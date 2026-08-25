//! The tool surface, as JSON in and JSON out.
//!
//! One entry point ([`call`]) and one catalogue ([`TOOLS`]), shared by the MCP server and the
//! in-app agent. Adding a tool here adds it to both at once, and neither can drift from the
//! other's idea of what a tool does — which is the whole reason this lives in Rust rather
//! than being written twice.
//!
//! Schemas carry `additionalProperties: false` and explicit `required` lists so they can be
//! used for strict tool use without further massaging.

use serde_json::{json, Value};

use crate::search::search;
use crate::store::{Vault, VaultError};

/// What a caller needs to know to expose a tool, beyond its schema.
pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    /// Safe to run without permission; nothing on disk changes.
    pub read_only: bool,
    /// Removes or relocates content, as opposed to adding or amending it. These are the only
    /// tools whose mistakes are not simply a diff, so hosts gate them separately.
    pub destructive: bool,
}

pub const TOOLS: &[ToolSpec] = &[
    ToolSpec {
        name: "list_notes",
        description: "List the folders and Markdown notes directly inside a folder of the \
                      vault. Omit `dir` for the top level. Paths are always vault-relative.",
        read_only: true,
        destructive: false,
    },
    ToolSpec {
        name: "read_note",
        description: "Read the full text of one Markdown note.",
        read_only: true,
        destructive: false,
    },
    ToolSpec {
        name: "search_notes",
        description: "Search the vault by file name and by content. Returns matching lines \
                      with the heading each one sits under, so results can be cited as \
                      `note.md#heading-anchor`.",
        read_only: true,
        destructive: false,
    },
    ToolSpec {
        name: "outline",
        description: "List the headings of one note with their anchors and line numbers. \
                      Cheaper than reading a long note when only its structure is needed.",
        read_only: true,
        destructive: false,
    },
    ToolSpec {
        name: "create_note",
        description: "Create a new note. Fails if something is already at that path; use \
                      `write_note` to replace an existing note deliberately.",
        read_only: false,
        destructive: false,
    },
    ToolSpec {
        name: "edit_note",
        description: "Replace one exact occurrence of `old_text` with `new_text` in a note. \
                      Prefer this over `write_note` for changes to an existing note: it \
                      cannot lose surrounding content, and it fails rather than guessing if \
                      the text is missing or appears more than once. Include enough \
                      surrounding text to make the match unique.",
        read_only: false,
        destructive: false,
    },
    ToolSpec {
        name: "write_note",
        description: "Replace the entire contents of a note, creating it if needed. This \
                      discards anything already in the file — prefer `edit_note` unless the \
                      note is genuinely being rewritten.",
        read_only: false,
        destructive: false,
    },
    ToolSpec {
        name: "create_folder",
        description: "Create a folder inside the vault, including any missing parents.",
        read_only: false,
        destructive: false,
    },
    ToolSpec {
        name: "move",
        description: "Move or rename a note or folder within the vault. Fails if something \
                      is already at the destination.",
        read_only: false,
        destructive: true,
    },
    ToolSpec {
        name: "delete",
        description: "Delete a note or folder. Recoverable: the deletion is recorded in the \
                      vault's history and can be undone with `undo`.",
        read_only: false,
        destructive: true,
    },
    ToolSpec {
        name: "undo",
        description: "Undo an earlier change by the commit id that change returned. The undo \
                      is itself recorded, so nothing is lost and it can be undone in turn.",
        read_only: false,
        destructive: false,
    },
];

pub fn spec(name: &str) -> Option<&'static ToolSpec> {
    TOOLS.iter().find(|tool| tool.name == name)
}

