//! C ABI for the vault, on top of [`markdown_vault`].
//!
//! Deliberately three functions wide. Every operation goes through one JSON call, so adding a
//! tool is a change in `markdown_vault::tools` alone — the header, the Swift facade, and the
//! C# facade never need touching again. That is what keeps the two app shells thin.

use core::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

use markdown_vault::Vault;
use serde_json::{json, Value};

use crate::ffi::{borrow_str, into_c_string};

/// Opaque handle to an open vault. Only ever passed back to these functions.
pub struct MdVault {
    vault: Vault,
}

/// Opens a vault at `path`, initialising its history on first use.
///
/// Returns NULL if the path is unusable; call [`md_vault_close`] when finished.
///
/// # Safety
/// `path` must be a valid NUL terminated string.
#[no_mangle]
pub unsafe extern "C" fn md_vault_open(path: *const c_char) -> *mut MdVault {
    let Some(path) = (unsafe { borrow_str(path) }) else {
        return core::ptr::null_mut();
    };

    let opened = catch_unwind(AssertUnwindSafe(|| Vault::open(Path::new(path))));
    match opened {
        Ok(Ok(vault)) => Box::into_raw(Box::new(MdVault { vault })),
        _ => core::ptr::null_mut(),
    }
}

/// Closes a vault opened by [`md_vault_open`]. Passing NULL is a no-op.
///
/// # Safety
/// `handle` must come from [`md_vault_open`] and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn md_vault_close(handle: *mut MdVault) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Runs one vault tool.
///
/// `input_json` is the tool's arguments as a JSON object. The reply is always a JSON object,
/// either `{"ok":true,"result":{...}}` or `{"ok":false,"error":"..."}` — a failing tool is a
/// normal reply, not a NULL, so callers have one shape to parse and a message they can show.
/// NULL is returned only when the arguments themselves are unusable.
///
/// Release the result with `md_string_free`.
///
/// # Safety
/// All three pointers must be valid NUL terminated strings, and `handle` must come from
/// [`md_vault_open`].
#[no_mangle]
pub unsafe extern "C" fn md_vault_call(
    handle: *mut MdVault,
    name: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return core::ptr::null_mut();
    }
    let Some(name) = (unsafe { borrow_str(name) }) else {
        return core::ptr::null_mut();
    };
    let Some(input) = (unsafe { borrow_str(input_json) }) else {
        return core::ptr::null_mut();
    };
    let handle = unsafe { &*handle };

    let reply = catch_unwind(AssertUnwindSafe(|| {
        let input: Value = match serde_json::from_str(input) {
            Ok(value) => value,
            Err(err) => return failure(&format!("arguments are not valid JSON: {err}")),
        };
        match markdown_vault::tools::call(&handle.vault, name, &input) {
            Ok(result) => json!({ "ok": true, "result": result }),
            Err(message) => failure(&message),
        }
    }));

    match reply {
        Ok(reply) => into_c_string(reply.to_string()),
        // A panic must not cross the ABI boundary, so it becomes an ordinary failure.
        Err(_) => into_c_string(failure("the vault operation failed unexpectedly").to_string()),
    }
}

/// Catalogue of tools with their schemas, as JSON.
///
/// Lets the MCP server and the agent build their tool lists without hard-coding anything.
/// Release with `md_string_free`.
#[no_mangle]
pub extern "C" fn md_vault_tools() -> *mut c_char {
    let tools: Vec<Value> = markdown_vault::TOOLS
        .iter()
        .map(|tool| {
            json!({
                "name": tool.name,
                "description": tool.description,
                "read_only": tool.read_only,
                "destructive": tool.destructive,
                "input_schema": markdown_vault::schema(tool.name),
            })
        })
        .collect();
    into_c_string(json!({ "tools": tools }).to_string())
}

