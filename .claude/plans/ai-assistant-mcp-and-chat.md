# AI assistant: MCP server + in-app chat agent

## Context

Two ways to point an AI agent at the notes vault:

1. An **MCP server** so Claude Code / Claude Desktop can read, search, create, and edit the  
notes folder from outside the app.
2. An **in-app chat panel** driving the same operations from a Claude agent loop.

Both reduce to the same thing — a trustworthy way to *mutate the vault* — so this is one  
shared Rust core with thin front ends over it.

Two constraints shape everything:

- **The app cannot write anything today.** `Workspace` reads a file into `text` and stops:  
no save, no create, no delete, edits live only in memory. Neither feature is buildable  
until that exists. It is the riskiest part of this work, not a warm-up.
- **The project already has a cross-platform seam.** `MarkdownCore.cs` says it outright —  
*"Mirrors MarkdownCore.swift on macOS"* — two thin facades over one Rust library. Logic  
belongs in Rust or in the Vue app; the Swift and C# shells stay thin. An earlier draft of  
this plan put the vault in Swift, which would have meant a full C# rewrite plus a third  
copy of path confinement.

Decisions: vault logic, MCP server, and agent loop all in **Rust**; chat panel in **Vue**,  
shared by both apps; agent writes **auto-apply with undo**; retrieval is **lexical search +**  
**MCP resources**; the MCP server talks **straight to disk**.

## Prior art: SoloMD (`/Volumes/T7/Projects/MNote/solomd-main`)

MIT-licensed, shipped at v4.6, Tauri 2 + Vue 3. It solves this exact problem, and every  
structural decision above independently matches what it ships:


| This plan                            | SoloMD                                                                                                                          |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| MCP server in Rust + `rmcp`          | `solomd-mcp`, Rust + `rmcp`                                                                                                     |
| Agent loop in Rust, not the web view | `agent_run.rs` / `agent_tools.rs` in the Tauri backend                                                                          |
| Chat panel in the shared web UI      | Vue Agent Panel                                                                                                                 |
| Keys in the OS keychain              | `ai_keystore.rs`                                                                                                                |
| stdio, straight to disk              | stdio only, no network port                                                                                                     |
| One path-confinement module          | `safety.rs::resolve_in` — near-identical, including the canonicalise-the-parent trick for writes to files that do not exist yet |


Three things it does **better**, folded into the phases below: git instead of a bespoke  
journal, caps enforced before dispatch, and read-only as the default on the external  
surface. One thing it does more conservatively: its entire write surface is `write_note`,  
`append_to_note`, and `autogit_rollback` — **no delete, no move, no create\_folder**. Folders  
are in scope here because you asked for them, so they carry the strictest gate.

**Worth deciding before Phase 1:** `solomd-mcp` is MIT, standalone, and works on any  
markdown folder (it skips `.git`, `.solomd`, `node_modules` when walking). Pointing it at  
the vault would deliver Phase 1 today with no code written, leaving only the in-app agent to  
build. Forking it later costs an `rmcp` upgrade — it pins 1.5, current is 3.1.4.

## Architecture

```
Claude Code / Desktop ──stdio──▶ markdown_mcp ─────┐
                                                   ├──▶ markdown_vault ──▶ disk
ChatPanel.vue ──bridge──▶ Swift / C# ──FFI──▶ markdown_agent ──┘
                                                    (confine • store •
                                                     journal • search)
```

Everything of consequence is written once. Each platform contributes a thin facade, a folder  
watcher, autosave, and a credential lookup — no vault logic, no agent loop, no chat UI.

```
rust/
  markdown_core/    existing — render + embedded Vue assets
  markdown_vault/   new — confinement, store, journal, search, outline, tools
  markdown_mcp/     new — rmcp stdio server binary
  markdown_agent/   new — Claude agent loop
```

---

## Phase 0 — `markdown_vault` crate (foundation)

New crate in the existing cargo workspace (`rust/Cargo.toml` `members`), linked into the  
current `markdown_core` FFI so both apps reach it through the facade pattern they have.


| Module       | Responsibility                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `confine.rs` | **The security boundary.** Resolve → standardize → resolve symlinks → reject anything outside the root: `../` escapes, absolute paths, symlinks pointing out of the vault. One copy, exhaustively tested.                                                                                                                                                                                          |
| `store.rs`   | `read`, `write`, `create_file`, `create_folder`, `move`, `delete`. Every mutation commits through `history.rs`, so `delete` is recoverable by revert and needs no `.trash/` of its own.                                                                                                                                                                                                            |
| `history.rs` | **Git, not a bespoke journal.** Vendored `libgit2` (`git2`), a repo inside the vault, one commit per save and per agent write. Undo is `revert`; the chat panel's per-operation undo reverts one commit. Never auto-pushed. Replaces the hand-rolled journal + `.trash/` of the first draft: real diffs, crash-safe, and no custom format to get wrong — the mechanism SoloMD proved with AutoGit. |
| `search.rs`  | Lexical ranking over names and contents, heading-anchored snippets. Port the caps already tuned in `FolderSearch.swift` (skip huge files, few snippets each, bounded results).                                                                                                                                                                                                                     |
| `outline.rs` | Heading extraction and slugs matching `vue-project/src/composables/useDocumentOutline.ts`, so anchors line up with the preview.                                                                                                                                                                                                                                                                    |
| `tools.rs`   | `tool_call(name, input_json) -> result_json` — one entry point shared by the MCP server and the agent, so adding a tool never touches Swift, C#, or the server.                                                                                                                                                                                                                                    |


