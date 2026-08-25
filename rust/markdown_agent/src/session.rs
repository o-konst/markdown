//! The agent loop: ask, run whatever tools come back, ask again.
//!
//! Written by hand because there is no Anthropic SDK for Rust to supply the loop. The parts
//! that are easy to get subtly wrong are called out where they happen: batching tool results
//! into one message, reporting failures instead of dropping them, and refusing work *before*
//! it has a side effect rather than after.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use markdown_vault::Vault;
use serde_json::{json, Value};

use crate::request::{self, AgentConfig, Message};
use crate::sse::{Assembler, StreamEvent};

/// Something the chat panel shows.
#[derive(Debug, Clone, PartialEq)]
pub enum AgentEvent {
    Text(String),
    Thinking(String),
    /// A tool is about to run. Shown before the work, so a slow call is not silence.
    ToolStarted { name: String },
    ToolFinished {
        name: String,
        ok: bool,
        /// One line worth showing next to the tool's name.
        detail: String,
        /// Present for changes, so the panel can offer an undo for exactly this one.
        commit: Option<String>,
    },
    /// A safety classifier declined. Not an error; the turn simply stops.
    Refused {
        category: Option<String>,
        explanation: Option<String>,
    },
    /// The turn could not run or could not finish.
    Failed(String),
    Done { stop_reason: String },
}

pub struct Agent {
    vault: Vault,
    config: AgentConfig,
    system: String,
    messages: Vec<Message>,
    client: reqwest::blocking::Client,
    /// Where per-turn traces go. Outside the vault, so they are never committed with notes.
    trace_dir: Option<PathBuf>,
}

impl Agent {
    pub fn new(vault: Vault, config: AgentConfig) -> Self {
        let name = vault
            .root()
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "notes".to_owned());