fn failure(message: &str) -> Value {
    json!({ "ok": false, "error": message })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::fs;
    use tempfile::TempDir;

    /// Round-trips a call through the C ABI exactly as the apps will.
    fn call(handle: *mut MdVault, name: &str, input: &str) -> Value {
        let name = CString::new(name).unwrap();
        let input = CString::new(input).unwrap();
        let raw = unsafe { md_vault_call(handle, name.as_ptr(), input.as_ptr()) };
        assert!(!raw.is_null(), "call returned NULL");

        let reply = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        unsafe { crate::ffi::md_string_free(raw) };
        serde_json::from_str(&reply).unwrap()
    }

    fn open_vault() -> (TempDir, *mut MdVault) {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("top.md"), "# Top\n\nbody\n").unwrap();

        let path = CString::new(dir.path().to_str().unwrap()).unwrap();
        let handle = unsafe { md_vault_open(path.as_ptr()) };
        assert!(!handle.is_null(), "vault failed to open");
        (dir, handle)
    }

    #[test]
    fn opens_reads_and_closes() {
        let (_dir, handle) = open_vault();
        let reply = call(handle, "read_note", r#"{"path":"top.md"}"#);
        assert_eq!(reply["ok"], json!(true));
        assert_eq!(reply["result"]["content"], "# Top\n\nbody\n");
        unsafe { md_vault_close(handle) };
    }

    #[test]
    fn writes_through_the_abi_and_undoes() {
        let (_dir, handle) = open_vault();
        let written = call(handle, "write_note", r#"{"path":"top.md","content":"new\n"}"#);
        assert_eq!(written["ok"], json!(true));

        let commit = written["result"]["commit"].as_str().unwrap().to_owned();
        let undone = call(handle, "undo", &format!(r#"{{"commit":"{commit}"}}"#));
        assert_eq!(undone["ok"], json!(true));

        let read = call(handle, "read_note", r#"{"path":"top.md"}"#);
        assert_eq!(read["result"]["content"], "# Top\n\nbody\n");
        unsafe { md_vault_close(handle) };
    }

    #[test]
    fn a_failing_tool_is_a_reply_not_a_null() {
        let (_dir, handle) = open_vault();
        let reply = call(handle, "read_note", r#"{"path":"../escape.md"}"#);
        assert_eq!(reply["ok"], json!(false));
        assert!(reply["error"].as_str().unwrap().contains(".."), "{reply}");
        unsafe { md_vault_close(handle) };
    }

    #[test]
    fn malformed_json_is_reported_rather_than_crashing() {
        let (_dir, handle) = open_vault();
        let reply = call(handle, "read_note", "{not json");
        assert_eq!(reply["ok"], json!(false));
        assert!(reply["error"].as_str().unwrap().contains("valid JSON"), "{reply}");
        unsafe { md_vault_close(handle) };
    }

    #[test]
    fn unknown_tools_are_reported() {
        let (_dir, handle) = open_vault();
        let reply = call(handle, "rm_rf", "{}");
        assert_eq!(reply["ok"], json!(false));
        unsafe { md_vault_close(handle) };
    }

    #[test]
    fn a_null_handle_is_survivable() {
        let name = CString::new("read_note").unwrap();
        let input = CString::new("{}").unwrap();
        let raw = unsafe { md_vault_call(core::ptr::null_mut(), name.as_ptr(), input.as_ptr()) };
        assert!(raw.is_null());
        unsafe { md_vault_close(core::ptr::null_mut()) };
    }

    #[test]
    fn opening_a_missing_vault_returns_null() {
        let path = CString::new("/definitely/not/a/vault").unwrap();
        assert!(unsafe { md_vault_open(path.as_ptr()) }.is_null());
    }

    #[test]
    fn publishes_the_tool_catalogue() {
        let raw = md_vault_tools();
        let json: Value =
            serde_json::from_str(unsafe { CStr::from_ptr(raw) }.to_str().unwrap()).unwrap();
        unsafe { crate::ffi::md_string_free(raw) };

        let tools = json["tools"].as_array().unwrap();
        assert_eq!(tools.len(), markdown_vault::TOOLS.len());
        assert!(tools.iter().all(|t| t["input_schema"].is_object()));
        // The gate the MCP server's `--allow-write` depends on travels with the catalogue.
        assert!(tools.iter().any(|t| t["read_only"] == json!(true)));
        assert!(tools.iter().any(|t| t["destructive"] == json!(true)));
    }
}
