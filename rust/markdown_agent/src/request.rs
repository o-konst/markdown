//! Building the `POST /v1/messages` request.
//!
//! There is no Anthropic SDK for Rust, so this is the raw HTTP shape. Several of the
//! parameters here are load-bearing in ways that are not obvious from reading them, so the
//! reasons are recorded next to each one rather than in a commit message.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const API_VERSION: &str = "2023-06-01";

/// Routes around a policy decline by re-running the request on a fallback model inside the
/// same call, without us maintaining a model list.
pub const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";

#[derive(Debug, Clone)]
pub struct AgentConfig {
    pub api_key: String,
    /// Overridable so tests can point at a stub server.
    pub base_url: String,
    pub model: String,
    /// `low` … `max`. Controls thinking depth and overall spend.
    pub effort: String,
    /// Writes allowed in one turn before further ones are refused.
    pub max_write_calls: u32,
    /// Request/tool-result round trips allowed in one turn.
    pub max_tool_rounds: u32,
}

impl AgentConfig {
    /// Hard ceiling on `max_write_calls`, whatever a caller asks for.
    pub const WRITE_CALL_CEILING: u32 = 50;

    pub fn new(api_key: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            base_url: "https://api.anthropic.com".to_owned(),
            // Opus 5 unless a caller deliberately chooses otherwise.
            model: "claude-opus-5".to_owned(),
            effort: "high".to_owned(),
            max_write_calls: 5,
            max_tool_rounds: 8,
        }
    }

    pub fn endpoint(&self) -> String {
        format!("{}/v1/messages", self.base_url.trim_end_matches('/'))
    }

    pub fn write_call_budget(&self) -> u32 {
        self.max_write_calls.min(Self::WRITE_CALL_CEILING)
    }
}

/// One turn in the conversation, stored as the API shapes it so it can be replayed verbatim.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: Value,
}

impl Message {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            role: "user".to_owned(),
            content: json!([{ "type": "text", "text": text.into() }]),
        }
    }

    /// The assistant's reply, echoed back unchanged.
    ///
    /// Content blocks — thinking included — must go back exactly as they arrived when the
    /// conversation continues on the same model.
    pub fn assistant(content: Value) -> Self {
        Self {
            role: "assistant".to_owned(),
            content,
        }
    }

    /// Every tool result for one assistant turn, in a single user message.
    ///
    /// Splitting these across several messages teaches the model to stop asking for tools in
    /// parallel, so they are always batched.
    pub fn tool_results(results: Vec<Value>) -> Self {
        Self {
            role: "user".to_owned(),
            content: Value::Array(results),
        }
    }
}

/// A tool result block. A failure is reported, never dropped.
pub fn tool_result_block(tool_use_id: &str, content: &str, is_error: bool) -> Value {
    let mut block = json!({
        "type": "tool_result",
        "tool_use_id": tool_use_id,
        "content": content,
    });
    if is_error {
        block["is_error"] = json!(true);
    }
    block
}

/// The tool list, from the vault's own catalogue so the two can never disagree.
pub fn tool_definitions() -> Vec<Value> {
    markdown_vault::TOOLS
        .iter()
        .filter_map(|tool| {
            Some(json!({
                "name": tool.name,
                "description": tool.description,
                "input_schema": markdown_vault::schema(tool.name)?,
            }))
        })
        .collect()
}

pub fn system_prompt(vault_name: &str) -> String {
    format!(
        "You are an assistant embedded in a Markdown notes app, working in the vault \
         \"{vault_name}\".\n\n\
         All paths are relative to the vault root. Prefer `edit_note` over `write_note` when \
         changing an existing note: it cannot lose surrounding content. Use `search_notes` \
         and `outline` to find your way around rather than reading every note.\n\n\
         Changes are applied immediately and recorded in the vault's history, so every one \
         can be undone — but they are the user's own notes, so make the change asked for and \
         no more. If a request is ambiguous about which note is meant, ask instead of guessing."
    )
}

/// The request body for one round trip.
pub fn body(config: &AgentConfig, system: &str, messages: &[Message]) -> Value {
    json!({
        "model": config.model,
        // Large, so streaming rather than a single response: a non-streamed request this
        // size risks an HTTP timeout.
        "max_tokens": 64_000,
        "stream": true,
        // Adaptive, not a token budget: `budget_tokens` is rejected outright on Opus 5.
        "thinking": { "type": "adaptive", "display": "summarized" },
        "output_config": { "effort": config.effort },
        "fallbacks": "default",
        // Render order is tools → system → messages, so a breakpoint on the system block
        // caches the tool list and the prompt together, and only the conversation varies.
        "system": [{
            "type": "text",
            "text": system,
            "cache_control": { "type": "ephemeral" }
        }],
        "tools": tool_definitions(),
        "messages": messages,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> AgentConfig {
        AgentConfig::new("test-key")
    }

    #[test]
    fn defaults_to_opus_5_with_adaptive_thinking() {
        let body = body(&config(), "sys", &[Message::user("hi")]);
        assert_eq!(body["model"], "claude-opus-5");
        assert_eq!(body["thinking"]["type"], "adaptive");
        // `budget_tokens` is a 400 on this model; make sure it never creeps back in.
        assert!(body["thinking"]["budget_tokens"].is_null());
    }

    #[test]
    fn streams_and_asks_for_fallbacks() {
        let body = body(&config(), "sys", &[]);
        assert_eq!(body["stream"], true);
        assert_eq!(body["fallbacks"], "default");
        assert_eq!(body["max_tokens"], 64_000);
    }

    #[test]
    fn caches_the_stable_prefix_only() {
        let body = body(&config(), "sys", &[Message::user("volatile")]);
        // Exactly one breakpoint, on the system block, so tools + prompt are the cached
        // prefix and the conversation stays outside it.
        assert_eq!(body["system"][0]["cache_control"]["type"], "ephemeral");
        assert!(body["tools"][0]["cache_control"].is_null());
        assert!(body["messages"][0]["cache_control"].is_null());
    }

    #[test]
    fn sends_no_assistant_prefill() {
        // A trailing assistant turn is a 400 on Opus 5. Nothing here should ever build one.
        let body = body(&config(), "sys", &[Message::user("hi")]);
        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.last().unwrap()["role"], "user");
    }

    #[test]
    fn tools_come_from_the_vault_catalogue() {
        let tools = tool_definitions();
        assert_eq!(tools.len(), markdown_vault::TOOLS.len());
        for tool in &tools {
            assert!(tool["input_schema"]["additionalProperties"] == serde_json::json!(false));
        }
    }

    #[test]
    fn write_budget_is_capped_at_the_ceiling() {
        let mut config = config();
        config.max_write_calls = 5_000;
        assert_eq!(config.write_call_budget(), AgentConfig::WRITE_CALL_CEILING);
    }

    #[test]
    fn tool_results_are_batched_into_one_message() {
        let message = Message::tool_results(vec![
            tool_result_block("a", "one", false),
            tool_result_block("b", "two", true),
        ]);
        assert_eq!(message.role, "user");
        assert_eq!(message.content.as_array().unwrap().len(), 2);
        assert_eq!(message.content[1]["is_error"], true);
        assert!(message.content[0]["is_error"].is_null());
    }

    #[test]
    fn endpoint_tolerates_a_trailing_slash() {
        let mut config = config();
        config.base_url = "http://127.0.0.1:9/".to_owned();
        assert_eq!(config.endpoint(), "http://127.0.0.1:9/v1/messages");
    }
}
