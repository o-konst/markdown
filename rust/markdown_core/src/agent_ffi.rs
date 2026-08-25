//! C ABI for the chat agent, on top of [`markdown_agent`].
//!
//! One turn at a time, driven by a background thread the host does not manage: `send_start`
//! spawns it, `poll_event` blocks until the next thing worth showing arrives, and a NULL
//! poll means the turn ended. This is the "no callback ABI" shape from the plan — Rust never
//! calls back into Swift or C#, which would need care to stay memory-safe across the
//! boundary. The host calls `poll_event` in a loop on its own background thread instead.
//!
//! The API key arrives here from the host's keychain and is held only in Rust. It never
//! crosses the bridge into the web view, which can render arbitrary HTML from a note.

use core::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;

use markdown_agent::{Agent, AgentConfig, AgentEvent};
use serde_json::{json, Value};

use crate::ffi::{borrow_str, into_c_string};

/// Opaque handle to an open chat session. Only ever passed back to these functions.
pub struct MdAgent {
    agent: Arc<Mutex<Agent>>,
    /// The active turn's event stream. `None` when idle.
    current_turn: Mutex<Option<Receiver<String>>>,
}

/// Opens a chat session against the vault at `vault_path`, authenticating with `api_key`.
///
/// Returns NULL if the vault path is unusable. Release with [`md_agent_close`].
///
/// # Safety
/// Both pointers must be valid NUL terminated strings.
#[no_mangle]
pub unsafe extern "C" fn md_agent_open(
    vault_path: *const c_char,
    api_key: *const c_char,
) -> *mut MdAgent {
    let Some(vault_path) = (unsafe { borrow_str(vault_path) }) else {
        return core::ptr::null_mut();
    };
    let Some(api_key) = (unsafe { borrow_str(api_key) }) else {
        return core::ptr::null_mut();
    };

    let opened = catch_unwind(AssertUnwindSafe(|| {
        markdown_vault::Vault::open(Path::new(vault_path))
    }));
    let Ok(Ok(vault)) = opened else {
        return core::ptr::null_mut();
    };

    let agent = Agent::new(vault, AgentConfig::new(api_key));
    Box::into_raw(Box::new(MdAgent {
        agent: Arc::new(Mutex::new(agent)),
        current_turn: Mutex::new(None),
    }))
}

/// Closes a chat session opened by [`md_agent_open`]. Passing NULL is a no-op.
///
/// A turn in flight finishes on its own thread; its events are simply never read.
///
/// # Safety
/// `handle` must come from [`md_agent_open`] and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn md_agent_close(handle: *mut MdAgent) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Starts a turn: sends `text` and runs the loop on a background thread.
///
/// Returns `false` without starting anything if a turn is already in progress — the host
/// must drain one turn (poll until NULL) before starting the next.
///
/// # Safety
/// Both pointers must be valid, and `handle` must come from [`md_agent_open`].
#[no_mangle]
pub unsafe extern "C" fn md_agent_send_start(handle: *mut MdAgent, text: *const c_char) -> bool {
    if handle.is_null() {
        return false;
    }
    let Some(text) = (unsafe { borrow_str(text) }) else {
        return false;
    };
    let handle = unsafe { &*handle };

    let mut slot = handle.current_turn.lock().unwrap();
    if slot.is_some() {
        return false;
    }

    let (tx, rx) = mpsc::channel();
    let agent = Arc::clone(&handle.agent);
    let text = text.to_owned();

    thread::spawn(move || {
        let mut agent = agent.lock().unwrap();
        let ran = catch_unwind(AssertUnwindSafe(|| {
            agent.send(&text, &mut |event| {
                // The receiver may already be gone if the host closed the session mid-turn;
                // that is not this thread's problem to report.
                let _ = tx.send(event_json(&event).to_string());
            });
        }));
        if ran.is_err() {
            let _ = tx.send(
                event_json(&AgentEvent::Failed(
                    "the assistant turn failed unexpectedly".to_owned(),
                ))
                .to_string(),
            );
        }
        // `tx` drops here; the next `recv()` on the host side returns `Err`, which
        // `md_agent_poll_event` turns into the NULL that marks the turn as finished.
    });

    *slot = Some(rx);
    true
}

/// Blocks for the next event of the current turn.
///
/// Returns NULL once the turn has finished, or immediately if no turn is running. Release a
/// non-NULL result with `md_string_free`.
///
/// # Safety
/// `handle` must come from [`md_agent_open`].
#[no_mangle]
pub unsafe extern "C" fn md_agent_poll_event(handle: *mut MdAgent) -> *mut c_char {
    if handle.is_null() {
        return core::ptr::null_mut();
    }
    let handle = unsafe { &*handle };

    // Taken out from behind the mutex rather than held across it: `recv()` can block for as
    // long as the model takes to respond, and a lock held that long would stop a concurrent
    // `md_agent_send_start` from ever observing this session as idle.
    let Some(rx) = handle.current_turn.lock().unwrap().take() else {
        return core::ptr::null_mut();
    };

    match rx.recv() {
        Ok(json) => {
            // Still running: put the receiver back for the next poll.
            *handle.current_turn.lock().unwrap() = Some(rx);
            into_c_string(json)
        }
        // The sender dropped, which is how the background thread signals the turn ended.
        // Already taken out above, so the session is correctly idle again.
        Err(_) => core::ptr::null_mut(),
    }
}

