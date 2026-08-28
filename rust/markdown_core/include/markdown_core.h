//
//  markdown_core.h
//  Public C interface of the Rust `markdown_core` static library.
//
//  The library bundles the compiled Vue single page app (see rust/markdown_core/build.rs)
//  and renders Markdown to HTML.
//

#ifndef MARKDOWN_CORE_H
#define MARKDOWN_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Borrowed view of an embedded web asset. The memory is static; never free it.
typedef struct MdAsset {
  const unsigned char *data;
  size_t len;
  const char *mime;
} MdAsset;

/// Looks up a file of the embedded Vue app by URL path, e.g. "/assets/index.js".
/// Unknown paths fall back to "index.html" so client side routing keeps working.
/// Returns false (and zeroes `out`) if `path` is invalid or nothing is embedded.
bool md_asset_lookup(const char *path, MdAsset *out);

/// Checks whether `path` matches a real embedded file exactly, without md_asset_lookup()'s
/// single-page-app fallback to "index.html" — for a caller that needs to tell "this is a
/// genuine embedded UI route" apart from "nothing here, try something else".
bool md_asset_exists(const char *path);

/// Number of files baked into the library.
size_t md_asset_count(void);

/// Renders Markdown to an HTML fragment.
/// The result is a UTF-8 string owned by the caller: release it with md_string_free().
/// Returns NULL when `markdown` is NULL or not valid UTF-8.
char *md_render(const char *markdown);

/// Version of the core library. Static storage; do not free.
const char *md_version(void);

/// Frees a string returned by md_render(), md_vault_call() or md_vault_tools().
/// Passing NULL is a no-op.
void md_string_free(char *value);

/// Opaque handle to an open vault.
typedef struct MdVault MdVault;

/// Opens the notes vault at `path`, initialising its history on first use and recording a
/// baseline commit if the folder has none. Returns NULL if the path is unusable.
/// Release with md_vault_close().
MdVault *md_vault_open(const char *path);

/// Closes a vault opened by md_vault_open(). Passing NULL is a no-op.
void md_vault_close(MdVault *vault);

/// Runs one vault tool. `input_json` is the tool's arguments as a JSON object.
///
/// The reply is always a JSON object — {"ok":true,"result":{...}} or
/// {"ok":false,"error":"..."} — so a failing tool is an ordinary reply carrying a message
/// worth showing, not a NULL. NULL means the arguments themselves were unusable.
/// Release the result with md_string_free().
char *md_vault_call(MdVault *vault, const char *name, const char *input_json);

/// The tool catalogue as JSON: name, description, read_only, destructive, input_schema.
/// Lets hosts build their tool lists without hard-coding any of it.
/// Release with md_string_free().
char *md_vault_tools(void);

/// Opaque handle to an open chat session.
typedef struct MdAgent MdAgent;

/// Opens a chat session against the vault at `vault_path`, authenticating with `api_key`.
/// The key is held only in Rust for the life of the session; it is never exposed to the
/// embedded web view. Returns NULL if the vault path is unusable.
/// Release with md_agent_close().
MdAgent *md_agent_open(const char *vault_path, const char *api_key);

/// Closes a chat session opened by md_agent_open(). Passing NULL is a no-op.
void md_agent_close(MdAgent *agent);

/// Starts a turn: sends `text` and runs the agent loop on a background thread.
/// Returns false without starting anything if a turn is already in progress — call
/// md_agent_poll_event() in a loop until it returns NULL before sending the next message.
bool md_agent_send_start(MdAgent *agent, const char *text);

/// Blocks for the next event of the current turn and returns it as JSON — one of
/// {"type":"text"|"thinking", "text":...}, {"type":"tool_started", "name":...},
/// {"type":"tool_finished", "name":..., "ok":..., "detail":..., "commit":...},
/// {"type":"refused", "category":..., "explanation":...}, {"type":"failed", "message":...},
/// or {"type":"done", "stop_reason":...}.
///
/// Returns NULL once the turn has finished, or immediately if no turn is running — call this
/// in a loop on a background thread; it is never called back into by Rust.
/// Release a non-NULL result with md_string_free().
char *md_agent_poll_event(MdAgent *agent);

#ifdef __cplusplus
}
#endif

#endif /* MARKDOWN_CORE_H */