        Self {
            system: request::system_prompt(&name),
            vault,
            config,
            messages: Vec::new(),
            client: reqwest::blocking::Client::new(),
            trace_dir: None,
        }
    }

    /// Records each turn as JSONL. The host chooses the location; passing a path inside the
    /// vault would get traces committed alongside the user's notes.
    pub fn with_trace_dir(mut self, dir: PathBuf) -> Self {
        self.trace_dir = Some(dir);
        self
    }

    /// Overrides the API endpoint after construction. Exists for tests that point at a stub
    /// server, and for any future host that needs to target something other than the default.
    pub fn set_base_url(&mut self, base_url: impl Into<String>) {
        self.config.base_url = base_url.into();
    }

    pub fn history_len(&self) -> usize {
        self.messages.len()
    }

    /// Runs one user message to completion, reporting progress through `emit`.
    pub fn send(&mut self, user_text: &str, emit: &mut dyn FnMut(AgentEvent)) {
        // Refuse on a dirty tree. Otherwise the agent's commits would be entangled with edits
        // the person has not saved, and undoing one would take the other with it.
        match self.vault.history().is_dirty() {
            Ok(true) => {
                emit(AgentEvent::Failed(
                    "There are unsaved changes in the vault. Save them first so the \
                     assistant's edits can be undone independently."
                        .to_owned(),
                ));
                return;
            }
            Err(err) => {
                emit(AgentEvent::Failed(format!("Cannot read the vault history: {err}")));
                return;
            }
            Ok(false) => {}
        }

        let mut trace = Trace::start(self.trace_dir.clone());
        trace.record(json!({ "kind": "prompt", "text": user_text }));
        self.messages.push(Message::user(user_text));

        let mut writes_used = 0_u32;

        for round in 0..self.config.max_tool_rounds {
            trace.record(json!({ "kind": "model_call", "round": round }));

            let assembled = match self.round(emit, &mut trace) {
                Ok(assembled) => assembled,
                Err(message) => {
                    trace.record(json!({ "kind": "error", "message": message }));
                    emit(AgentEvent::Failed(message));
                    return;
                }
            };

            if assembled.was_refused() {
                let details = assembled.stop_details.clone().unwrap_or_default();
                emit(AgentEvent::Refused {
                    category: details["category"].as_str().map(str::to_owned),
                    explanation: details["explanation"].as_str().map(str::to_owned),
                });
                trace.record(json!({ "kind": "refusal", "details": details }));
                return;
            }

            // The assistant turn goes back verbatim, thinking blocks included.
            self.messages
                .push(Message::assistant(Value::Array(assembled.content.clone())));

            if !assembled.wants_tools() {
                let reason = assembled.stop_reason.unwrap_or_else(|| "end_turn".to_owned());
                trace.record(json!({ "kind": "done", "stop_reason": reason }));
                emit(AgentEvent::Done { stop_reason: reason });
                return;
            }

            let results = self.run_tools(&assembled, &mut writes_used, emit, &mut trace);
            // All of them, in one user message: splitting them teaches the model to stop
            // asking for tools in parallel.
            self.messages.push(Message::tool_results(results));
        }

        let message = format!(
            "Stopped after {} rounds of tool calls without finishing. Try a smaller request.",
            self.config.max_tool_rounds
        );
        trace.record(json!({ "kind": "error", "message": message }));
        emit(AgentEvent::Failed(message));
    }

    /// One request/response, streamed.
    fn round(
        &self,
        emit: &mut dyn FnMut(AgentEvent),
        trace: &mut Trace,
    ) -> Result<crate::sse::Assembled, String> {
        let body = request::body(&self.config, &self.system, &self.messages);

        let response = self
            .client
            .post(self.config.endpoint())
            .header("x-api-key", &self.config.api_key)
            .header("anthropic-version", request::API_VERSION)
            .header("anthropic-beta", request::FALLBACK_BETA)
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .map_err(|err| format!("Could not reach the API: {err}"))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().unwrap_or_default();
            let detail = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| v["error"]["message"].as_str().map(str::to_owned))
                .unwrap_or(body);
            return Err(format!("The API returned {status}: {detail}"));
        }

        let mut assembler = Assembler::new();
        let reader = BufReader::new(response);
        for line in reader.lines() {
            let line = line.map_err(|err| format!("The stream ended early: {err}"))?;
            for event in assembler.feed(&line) {
                match event {
                    StreamEvent::Text(text) => emit(AgentEvent::Text(text)),
                    StreamEvent::Thinking(text) => emit(AgentEvent::Thinking(text)),
                    StreamEvent::ToolStarted { name, .. } => {
                        emit(AgentEvent::ToolStarted { name })
                    }
                    StreamEvent::Error(message) => {
                        trace.record(json!({ "kind": "stream_error", "message": message }));
                        return Err(message);
                    }
                }
            }
        }
        Ok(assembler.finish())
    }

    /// Runs every tool the assistant asked for, in order, and returns their result blocks.
    fn run_tools(
        &self,
        assembled: &crate::sse::Assembled,
        writes_used: &mut u32,
        emit: &mut dyn FnMut(AgentEvent),
        trace: &mut Trace,
    ) -> Vec<Value> {
        let budget = self.config.write_call_budget();
        let mut results = Vec::new();

        for (id, name, input) in assembled.tool_uses() {
            trace.record(json!({ "kind": "tool_call", "tool": name, "input": input }));

            let mutating = markdown_vault::tools::spec(name).is_some_and(|spec| !spec.read_only);

            // Checked before the call, not after: a model that decides to rewrite the whole
            // vault is stopped before the first file changes.
            if mutating && *writes_used >= budget {
                let message = format!(
                    "Refused: this turn has already made its {budget} allowed changes. \
                     Summarise what is left instead of making more."
                );
                emit(AgentEvent::ToolFinished {
                    name: name.to_owned(),
                    ok: false,
                    detail: "write limit reached".to_owned(),
                    commit: None,
                });
                trace.record(json!({ "kind": "tool_result", "tool": name, "refused": true }));
                results.push(request::tool_result_block(id, &message, true));
                continue;
            }

            match markdown_vault::tools::call(&self.vault, name, input) {
                Ok(value) => {
                    if mutating {
                        *writes_used += 1;
                    }
                    let commit = value["commit"].as_str().map(str::to_owned);
                    emit(AgentEvent::ToolFinished {
                        name: name.to_owned(),
                        ok: true,
                        detail: describe(name, input),
                        commit: commit.clone(),
                    });
                    trace.record(json!({
                        "kind": "tool_result", "tool": name, "ok": true, "commit": commit
                    }));
                    results.push(request::tool_result_block(id, &value.to_string(), false));
                }
                Err(message) => {
                    // Reported back, never dropped: the model needs to see why it failed.
                    emit(AgentEvent::ToolFinished {
                        name: name.to_owned(),
                        ok: false,
                        detail: message.clone(),
                        commit: None,
                    });
                    trace.record(json!({
                        "kind": "tool_result", "tool": name, "ok": false, "error": message
                    }));
                    results.push(request::tool_result_block(id, &message, true));
                }
            }
        }
        results
    }
}

/// A short human-readable label for what a tool call touched.
fn describe(name: &str, input: &Value) -> String {
    for key in ["path", "from", "query", "dir"] {
        if let Some(value) = input[key].as_str() {
            return value.to_owned();
        }
    }
    name.to_owned()
}

