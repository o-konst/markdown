//! Turning the streaming response into deltas to show and a message to replay.
//!
//! Two jobs at once. The host wants deltas as they arrive so text appears while it is being
//! written; the next request needs the assistant turn reassembled *verbatim*, because content
//! blocks — thinking included — have to be echoed back unchanged when the conversation
//! continues on the same model.

use serde_json::{json, Value};

/// Something worth showing the moment it arrives.
#[derive(Debug, Clone, PartialEq)]
pub enum StreamEvent {
    Text(String),
    /// Summarised reasoning. The raw chain of thought is never returned by the API.
    Thinking(String),
    /// A tool call has begun; its arguments are still streaming in.
    ToolStarted { id: String, name: String },
    /// An error delivered inside the stream rather than as an HTTP status.
    Error(String),
}

/// The finished assistant turn.
#[derive(Debug, Clone, Default)]
pub struct Assembled {
    /// Content blocks exactly as they arrived, for replay in the next request.
    pub content: Vec<Value>,
    pub stop_reason: Option<String>,
    /// Populated only when `stop_reason` is `refusal`.
    pub stop_details: Option<Value>,
    pub usage: Option<Value>,
}

impl Assembled {
    pub fn tool_uses(&self) -> Vec<(&str, &str, &Value)> {
        self.content
            .iter()
            .filter(|block| block["type"] == "tool_use")
            .filter_map(|block| {
                Some((
                    block["id"].as_str()?,
                    block["name"].as_str()?,
                    &block["input"],
                ))
            })
            .collect()
    }

    pub fn wants_tools(&self) -> bool {
        self.stop_reason.as_deref() == Some("tool_use")
    }

    pub fn was_refused(&self) -> bool {
        self.stop_reason.as_deref() == Some("refusal")
    }
}

/// One in-flight content block.
#[derive(Debug)]
struct Block {
    value: Value,
    /// `tool_use` arguments arrive as fragments of JSON text to be concatenated.
    partial_json: String,
}

#[derive(Debug, Default)]
pub struct Assembler {
    blocks: Vec<Block>,
    stop_reason: Option<String>,
    stop_details: Option<Value>,
    usage: Option<Value>,
}