**FFI + facades:** extend `ffi.rs` and `include/markdown_core.h`; add a `VaultStore.swift`  
beside `MarkdownCore.swift` and a `VaultStore.cs` beside `MarkdownCore.cs`. JSON in, JSON  
out — the marshalling `md_render` already does.

**Sanitize the renderer** (see the security finding below) before anything can write.

**App side, per platform and thin:**

- Debounced autosave plus flush on file switch and quit. Required, not optional: without it  
an agent write and an unsaved buffer silently destroy each other.
- A folder watcher (FSEvents / `ReadDirectoryChangesW`) refreshing `FileNode` and reloading  
the open file **only when the buffer is clean**; a dirty buffer is flagged, never clobbered.

---

## Phase 1 — `markdown_mcp` (Rust, `rmcp`)

A second binary target in the workspace linking `markdown_vault` directly, so confinement  
and search stay at exactly one copy. `rmcp` is the official  
`modelcontextprotocol/rust-sdk` — v3.1.4, \~22M downloads, actively released.

Ships as a **single static binary**: no runtime to bundle, and it cross-compiles for Windows  
with the toolchain this repo already uses for the WinUI `cdylib`. Registered in Claude  
Code's `.mcp.json` and Claude Desktop's config by path. MCPB packaging stays available for  
one-click install but is no longer required to carry a runtime.

Vault root from `MARKDOWN_VAULT` or `--vault`.

**Tools — one per action** (10, well under the \~15 threshold): `list_notes`, `read_note`,  
`search_notes`, `outline`, `create_note`, `edit_note` (targeted `old_text`/`new_text`  
replace — the default Claude should reach for), `write_note`, `create_folder`, `move`,  
`delete`. Annotate read-only vs `destructiveHint`; the connector review criteria require  
that split. Each is a thin wrapper over `vault::tools::tool_call`.

**Read-only by default.** Writes require `--allow-write`; without it the write tools are  
present but return an error explaining how to enable them. Claude Desktop and Claude Code  
are a surface you are not watching while it runs — a different trust boundary from the  
in-app chat, and SoloMD ships exactly this default. `delete` and `move` sit behind a further  
`--allow-destructive`, since they are the only tools whose mistakes are not a diff.

**Resources:** each note as `note://<relative-path>` so hosts can browse and attach  
directly. That plus `search_notes` *is* the retrieval layer — no embedding service, no index  
to keep fresh.

---

## Phase 2 — `markdown_agent` + `ChatPanel.vue`

### Why the loop is in Rust, not the web view

The tempting shortcut — call the API straight from Vue with `fetch` — is unsafe here. A  
crafted note can execute script in the web view (finding below), so an API key reachable  
from JS is exfiltratable. **The key stays native** (Keychain on macOS, Credential Manager on  
Windows), is handed to Rust at call time, and never crosses the bridge.

### `markdown_agent` (Rust, `reqwest`)

Raw HTTP to `POST /v1/messages` — there is no Anthropic SDK for Rust or Swift, so this is  
the documented raw-HTTP shape:

- `model: "claude-opus-5"`, `thinking: {type: "adaptive"}` — **not** `budget_tokens`, which  
returns 400 on Opus 5
- `output_config: {effort: "high"}`, `stream: true`, `max_tokens: 64000`
- Server-side fallbacks by default: beta `server-side-fallback-2026-07-01` +  
`fallbacks: "default"`; check `stop_reason` before reading `content`, and handle  
`stop_reason: "refusal"` with its `stop_details.category`
- Prompt caching: stable system prompt and tool list first, volatile turns after the last  
`cache_control` breakpoint; confirm with `usage.cache_read_input_tokens`
- No assistant prefill (400 on Opus 5)

Manual `while stop_reason == "tool_use"` loop dispatching into `vault::tools`. Rules that  
bite if missed: run parallel `tool_use` blocks concurrently and return **all** `tool_result`  
blocks in a **single** user message; failures come back with `is_error: true`, never  
dropped; parse `tool_use.input` as JSON rather than string-matching it.