fn event_json(event: &AgentEvent) -> Value {
    match event {
        AgentEvent::Text(text) => json!({ "type": "text", "text": text }),
        AgentEvent::Thinking(text) => json!({ "type": "thinking", "text": text }),
        AgentEvent::ToolStarted { name } => json!({ "type": "tool_started", "name": name }),
        AgentEvent::ToolFinished { name, ok, detail, commit } => json!({
            "type": "tool_finished",
            "name": name,
            "ok": ok,
            "detail": detail,
            "commit": commit,
        }),
        AgentEvent::Refused { category, explanation } => json!({
            "type": "refused",
            "category": category,
            "explanation": explanation,
        }),
        AgentEvent::Failed(message) => json!({ "type": "failed", "message": message }),
        AgentEvent::Done { stop_reason } => json!({ "type": "done", "stop_reason": stop_reason }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::fs;
    use tempfile::TempDir;

    /// Drains one full turn through the C ABI, exactly as the host will.
    fn drain(handle: *mut MdAgent) -> Vec<Value> {
        let mut events = Vec::new();
        loop {
            let raw = unsafe { md_agent_poll_event(handle) };
            if raw.is_null() {
                break;
            }
            let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
            unsafe { crate::ffi::md_string_free(raw) };
            events.push(serde_json::from_str(&text).unwrap());
        }
        events
    }

    #[test]
    fn opening_a_missing_vault_returns_null() {
        let path = CString::new("/definitely/not/a/vault").unwrap();
        let key = CString::new("k").unwrap();
        assert!(unsafe { md_agent_open(path.as_ptr(), key.as_ptr()) }.is_null());
    }

    #[test]
    fn a_null_handle_is_survivable() {
        let text = CString::new("hi").unwrap();
        assert!(!unsafe { md_agent_send_start(core::ptr::null_mut(), text.as_ptr()) });
        assert!(unsafe { md_agent_poll_event(core::ptr::null_mut()) }.is_null());
        unsafe { md_agent_close(core::ptr::null_mut()) };
    }

    #[test]
    fn polling_with_no_turn_running_returns_null_immediately() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("a.md"), "# A\n").unwrap();
        let path = CString::new(dir.path().to_str().unwrap()).unwrap();
        let key = CString::new("k").unwrap();
        let handle = unsafe { md_agent_open(path.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());

        assert!(unsafe { md_agent_poll_event(handle) }.is_null());
        unsafe { md_agent_close(handle) };
    }

    #[test]
    fn a_turn_streams_events_ending_in_a_failure_against_an_unreachable_host() {
        // No network stub here: this exercises the FFI plumbing (thread spawn, channel,
        // NULL-terminated drain), not the HTTP layer, which `markdown_agent`'s own stub-server
        // tests already cover in depth.
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("a.md"), "# A\n").unwrap();
        let path = CString::new(dir.path().to_str().unwrap()).unwrap();
        let key = CString::new("k").unwrap();
        let handle = unsafe { md_agent_open(path.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());

        // Point it at a port nothing listens on, so the request fails fast rather than
        // hitting the real API in a test.
        unsafe {
            (*handle).agent.lock().unwrap().set_base_url("http://127.0.0.1:1");
        }

        let text = CString::new("hello").unwrap();
        assert!(unsafe { md_agent_send_start(handle, text.as_ptr()) });

        let events = drain(handle);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "failed");

        // Draining fully must leave the session ready for another turn.
        assert!(unsafe { md_agent_send_start(handle, text.as_ptr()) });
        unsafe { md_agent_close(handle) };
    }

    #[test]
    fn a_second_send_while_one_is_in_flight_is_refused() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("a.md"), "# A\n").unwrap();
        let path = CString::new(dir.path().to_str().unwrap()).unwrap();
        let key = CString::new("k").unwrap();
        let handle = unsafe { md_agent_open(path.as_ptr(), key.as_ptr()) };
        unsafe {
            (*handle).agent.lock().unwrap().set_base_url("http://127.0.0.1:1");
        }

        let text = CString::new("hello").unwrap();
        assert!(unsafe { md_agent_send_start(handle, text.as_ptr()) });
        // The first turn's thread is racing this call, but `current_turn` is set
        // synchronously before `send_start` returns, so this is deterministic.
        assert!(!unsafe { md_agent_send_start(handle, text.as_ptr()) });

        drain(handle);
        unsafe { md_agent_close(handle) };
    }
}