/// Per-turn JSONL, so "why did it do that" stays answerable afterwards.
struct Trace {
    file: Option<std::fs::File>,
    sequence: u64,
}

impl Trace {
    fn start(dir: Option<PathBuf>) -> Self {
        let Some(dir) = dir else {
            return Self { file: None, sequence: 0 };
        };
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let run = dir.join(format!("{stamp}"));
        if std::fs::create_dir_all(&run).is_err() {
            return Self { file: None, sequence: 0 };
        }
        Self {
            file: std::fs::File::create(run.join("trace.jsonl")).ok(),
            sequence: 0,
        }
    }

    /// Tracing is best-effort: a turn must never fail because a log could not be written.
    fn record(&mut self, mut entry: Value) {
        let Some(file) = self.file.as_mut() else {
            return;
        };
        self.sequence += 1;
        entry["seq"] = json!(self.sequence);
        entry["ts"] = json!(SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0));
        let _ = writeln!(file, "{entry}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;
    use tempfile::TempDir;

    /// A canned `/v1/messages` server.
    ///
    /// The loop is the part most worth testing and the part hardest to test against the real
    /// API, so it gets replayed transcripts: no tokens, no network, and failure modes that
    /// would be luck to reproduce live.
    struct Stub {
        port: u16,
        requests: Arc<Mutex<Vec<Value>>>,
    }

    impl Stub {
        fn start(script: Vec<String>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let requests = Arc::new(Mutex::new(Vec::new()));
            let captured = Arc::clone(&requests);

            thread::spawn(move || {
                for body_text in script {
                    let Ok((mut stream, _)) = listener.accept() else { break };
                    let mut reader = BufReader::new(stream.try_clone().unwrap());

                    let mut length = 0usize;
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                            length = value.trim().parse().unwrap_or(0);
                        }
                    }
                    let mut raw = vec![0u8; length];
                    reader.read_exact(&mut raw).ok();
                    if let Ok(parsed) = serde_json::from_slice::<Value>(&raw) {
                        captured.lock().unwrap().push(parsed);
                    }

                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\
                         Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body_text.len(),
                        body_text
                    );
                    stream.write_all(response.as_bytes()).ok();
                    stream.flush().ok();
                }
            });