/// JSON Schema for a tool's input, or `None` for an unknown tool.
pub fn schema(name: &str) -> Option<Value> {
    let schema = match name {
        "list_notes" => object(json!({ "dir": string("Vault-relative folder. Omit for the top level.") }), &[]),
        "read_note" => object(json!({ "path": string("Vault-relative path to the note.") }), &["path"]),
        "search_notes" => object(
            json!({
                "query": string("Text to look for in note names and note contents."),
                "limit": { "type": "integer", "description": "Maximum notes to return.", "minimum": 1 }
            }),
            &["query"],
        ),
        "outline" => object(json!({ "path": string("Vault-relative path to the note.") }), &["path"]),
        "create_note" => object(
            json!({
                "path": string("Vault-relative path for the new note."),
                "content": string("Markdown to write into it.")
            }),
            &["path", "content"],
        ),
        "edit_note" => object(
            json!({
                "path": string("Vault-relative path to the note."),
                "old_text": string("Exact text to replace. Must appear exactly once."),
                "new_text": string("Replacement text.")
            }),
            &["path", "old_text", "new_text"],
        ),
        "write_note" => object(
            json!({
                "path": string("Vault-relative path to the note."),
                "content": string("Markdown that will replace the entire file.")
            }),
            &["path", "content"],
        ),
        "create_folder" => object(json!({ "path": string("Vault-relative folder to create.") }), &["path"]),
        "move" => object(
            json!({
                "from": string("Vault-relative path that exists now."),
                "to": string("Vault-relative destination path.")
            }),
            &["from", "to"],
        ),
        "delete" => object(json!({ "path": string("Vault-relative note or folder to delete.") }), &["path"]),
        "undo" => object(json!({ "commit": string("Commit id returned by an earlier change.") }), &["commit"]),
        _ => return None,
    };
    Some(schema)
}

/// Runs one tool. `Err` carries a message meant for the model to read and act on.
pub fn call(vault: &Vault, name: &str, input: &Value) -> Result<Value, String> {
    match name {
        "list_notes" => {
            let entries = vault.list(optional_str(input, "dir")).map_err(describe)?;
            Ok(json!({ "entries": entries }))
        }
        "read_note" => {
            let path = required_str(input, "path")?;
            Ok(json!({ "content": vault.read(path).map_err(describe)? }))
        }
        "search_notes" => {
            let query = required_str(input, "query")?;
            let mut hits = search(vault.root(), query);
            if let Some(limit) = input.get("limit").and_then(Value::as_u64) {
                hits.truncate(limit as usize);
            }
            Ok(json!({ "hits": hits }))
        }
        "outline" => {
            let path = required_str(input, "path")?;
            let contents = vault.read(path).map_err(describe)?;
            Ok(json!({ "headings": crate::outline::outline(&contents) }))
        }
        "create_note" => {
            let path = required_str(input, "path")?;
            let content = required_str(input, "content")?;
            committed(vault.create_file(path, content))
        }
        "edit_note" => {
            let path = required_str(input, "path")?;
            let old_text = required_str(input, "old_text")?;
            let new_text = required_str(input, "new_text")?;
            committed(vault.edit(path, old_text, new_text))
        }
        "write_note" => {
            let path = required_str(input, "path")?;
            let content = required_str(input, "content")?;
            committed(vault.write(path, content))
        }
        "create_folder" => committed(vault.create_folder(required_str(input, "path")?)),
        "move" => {
            let from = required_str(input, "from")?;
            let to = required_str(input, "to")?;
            committed(vault.move_path(from, to))
        }
        "delete" => committed(vault.delete(required_str(input, "path")?)),
        "undo" => {
            let commit = required_str(input, "commit")?;
            let id = vault.undo(commit).map_err(describe)?;
            Ok(json!({ "commit": id }))
        }
        other => Err(format!("unknown tool `{other}`")),
    }
}

// MARK: - Helpers

fn string(description: &str) -> Value {
    json!({ "type": "string", "description": description })
}

fn object(properties: Value, required: &[&str]) -> Value {
    json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false
    })
}

fn required_str<'a>(input: &'a Value, key: &str) -> Result<&'a str, String> {
    input
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("`{key}` is required and must be a string"))
}

fn optional_str<'a>(input: &'a Value, key: &str) -> Option<&'a str> {
    input.get(key).and_then(Value::as_str)
}

/// A change that did not alter the tree is reported honestly rather than as a commit.
fn committed(result: Result<Option<String>, VaultError>) -> Result<Value, String> {
    match result.map_err(describe)? {
        Some(commit) => Ok(json!({ "commit": commit, "changed": true })),
        None => Ok(json!({ "changed": false })),
    }
}