impl Assembler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feeds one line of the SSE body. Returns whatever became showable.
    ///
    /// The `event:` lines are ignored: every `data:` payload names its own type, so parsing
    /// both would be two sources of truth for the same thing.
    pub fn feed(&mut self, line: &str) -> Vec<StreamEvent> {
        let Some(payload) = line.strip_prefix("data:") else {
            return Vec::new();
        };
        let payload = payload.trim();
        if payload.is_empty() || payload == "[DONE]" {
            return Vec::new();
        }
        let Ok(event) = serde_json::from_str::<Value>(payload) else {
            return vec![StreamEvent::Error(format!(
                "could not parse a streamed event: {payload}"
            ))];
        };

        match event["type"].as_str().unwrap_or_default() {
            "content_block_start" => self.start_block(&event),
            "content_block_delta" => self.apply_delta(&event),
            "content_block_stop" => {
                self.finish_block(&event);
                Vec::new()
            }
            "message_delta" => {
                if let Some(reason) = event["delta"]["stop_reason"].as_str() {
                    self.stop_reason = Some(reason.to_owned());
                }
                if event["delta"]["stop_details"].is_object() {
                    self.stop_details = Some(event["delta"]["stop_details"].clone());
                }
                if event["usage"].is_object() {
                    self.usage = Some(event["usage"].clone());
                }
                Vec::new()
            }
            "message_start" => {
                if event["message"]["usage"].is_object() {
                    self.usage = Some(event["message"]["usage"].clone());
                }
                Vec::new()
            }
            "error" => vec![StreamEvent::Error(
                event["error"]["message"]
                    .as_str()
                    .unwrap_or("the stream reported an error")
                    .to_owned(),
            )],
            // `ping`, `message_stop`, and anything added later.
            _ => Vec::new(),
        }
    }

    pub fn finish(mut self) -> Assembled {
        // A stream cut short mid-block still has to produce replayable content.
        for index in 0..self.blocks.len() {
            self.seal(index);
        }
        Assembled {
            content: self.blocks.into_iter().map(|block| block.value).collect(),
            stop_reason: self.stop_reason,
            stop_details: self.stop_details,
            usage: self.usage,
        }
    }

    fn start_block(&mut self, event: &Value) -> Vec<StreamEvent> {
        let index = event["index"].as_u64().unwrap_or(0) as usize;
        let value = event["content_block"].clone();
        let emitted = match value["type"].as_str() {
            Some("tool_use") => vec![StreamEvent::ToolStarted {
                id: value["id"].as_str().unwrap_or_default().to_owned(),
                name: value["name"].as_str().unwrap_or_default().to_owned(),
            }],
            _ => Vec::new(),
        };

        while self.blocks.len() <= index {
            self.blocks.push(Block {
                value: json!({}),
                partial_json: String::new(),
            });
        }
        self.blocks[index] = Block {
            value,
            partial_json: String::new(),
        };
        emitted
    }

    fn apply_delta(&mut self, event: &Value) -> Vec<StreamEvent> {
        let index = event["index"].as_u64().unwrap_or(0) as usize;
        let delta = &event["delta"];
        if index >= self.blocks.len() {
            return Vec::new();
        }
        let block = &mut self.blocks[index];

        match delta["type"].as_str().unwrap_or_default() {
            "text_delta" => {
                let text = delta["text"].as_str().unwrap_or_default();
                append_str(&mut block.value, "text", text);
                vec![StreamEvent::Text(text.to_owned())]
            }
            "thinking_delta" => {
                let text = delta["thinking"].as_str().unwrap_or_default();
                append_str(&mut block.value, "thinking", text);
                if text.is_empty() {
                    Vec::new()
                } else {
                    vec![StreamEvent::Thinking(text.to_owned())]
                }
            }
            "signature_delta" => {
                // Part of the thinking block's integrity data; kept for replay, never shown.
                append_str(
                    &mut block.value,
                    "signature",
                    delta["signature"].as_str().unwrap_or_default(),
                );
                Vec::new()
            }
            "input_json_delta" => {
                block
                    .partial_json
                    .push_str(delta["partial_json"].as_str().unwrap_or_default());
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn finish_block(&mut self, event: &Value) {
        let index = event["index"].as_u64().unwrap_or(0) as usize;
        self.seal(index);
    }

    /// Parses a tool block's accumulated argument text into real JSON.
    ///
    /// Always parsed, never string-matched: escaping in these fragments varies by model, so
    /// reading them as text rather than JSON is how you get a subtly wrong argument.
    fn seal(&mut self, index: usize) {
        let Some(block) = self.blocks.get_mut(index) else {
            return;
        };
        if block.value["type"] != "tool_use" {
            return;
        }
        if block.partial_json.is_empty() {
            // No arguments streamed: an empty object, not a missing field.
            if !block.value["input"].is_object() {
                block.value["input"] = json!({});
            }
            return;
        }
        match serde_json::from_str::<Value>(&block.partial_json) {
            Ok(input) => block.value["input"] = input,
            // Leave whatever `content_block_start` carried; the tool layer will reject it
            // with a message the model can act on.
            Err(_) => block.value["input"] = json!({}),
        }
        block.partial_json.clear();
    }
}

fn append_str(value: &mut Value, key: &str, text: &str) {
    if text.is_empty() {
        return;
    }
    let existing = value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    value[key] = Value::String(existing + text);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(lines: &[&str]) -> (Vec<StreamEvent>, Assembled) {
        let mut assembler = Assembler::new();
        let mut events = Vec::new();
        for line in lines {
            events.extend(assembler.feed(line));
        }
        (events, assembler.finish())
    }

    #[test]
    fn assembles_streamed_text() {
        let (events, done) = run(&[
            r#"event: content_block_start"#,
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}"#,
            r#"data: {"type":"content_block_stop","index":0}"#,
            r#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
        ]);

        assert_eq!(
            events,
            vec![
                StreamEvent::Text("Hello".into()),
                StreamEvent::Text(", world".into())
            ]
        );
        assert_eq!(done.content[0]["text"], "Hello, world");
        assert_eq!(done.stop_reason.as_deref(), Some("end_turn"));
        assert_eq!(done.usage.unwrap()["output_tokens"], 5);
    }

    #[test]
    fn parses_tool_arguments_from_json_fragments() {
        let (events, done) = run(&[
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_note","input":{}}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"a.md\"}"}}"#,
            r#"data: {"type":"content_block_stop","index":0}"#,
            r#"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]);

        assert_eq!(
            events,
            vec![StreamEvent::ToolStarted {
                id: "toolu_1".into(),
                name: "read_note".into()
            }]
        );
        assert!(done.wants_tools());
        let uses = done.tool_uses();
        assert_eq!(uses.len(), 1);
        assert_eq!(uses[0].1, "read_note");
        // Parsed as JSON, not pattern-matched out of the text.
        assert_eq!(uses[0].2["path"], "a.md");
    }

    #[test]
    fn keeps_parallel_tool_calls_separate() {
        let (_, done) = run(&[
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"read_note","input":{}}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.md\"}"}}"#,
            r#"data: {"type":"content_block_stop","index":0}"#,
            r#"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t2","name":"read_note","input":{}}}"#,
            r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"b.md\"}"}}"#,
            r#"data: {"type":"content_block_stop","index":1}"#,
            r#"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]);

        let uses = done.tool_uses();
        assert_eq!(uses.len(), 2);
        assert_eq!(uses[0].2["path"], "a.md");
        assert_eq!(uses[1].2["path"], "b.md");
    }

    #[test]
    fn keeps_thinking_blocks_for_replay() {
        let (events, done) = run(&[
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"weighing it up"}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            r#"data: {"type":"content_block_stop","index":0}"#,
        ]);

        assert_eq!(events, vec![StreamEvent::Thinking("weighing it up".into())]);
        // Both fields survive, because the block must be echoed back unchanged.
        assert_eq!(done.content[0]["thinking"], "weighing it up");
        assert_eq!(done.content[0]["signature"], "sig123");
    }

    #[test]
    fn an_omitted_thinking_block_shows_nothing() {
        // `display: "omitted"` streams thinking deltas whose text is empty.
        let (events, _) = run(&[
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
        ]);
        assert!(events.is_empty());
    }

    #[test]
    fn surfaces_a_refusal_with_its_category() {
        let (_, done) = run(&[
            r#"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}}"#,
        ]);
        assert!(done.was_refused());
        assert_eq!(done.stop_details.unwrap()["category"], "cyber");
    }

    #[test]
    fn surfaces_an_in_stream_error() {
        let (events, _) = run(&[
            r#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]);
        assert_eq!(events, vec![StreamEvent::Error("Overloaded".into())]);
    }

    #[test]
    fn malformed_tool_arguments_do_not_panic() {
        let (_, done) = run(&[
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"read_note","input":{}}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{not json"}}"#,
            r#"data: {"type":"content_block_stop","index":0}"#,
            r#"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]);
        // Empty arguments reach the tool layer, which answers with guidance the model can use.
        assert_eq!(done.tool_uses()[0].2, &json!({}));
    }

    #[test]
    fn a_truncated_stream_still_replays() {
        // No content_block_stop, no message_delta: the connection simply ended.
        let (_, done) = run(&[
            r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"read_note","input":{}}}"#,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.md\"}"}}"#,
        ]);
        assert_eq!(done.tool_uses()[0].2["path"], "a.md");
        assert!(done.stop_reason.is_none());
    }

    #[test]
    fn ignores_pings_and_unparseable_lines() {
        let mut assembler = Assembler::new();
        assert!(assembler.feed("event: ping").is_empty());
        assert!(assembler.feed("data: {\"type\":\"ping\"}").is_empty());
        assert!(assembler.feed("").is_empty());
        assert!(assembler.feed(": comment").is_empty());
        assert_eq!(assembler.feed("data: {not json").len(), 1);
    }
}