            Self { port, requests }
        }

        fn requests(&self) -> Vec<Value> {
            self.requests.lock().unwrap().clone()
        }
    }

    fn sse(events: &[Value]) -> String {
        events
            .iter()
            .map(|event| format!("event: {}\ndata: {}\n\n", event["type"].as_str().unwrap(), event))
            .collect()
    }

    fn text_turn(text: &str) -> String {
        sse(&[
            json!({"type":"content_block_start","index":0,
                   "content_block":{"type":"text","text":""}}),
            json!({"type":"content_block_delta","index":0,
                   "delta":{"type":"text_delta","text":text}}),
            json!({"type":"content_block_stop","index":0}),
            json!({"type":"message_delta","delta":{"stop_reason":"end_turn"}}),
        ])
    }

    /// One assistant turn asking for `calls` as (id, tool, arguments-json).
    fn tool_turn(calls: &[(&str, &str, &str)]) -> String {
        let mut events = Vec::new();
        for (index, (id, name, args)) in calls.iter().enumerate() {
            events.push(json!({"type":"content_block_start","index":index,
                "content_block":{"type":"tool_use","id":id,"name":name,"input":{}}}));
            events.push(json!({"type":"content_block_delta","index":index,
                "delta":{"type":"input_json_delta","partial_json":args}}));
            events.push(json!({"type":"content_block_stop","index":index}));
        }
        events.push(json!({"type":"message_delta","delta":{"stop_reason":"tool_use"}}));
        sse(&events)
    }

    fn vault() -> (TempDir, Vault) {
        let dir = TempDir::new().unwrap();
        std::fs::write(dir.path().join("a.md"), "# A\n\nalpha\n").unwrap();
        std::fs::write(dir.path().join("b.md"), "# B\n\nbeta\n").unwrap();
        let vault = Vault::open(dir.path()).unwrap();
        (dir, vault)
    }

    fn agent(vault: Vault, stub: &Stub) -> Agent {
        let mut config = AgentConfig::new("test-key");
        config.base_url = format!("http://127.0.0.1:{}", stub.port);
        Agent::new(vault, config)
    }

    fn collect(agent: &mut Agent, prompt: &str) -> Vec<AgentEvent> {
        let mut events = Vec::new();
        agent.send(prompt, &mut |event| events.push(event));
        events
    }

    #[test]
    fn a_plain_answer_streams_and_finishes() {
        let stub = Stub::start(vec![text_turn("Hello there")]);
        let (_dir, vault) = vault();
        let events = collect(&mut agent(vault, &stub), "hi");

        assert_eq!(events[0], AgentEvent::Text("Hello there".into()));
        assert!(matches!(events.last(), Some(AgentEvent::Done { .. })));
        assert_eq!(stub.requests().len(), 1);
    }

    #[test]
    fn parallel_tool_results_go_back_in_one_message() {
        let stub = Stub::start(vec![
            tool_turn(&[
                ("t1", "read_note", r#"{"path":"a.md"}"#),
                ("t2", "read_note", r#"{"path":"b.md"}"#),
            ]),
            text_turn("Read both"),
        ]);
        let (_dir, vault) = vault();
        collect(&mut agent(vault, &stub), "read both notes");

        let requests = stub.requests();
        assert_eq!(requests.len(), 2);

        // The follow-up carries exactly one user message holding both results. Splitting
        // them across messages is what teaches the model to stop calling tools in parallel.
        let messages = requests[1]["messages"].as_array().unwrap();
        let last = messages.last().unwrap();
        assert_eq!(last["role"], "user");
        let blocks = last["content"].as_array().unwrap();
        assert_eq!(blocks.len(), 2);
        assert!(blocks.iter().all(|b| b["type"] == "tool_result"));
        assert_eq!(blocks[0]["tool_use_id"], "t1");
        assert_eq!(blocks[1]["tool_use_id"], "t2");
    }

    #[test]
    fn a_failing_tool_is_reported_not_dropped() {
        let stub = Stub::start(vec![
            tool_turn(&[("t1", "read_note", r#"{"path":"missing.md"}"#)]),
            text_turn("That note is not there"),
        ]);
        let (_dir, vault) = vault();
        let events = collect(&mut agent(vault, &stub), "read missing.md");

        assert!(events.iter().any(|e| matches!(
            e, AgentEvent::ToolFinished { ok: false, .. }
        )));

        let requests = stub.requests();
        let blocks = requests[1]["messages"].as_array().unwrap().last().unwrap()["content"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(blocks[0]["is_error"], true);
        assert!(blocks[0]["content"].as_str().unwrap().contains("no such file"));
    }

    #[test]
    fn the_write_cap_refuses_before_the_file_changes() {
        let stub = Stub::start(vec![
            tool_turn(&[
                ("t1", "write_note", r#"{"path":"one.md","content":"1"}"#),
                ("t2", "write_note", r#"{"path":"two.md","content":"2"}"#),
            ]),
            text_turn("Stopped at the limit"),
        ]);
        let (dir, vault) = vault();
        let mut config = AgentConfig::new("k");
        config.base_url = format!("http://127.0.0.1:{}", stub.port);
        config.max_write_calls = 1;
        let mut agent = Agent::new(vault, config);
        collect(&mut agent, "write two notes");

        assert!(dir.path().join("one.md").exists(), "the allowed write did not happen");
        assert!(!dir.path().join("two.md").exists(), "the capped write reached disk");

        let requests = stub.requests();
        let blocks = requests[1]["messages"].as_array().unwrap().last().unwrap()["content"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(blocks[1]["is_error"], true);
        assert!(blocks[1]["content"].as_str().unwrap().contains("already made"));
    }

    #[test]
    fn reads_are_not_charged_against_the_write_cap() {
        let stub = Stub::start(vec![
            tool_turn(&[
                ("t1", "read_note", r#"{"path":"a.md"}"#),
                ("t2", "read_note", r#"{"path":"b.md"}"#),
                ("t3", "write_note", r#"{"path":"one.md","content":"1"}"#),
            ]),
            text_turn("done"),
        ]);
        let (dir, vault) = vault();
        let mut config = AgentConfig::new("k");
        config.base_url = format!("http://127.0.0.1:{}", stub.port);
        config.max_write_calls = 1;
        collect(&mut Agent::new(vault, config), "read then write");

        assert!(dir.path().join("one.md").exists(), "reads consumed the write budget");
    }

    #[test]
    fn a_refusal_stops_the_turn_with_its_category() {
        let stub = Stub::start(vec![sse(&[json!({
            "type":"message_delta",
            "delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}
        })])]);
        let (_dir, vault) = vault();
        let events = collect(&mut agent(vault, &stub), "something declined");

        assert_eq!(
            events.last(),
            Some(&AgentEvent::Refused {
                category: Some("cyber".into()),
                explanation: None
            })
        );
    }

    #[test]
    fn a_dirty_vault_refuses_before_any_request() {
        let stub = Stub::start(vec![text_turn("never asked")]);
        let (dir, vault) = vault();
        std::fs::write(dir.path().join("unsaved.md"), "in progress").unwrap();

        let events = collect(&mut agent(vault, &stub), "go");
        assert!(matches!(events.as_slice(), [AgentEvent::Failed(m)] if m.contains("unsaved")));
        assert!(stub.requests().is_empty(), "it called the API anyway");
    }

    #[test]
    fn the_round_cap_stops_a_loop_that_never_finishes() {
        let looping: Vec<String> = (0..10)
            .map(|_| tool_turn(&[("t", "read_note", r#"{"path":"a.md"}"#)]))
            .collect();
        let stub = Stub::start(looping);
        let (_dir, vault) = vault();

        let mut config = AgentConfig::new("k");
        config.base_url = format!("http://127.0.0.1:{}", stub.port);
        config.max_tool_rounds = 3;
        let events = collect(&mut Agent::new(vault, config), "loop forever");

        assert!(matches!(events.last(), Some(AgentEvent::Failed(m)) if m.contains("3 rounds")));
        assert_eq!(stub.requests().len(), 3, "the cap did not bound the requests");
    }

    #[test]
    fn thinking_blocks_are_echoed_back_unchanged() {
        let first = sse(&[
            json!({"type":"content_block_start","index":0,
                   "content_block":{"type":"thinking","thinking":""}}),
            json!({"type":"content_block_delta","index":0,
                   "delta":{"type":"thinking_delta","thinking":"considering"}}),
            json!({"type":"content_block_delta","index":0,
                   "delta":{"type":"signature_delta","signature":"sig"}}),
            json!({"type":"content_block_stop","index":0}),
            json!({"type":"content_block_start","index":1,
                   "content_block":{"type":"tool_use","id":"t","name":"read_note","input":{}}}),
            json!({"type":"content_block_delta","index":1,
                   "delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.md\"}"}}),
            json!({"type":"content_block_stop","index":1}),
            json!({"type":"message_delta","delta":{"stop_reason":"tool_use"}}),
        ]);
        let stub = Stub::start(vec![first, text_turn("done")]);
        let (_dir, vault) = vault();
        collect(&mut agent(vault, &stub), "think then read");

        let requests = stub.requests();
        let messages = requests[1]["messages"].as_array().unwrap();
        let assistant = messages.iter().find(|m| m["role"] == "assistant").unwrap();
        let thinking = &assistant["content"][0];
        assert_eq!(thinking["type"], "thinking");
        assert_eq!(thinking["thinking"], "considering");
        assert_eq!(thinking["signature"], "sig", "the signature must survive replay");
    }

    #[test]
    fn a_trace_records_the_turn() {
        let stub = Stub::start(vec![
            tool_turn(&[("t1", "read_note", r#"{"path":"a.md"}"#)]),
            text_turn("done"),
        ]);
        let (_dir, vault) = vault();
        let traces = TempDir::new().unwrap();

        let mut config = AgentConfig::new("k");
        config.base_url = format!("http://127.0.0.1:{}", stub.port);
        let mut agent = Agent::new(vault, config).with_trace_dir(traces.path().to_path_buf());
        agent.send("read a.md", &mut |_| {});

        let run = std::fs::read_dir(traces.path()).unwrap().next().unwrap().unwrap();
        let lines = std::fs::read_to_string(run.path().join("trace.jsonl")).unwrap();
        let kinds: Vec<String> = lines
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap()["kind"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(kinds[0], "prompt");
        assert!(kinds.contains(&"tool_call".to_owned()));
        assert!(kinds.contains(&"tool_result".to_owned()));
        assert_eq!(kinds.last().unwrap(), "done");
    }

    #[test]
    fn the_trace_stays_out_of_the_vault() {
        // Traces inside the vault would be swept up by the next commit and land in the
        // user's note history.
        let (dir, vault) = vault();
        let stub = Stub::start(vec![text_turn("hi")]);
        let traces = TempDir::new().unwrap();
        let mut config = AgentConfig::new("k");
        config.base_url = format!("http://127.0.0.1:{}", stub.port);
        Agent::new(vault, config)
            .with_trace_dir(traces.path().to_path_buf())
            .send("hi", &mut |_| {});

        let names: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
            .collect();
        assert!(!names.iter().any(|n| n.contains("trace")), "{names:?}");
    }
}
