# Architecture overview

## What this is

A Markdown notes app shipped as two native desktop apps — **macOS** (SwiftUI) and
**Windows** (WinUI 3 / C#) — sharing one **Rust core** for everything that isn't UI
chrome, plus an embedded **Vue 3** web app that renders the actual markdown preview and
document outline inside a native WebView. There's also an optional **AI assistant**
feature (an agentic chat backed by Claude/Anthropic's API) and an **MCP server** sidecar
so external tools (Claude Code, Claude Desktop) can read/search/edit the same notes
folder ("vault") from outside the app.

Repo layout:

```
markdown/
  rust/               shared core — the center of gravity
    markdown_core/      renders markdown, embeds the Vue UI, owns the C ABI
    markdown_vault/     path confinement, CRUD, git-backed undo, search, outline, tool dispatch
    markdown_agent/     Claude API agent loop (tool use, SSE streaming, safety caps)
    vendor/solomd-mcp/  vendored MCP server binary (see rust-core.md §1a — not yet unified with markdown_vault)
  vue-project/        embedded web UI — markdown preview + outline pane (not an editor)
  macos/Markdown/     SwiftUI app — full-featured (vault, chat, search, auth)
  win/MarkdownWin/    WinUI 3 app — minimal (single-file editor + preview only)
  .claude/plans/      original design plan for the vault/MCP/chat feature
```

This directory is **not a git repository** — there is no `.git` at the root. (`markdown_vault`
still creates its own `.git` *inside whatever vault folder a user opens*, which is a separate,
intentional concern — see `rust-core.md` §3.3 and `security.md`.)

## Component diagram

```
                         ┌─────────────────────────┐
                         │   Vue 3 app (preview)    │
                         │   vue-project/src/       │
                         │   compiled into dist/    │
                         └───────────▲──────────────┘
                                     │ include_bytes! at compile time (build.rs)
                                     │
┌────────────────────────────────────────────────────────────────────────┐
│                        markdown_core (Rust, C ABI)                     │
│  render.rs (pulldown-cmark + ammonia sanitize)   assets.rs (embedded)  │
│  ffi.rs         md_render, md_asset_lookup, md_version, ...            │
│  vault_ffi.rs   md_vault_open/close/call, md_vault_tools               │
│  agent_ffi.rs   md_agent_open/close/send_start/poll_event              │
└───────┬───────────────────────────────────────────────────┬───────────┘
        │ depends on                                         │ depends on
        ▼                                                     ▼
┌───────────────────┐                                ┌──────────────────────┐
│  markdown_vault    │◀───────depended on by──────────│   markdown_agent      │
│  confine / store /  │                                │  request / session /  │
│  history / search /  │                               │  sse (Claude API loop)│
│  outline / tools     │                                └──────────────────────┘
└─────────┬────────────┘
          │ same tool catalogue, duplicated logic (not yet unified)
          ▼
┌───────────────────────┐
│  vendor/solomd-mcp     │  standalone MCP server binary, bundled into the macOS app,
│  (vendored, MIT)       │  used by Claude Code / Claude Desktop over stdio
└───────────────────────┘

     ▲ links statically (.a)                    ▲ links dynamically (.dll)
     │                                            │
┌─────────────────┐                      ┌─────────────────────┐
│  macOS app        │                      │  Windows app          │
│  Swift, full-featured│                    │  C#, minimal shell    │
│  (Workspace, VaultStore,│                 │  (MainWindow, MarkdownCore.cs,│
│   ChatView, Keychain, ...) │              │   MarkdownDocument.cs)         │
└─────────────────┘                      └─────────────────────┘
```

## Data flow: editing and preview

1. User types in the native text editor (SwiftUI `TextEditor` / WinUI `TextBox`).
2. The native shell pushes the new text into the WebView via a JS bridge call
   (`window.__markdownHost.setDocument(text)`).
3. The Vue app calls back over the same bridge (`render` message) asking the native host
   to render markdown → HTML.
4. The native host calls `MarkdownCore.render(_:)` / `MarkdownCore.Render(...)`, which is a
   thin FFI wrapper over Rust's `md_render()` (`markdown_core::render::render_markdown`).
5. Rust parses with `pulldown-cmark`, then sanitizes the HTML with `ammonia` before
   returning it — this is the point where any XSS-shaped raw HTML would be stripped.
6. The HTML comes back to Vue, which injects it via `v-html` into `MarkdownPreview.vue`.
7. Vue's `useDocumentOutline` composable parses the same HTML with `DOMParser` to build the
   heading/outline sidebar, matching an equivalent slug algorithm Rust uses in
   `markdown_vault::outline` for search-result anchors.

See `frontend.md` for the exact bridge protocol and `security.md` for the sanitization
guarantee this flow depends on.

## Data flow: vault writes (create/edit/delete/move/undo)

1. macOS only, today: `Workspace` (Swift) calls `VaultStore.write(...)` (or `.edit`, etc.).
2. `VaultStore` calls `md_vault_call(handle, "write_note", jsonInput)` over FFI.
3. Rust dispatches through `markdown_vault::tools::call`, which routes to `store.rs`'s
   `write`/`edit`/`create_file`/`move_path`/`delete`.
4. Every mutation is path-confined first (`confine::resolve_in` — the one security
   boundary every write passes through) and then committed to a per-vault git repository
   (`history::commit_all`), which is what makes every change undoable.
5. A folder watcher (`VaultWatcher`, FSEvents) notices the change and refreshes the UI's
   file tree, reloading the open file only if there are no unsaved local edits.

The Windows app has **no equivalent path today** — see `windows-app.md` for the gap list.
The same `tools.rs` dispatch is also what the AI chat agent and the vendored MCP server
use (in principle — see the caveat about `solomd-mcp` below).

## Data flow: AI chat (macOS only, currently)

1. User opens the chat sheet; `ChatViewModel` opens an `AgentClient` for the current vault
   root, using the Anthropic API key from `Keychain.apiKey()`.
2. `AgentClient` calls `md_agent_open(vaultPath, apiKey)`, then `md_agent_send_start(text)`.
3. Rust's `markdown_agent::Agent` runs a synchronous tool-use loop on a background thread:
   POST to `https://api.anthropic.com/v1/messages` (streamed SSE), parse deltas, dispatch
   any `tool_use` blocks through the *same* `markdown_vault::tools::call` writes go
   through, batch all `tool_result`s into one message, loop until the model stops or a cap
   is hit.
4. Events (`text`, `thinking`, `tool_started`, `tool_finished`, `refused`, `failed`, `done`)
   are pushed through an internal channel; the Swift side polls them one at a time via the
   blocking `md_agent_poll_event(handle)` — there is no callback from Rust into
   Swift/C#, by design (see `rust-core.md` §2.3 and §4.4).
5. Because agent writes go through the same vault tool dispatch as manual edits, they get
   the same git-backed undo — though **the Swift chat UI doesn't currently expose an Undo
   button** even though the commit id is available in every tool-result event (see
   `macos-app.md` gotcha list).

## MCP server (external agent access)

The design plan proposed a from-scratch `markdown_mcp` Rust crate reusing `markdown_vault`
directly. That crate was **not built**. Instead, the upstream open-source `solomd-mcp`
server was vendored wholesale (`rust/vendor/solomd-mcp`, MIT, see its own `PROVENANCE.md`)
and built/bundled as-is into the macOS app bundle (Windows packaging for it does not exist
yet). Critically, `solomd-mcp` ships **its own independent path-confinement and git-history
logic**, not `markdown_vault`'s — two separate implementations of the same security
boundary currently coexist in this repo, unconverged. See `security.md` and
`rust-core.md` §1a for detail; this is the single most consequential piece of technical
debt uncovered while writing this documentation.

## Per-platform feature-parity matrix

| Feature | macOS | Windows |
|---|---|---|
| Markdown preview (Rust render + Vue UI) | ✅ | ✅ |
| Document outline sidebar | ✅ (toolbar open/close panel, right side of the webview layout — not a persisted Settings toggle any more) | ⚠️ bridge exists but no settings/toggle UI to drive it |
| Per-file-kind viewers (image pan/zoom, PDF view + page thumbnails, plain-text edit for non-Markdown text files) | ✅ (`FileKind`, `ImageViewer.swift`, `PDFViewerView.swift` — see `macos-app.md` §3) | ❌ (explicitly not built yet; design captured in `.claude/plans/file-type-viewers-plan.md`) |
| Single-file open/save | ✅ (via vault) | ✅ (plain file I/O, no vault) |
| Folder/vault browsing (sidebar, file tree) | ✅ (`SidebarView`, `FileNode`) | ❌ |
| Sidebar create/rename/delete + All-vs-Markdown filter | ✅ (`Workspace` mutation API, `SidebarFilter` — see `macos-app.md` §4) | ❌ (explicitly not built yet; tracked as a follow-up in `.claude/plans/sidebar-file-management-plan.md`) |
| Vault writes with git-backed undo | ✅ (`VaultStore`) | ❌ (no `vault_*` FFI calls at all) |
| Folder search | ✅ (`FolderSearch.swift`, plus vault's `search.rs` via tools) | ❌ |
| External-change watching (live reload) | ✅ (`VaultWatcher`, FSEvents) | ❌ |
| AI chat assistant | ✅ (`ChatView`/`ChatViewModel`/`AgentClient`) | ❌ (no `agent_*` FFI calls; `systemAIModels` capability declared in the app manifest but unused) |
| Credential storage (Anthropic API key) | ✅ (macOS Keychain) | ❌ (no Credential Manager usage) |
| Settings UI | ✅ | ❌ |
| MCP server sidecar bundled with the app | ✅ (macOS-only build step) | ❌ |
| App sandboxing | ✅ (`ENABLE_APP_SANDBOX = YES` in `project.pbxproj`, plus an explicit `Markdown.entitlements` since 2026-08-28 adding app-scope bookmarks and an app group — see `security.md` §6) | N/A (Windows model differs; `runFullTrust` capability declared) |

This matches the design plan's own framing: **"Windows gets everything except the
shell."** Everything Windows-specific still to build is enumerated in `windows-app.md` §7.