**Caps, refused before dispatch** — the cheapest safety in the whole plan, and the first  
draft had none. A per-turn **write cap** (default 5, hard ceiling 50) and a **tool-loop cap**  
(default 8 round-trips), both checked *before* a tool runs, so a model that decides to  
rewrite two hundred notes is stopped before the first one. A turn also refuses to start on a  
dirty working tree, so agent commits never entangle with unsaved human edits. All three are  
SoloMD's defaults, and they cost almost nothing to implement.

Each turn writes a `trace.jsonl` (prompt / model\_call / tool\_call / tool\_result / done) next  
to the run history — the thing that makes "why did it do that" answerable after the fact.

**Event delivery — no callback ABI.** `md_agent_next_event(handle)` blocks and returns one  
JSON event (text delta, tool call, tool result, done). Each shell calls it on a background  
thread and marshals to its UI thread. This avoids Rust calling back into managed code, which  
on the C# side needs `GCHandle` care to stay alive across the boundary.

### `ChatPanel.vue`

Rendered beside the preview over the existing `markdownBridge` — the channel that already  
carries `setDocument` and `setPreferences`. The host pushes `appendChatEvent`; the panel  
sends user turns back. Shows streamed text, a row per tool call naming the file it touched,  
and an inline **Undo** wired to `journal.rs`.

Assistant replies render through the same Markdown path, so they go through the sanitization  
below before `v-html` — model output is not trusted input either.

---

## Security finding (pre-existing, now load-bearing)

`render.rs` sets no HTML-filtering option, so `pulldown-cmark` passes raw HTML through per  
CommonMark, and `MarkdownPreview.vue:12` injects it with `v-html`. A note containing  
`<img src=x onerror=…>` executes script in the web view **today**.

The comment there — *"Trusted content: … from the user's own document"* — holds only while  
you author every note yourself. This feature breaks that assumption: an AI agent and any MCP  
client will now write notes. **Add sanitization in** `render.rs` (drop or escape raw HTML  
and `javascript:` URLs) in Phase 0, before anything gains the ability to write. It is a small  
change at the one place every host renders through, and it is what makes a Vue chat panel  
safe to add at all.

---

## Verification

1. **Confinement first** — exhaustive Rust tests over `../`, absolute paths, symlinks out of  
the vault, and percent-encoded and unicode variants. The one place a bug is a security  
bug rather than a UX bug.
2. **Sanitization** — Rust tests asserting `<script>`, `onerror=`, and `javascript:` hrefs  
do not survive `render_markdown`.
3. **MCP server** — `npx @modelcontextprotocol/inspector` (protocol-level over stdio, so  
language-agnostic) across every tool and resource, then a real Claude Code session  
against a scratch vault.
4. **Agent loop without network** — a stub HTTP server replaying a canned transcript  
(text → parallel `tool_use` → `tool_result` → `end_turn`), so loop correctness, parallel  
dispatch, and `is_error` handling are testable without tokens or connectivity.
5. **Caps and undo** — Rust tests proving the write cap and loop cap refuse *before* any  
side effect, that a dirty tree blocks a turn, and that reverting an agent commit restores  
the exact prior bytes.
6. **End to end in the app** — the probe technique used throughout this session: temporary  
`NSLog` instrumentation driven from a `.task` against a fixture vault in the app  
container, covering tool dispatch, git undo, and watcher refresh; removed after.
7. **All toolchains clean** — `cargo test` (workspace-wide), `npm run build`, `xcodebuild`.
8. **Live-write smoke test** — edit a note from Claude Code with the app open; the tree and  
preview refresh, and a dirty buffer is left untouched.

---

## Consequences worth accepting knowingly

- **Auto-apply means a wrong tool call reaches disk before you see it.** Git history plus  
the pre-dispatch caps are what make that recoverable — load-bearing, not polish. If you  
later want approval instead, SoloMD's upgrade path is proven and needs no rework: run each  
turn on its own branch (`agent/<run-id>`), then **accept** = merge, **reject** = delete the  
branch and the run vanishes from history entirely.
- **Adding a git repo to the vault is a real product decision**, not just an undo mechanism.  
It means a `.git` directory appears in the notes folder, and vaults already under git (or  
syncing through Dropbox/iCloud) need thinking about. Cheaper than a bespoke journal and far  
more capable, but not invisible.
- **Streaming crosses the bridge**, the price of a chat panel both apps share. The bridge  
already pushes per-keystroke document updates, so the volume is not new.
- **Cost:** Opus 5 is $5 / $25 per MTok, and a chat that reads much of a vault adds up.  
Prompt caching and `effort` tuning are cheaper to build in now than to retrofit.
- **Windows gets everything except the shell.** WinUI needs a `VaultStore.cs` facade, a  
watcher, autosave, and a credential lookup. The vault, MCP server, agent loop, and chat  
panel are all shared.
- **Rust is now the centre of gravity.** Four crates instead of one, and work that would  
have been Swift is Rust — a deliberate trade for writing the security boundary once.
- **Scope.** Far larger than anything else in this session; Phase 0 rewrites how documents  
load and save. The phases are independently shippable and worth landing in order.