fn describe(err: VaultError) -> String {
    err.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn vault() -> (TempDir, Vault) {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(dir.path().join("notes")).unwrap();
        fs::write(dir.path().join("top.md"), "# Top\n\nbody\n").unwrap();
        fs::write(dir.path().join("notes/nested.md"), "# Nested\n\nneedle here\n").unwrap();
        let vault = Vault::open(dir.path()).unwrap();
        vault.history().commit_all("initial").unwrap();
        (dir, vault)
    }

    #[test]
    fn every_tool_has_a_schema_and_every_schema_a_tool() {
        for tool in TOOLS {
            assert!(schema(tool.name).is_some(), "no schema for {}", tool.name);
        }
        assert!(schema("not_a_tool").is_none());
    }

    #[test]
    fn schemas_are_strict() {
        for tool in TOOLS {
            let schema = schema(tool.name).unwrap();
            assert_eq!(schema["additionalProperties"], json!(false), "{}", tool.name);
            assert!(schema["required"].is_array(), "{}", tool.name);
        }
    }

    #[test]
    fn only_move_and_delete_are_destructive() {
        let destructive: Vec<_> = TOOLS.iter().filter(|t| t.destructive).map(|t| t.name).collect();
        assert_eq!(destructive, vec!["move", "delete"]);
    }

    #[test]
    fn no_read_only_tool_can_change_anything() {
        // Guards the MCP server's `--allow-write` gate, which trusts this flag.
        for tool in TOOLS.iter().filter(|t| t.read_only) {
            assert!(!tool.destructive, "{} is both read-only and destructive", tool.name);
        }
    }

    #[test]
    fn reads_and_lists() {
        let (_dir, vault) = vault();
        let content = call(&vault, "read_note", &json!({ "path": "top.md" })).unwrap();
        assert_eq!(content["content"], "# Top\n\nbody\n");

        let listing = call(&vault, "list_notes", &json!({})).unwrap();
        assert_eq!(listing["entries"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn searches_with_heading_anchors() {
        let (_dir, vault) = vault();
        let result = call(&vault, "search_notes", &json!({ "query": "needle" })).unwrap();
        let hit = &result["hits"][0];
        assert_eq!(hit["path"], "notes/nested.md");
        assert_eq!(hit["snippets"][0]["heading_id"], "nested");
    }

    #[test]
    fn outlines_a_note() {
        let (_dir, vault) = vault();
        let result = call(&vault, "outline", &json!({ "path": "top.md" })).unwrap();
        assert_eq!(result["headings"][0]["id"], "top");
    }

    #[test]
    fn writes_report_a_commit_that_undo_accepts() {
        let (_dir, vault) = vault();
        let written = call(
            &vault,
            "write_note",
            &json!({ "path": "top.md", "content": "replaced\n" }),
        )
        .unwrap();
        assert_eq!(written["changed"], json!(true));

        let commit = written["commit"].as_str().unwrap();
        call(&vault, "undo", &json!({ "commit": commit })).unwrap();
        assert_eq!(vault.read("top.md").unwrap(), "# Top\n\nbody\n");
    }

    #[test]
    fn an_unchanged_write_is_reported_as_no_change() {
        let (_dir, vault) = vault();
        let result = call(
            &vault,
            "write_note",
            &json!({ "path": "top.md", "content": "# Top\n\nbody\n" }),
        )
        .unwrap();
        assert_eq!(result["changed"], json!(false));
    }

    #[test]
    fn missing_arguments_are_explained_not_panicked_on() {
        let (_dir, vault) = vault();
        let err = call(&vault, "read_note", &json!({})).unwrap_err();
        assert!(err.contains("`path` is required"), "{err}");
    }

    #[test]
    fn an_unknown_tool_is_an_error_not_a_panic() {
        let (_dir, vault) = vault();
        assert!(call(&vault, "rm_rf", &json!({})).unwrap_err().contains("unknown tool"));
    }

    #[test]
    fn errors_come_back_as_readable_guidance() {
        let (_dir, vault) = vault();
        let err = call(
            &vault,
            "edit_note",
            &json!({ "path": "top.md", "old_text": "absent", "new_text": "x" }),
        )
        .unwrap_err();
        assert!(err.contains("not found"), "{err}");
    }

    #[test]
    fn confinement_holds_through_the_tool_layer() {
        let (dir, vault) = vault();
        let escaped = dir.path().parent().unwrap().join("escaped.md");

        for (tool, input) in [
            ("read_note", json!({ "path": "../escaped.md" })),
            ("write_note", json!({ "path": "../escaped.md", "content": "x" })),
            ("create_note", json!({ "path": "../escaped.md", "content": "x" })),
            ("create_folder", json!({ "path": "../escaped" })),
            ("delete", json!({ "path": "../escaped.md" })),
            ("move", json!({ "from": "top.md", "to": "../escaped.md" })),
            ("outline", json!({ "path": "../escaped.md" })),
        ] {
            assert!(call(&vault, tool, &input).is_err(), "{tool} allowed an escape");
        }
        assert!(!escaped.exists(), "a tool wrote outside the vault");
    }
}
