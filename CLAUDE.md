# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this project is

A Markdown notes app shipped as two native desktop apps, **macOS** (SwiftUI) and
**Windows** (WinUI 3 / C#), sharing one **Rust core** for rendering, storage, and an AI
agent loop, plus an embedded **Vue 3** web UI for the markdown preview/outline pane. It
also ships an **MCP server** sidecar (macOS only, currently) so Claude Code / Claude
Desktop can read, search, and edit the same notes folder from outside the app.

This repository is **not a git repository** — there is no `.git` at the root. Don't run
`git status`/`git log`/branch commands here expecting them to work at the top level.
(`markdown_vault` *does* create its own `.git` inside whatever notes folder — "vault" — a
user opens in the app; that's a separate, per-vault repository used for undo history, not
this repo's own version control.)

## Repo layout

```
markdown/
  rust/               shared core — read this first for anything cross-platform
    markdown_core/      renders markdown (pulldown-cmark + ammonia sanitize), embeds the
                         Vue UI as bytes, owns the C ABI (ffi.rs, vault_ffi.rs, agent_ffi.rs)
    markdown_vault/     path confinement, CRUD, git-backed undo, lexical search, outline,
                         and the single tool-dispatch surface (tools.rs) everything shares
    markdown_agent/     Claude/Anthropic agentic loop (SSE streaming, write/loop caps)
    vendor/solomd-mcp/  vendored MCP server binary — NOT yet unified with markdown_vault
                         (it has its own independent confinement/history logic — see
                         .claude/docs/security.md)
  vue-project/        embedded web UI — a preview + outline pane, not an editor
  macos/Markdown/     SwiftUI app — full-featured (vault writes, search, chat, auth)
  win/MarkdownWin/    WinUI 3 app — vault, watcher, autosave, search, chat, and account,
                      mirroring macOS file-for-file (added 2026-08-24); no MCP server, and
                      unverified end-to-end against a real vault or a real API key
  .claude/docs/       generated deep-reference docs — READ THESE before making non-trivial changes
  .claude/plans/      original design plan for the vault/MCP/chat feature
```

## Start here: `.claude/docs/`

Comprehensive, per-subsystem documentation already exists — read the relevant doc before
touching a subsystem you haven't worked in yet:

- **[architecture.md](.claude/docs/architecture.md)** — system overview, component
  diagram, data flow, per-platform feature-parity matrix. Read this first.
- **[rust-core.md](.claude/docs/rust-core.md)** — full C ABI table, vault tool catalogue,
  agent loop internals, test coverage.
- **[macos-app.md](.claude/docs/macos-app.md)** — Swift app internals.
- **[windows-app.md](.claude/docs/windows-app.md)** — C# app internals and its (large)
  gap list vs. macOS.
- **[frontend.md](.claude/docs/frontend.md)** — Vue app, native bridge protocol.
- **[security.md](.claude/docs/security.md)** — confinement, sanitization, credentials,
  safety caps, and ranked open gaps. **Read before touching anything that writes to disk,
  renders untrusted content, or handles the API key.**
- **[build-and-development.md](.claude/docs/build-and-development.md)** — how to build,
  run, and test every piece, including non-obvious build-script workarounds.

These were generated 2026-08-24 by reading every source file across all four platforms.
Treat them as a snapshot — re-verify specifics against the code before relying on them for
anything load-bearing, and update the relevant doc when you change something it describes.

## Architectural invariants — do not violate these

1. **All filesystem writes to a vault go through `markdown_vault::tools::call`** (or its
   FFI wrapper `md_vault_call`). Never add a second path that touches vault files
   directly from Swift/C#/JS — that's exactly the mistake already made once with the
   vendored `solomd-mcp` server, which now has to be reconciled back onto this single
   path (see `security.md` §1).
2. **Every mutating vault tool must go through `confine::resolve_in`** and get a git
   commit via `history::commit_all`. This is what makes writes both safe (can't escape
   the vault) and recoverable (undoable). No exceptions, no "trusted" fast path.
3. **Adding a new vault tool means editing exactly one place**: `markdown_vault::tools.rs`
   (name, schema, `read_only`/`destructive` flags, implementation). The C ABI, Swift
   facade, and C# facade are deliberately generic (`call(name, json)`) so they never need
   to change. If you find yourself adding a new FFI function for a new operation, stop —
   you're probably duplicating the dispatch pattern instead of extending it.
4. **Rust never calls back into Swift/C#.** The agent event loop is poll-based
   (`md_agent_poll_event` blocks) specifically to avoid GC/lifetime hazards calling into
   managed code. Don't introduce a callback-based FFI pattern.
5. **HTML rendered for the preview must go through `markdown_core::render::render_markdown`**,
   which sanitizes with `ammonia`. This is the only thing currently preventing a
   maliciously-crafted note (or agent-authored note) from executing script in the
   WebView via `v-html`. There is no client-side sanitization backstop in the Vue layer —
   see `security.md` §2. Never add a rendering path that skips sanitization.
6. **Write/loop safety caps are checked before dispatch, not after.** If you touch
   `markdown_agent::session`, preserve the check-then-maybe-call ordering — a cap that
   increments a counter after calling a tool is not the same guarantee.
7. **The Anthropic API key never crosses the native↔web bridge.** It lives in the OS
   keychain (macOS) and is handed to Rust per-session via `md_agent_open`; it must never
   become reachable from the Vue/JS layer, which renders untrusted content.
8. **Outline slug generation must stay identical in Rust and TypeScript.**
   `markdown_vault::outline::slugify` and `vue-project/src/composables/useDocumentOutline.ts`'s
   slug rule are deliberately mirrored byte-for-byte so search-result anchors and preview
   anchors agree. If you change one, port the change to the other and check both test
   suites.

## Known gaps worth knowing before you start (see `security.md` and `windows-app.md` for detail)

- Two independent path-confinement implementations exist (`markdown_vault::confine` vs.
  vendored `solomd-mcp`'s `safety.rs`) — not yet converged.
- The macOS app currently has **no App Sandbox entitlements**, despite `rust/README.md`
  assuming a sandboxed app.
- The chat UI has no Undo button on **Windows** (`ChatMessage.ToolCommit` is populated but
  unused in `ChatView.xaml`/`.xaml.cs`), despite the commit id being available on every
  tool-result event. macOS has one as of 2026-08-25 (`ChatViewModel.undo(commit:vaultRoot:)`
  in `ChatViewModel.swift`) — port the same shape to Windows.
- Windows now mirrors macOS's vault, watcher, autosave, search, chat, and account/settings
  code file-for-file (`win/MarkdownWin/MarkdownWin/VaultStore.cs`, `VaultWatcher.cs`,
  `Workspace.cs`, `FolderSearch.cs`, `ChatView.xaml.cs`, `Account.cs`, added 2026-08-24) —
  it is no longer a minimal single-file editor. It still has no MCP server (macOS only, by
  design), and none of this has been exercised end-to-end against a real vault or a real
  API key — treat it as unverified, not absent.
- The Vue frontend has no automated tests and no mock bridge for `npm run dev` — real
  behavior can only be exercised inside a native host.

## Build/test quick reference

```sh
cd rust && cargo test                      # ~143 Rust unit tests, network-free
cd rust && MARKDOWN_SKIP_UI_BUILD=1 cargo build   # skip rebuilding the Vue UI
cd vue-project && npm run build-only       # build the embedded UI (what Rust's build.rs runs)
```

macOS: open `macos/Markdown/Markdown.xcodeproj` in Xcode (builds Rust automatically via a
run-script phase). Windows: open `win/MarkdownWin/MarkdownWin.slnx` (builds Rust
automatically via an MSBuild target). Full detail, including easy-to-regress build-script
gotchas (macOS MCP-binary code-signing, Windows network-share path overrides), is in
`.claude/docs/build-and-development.md`.

## Working conventions

- This is a small, single-maintainer-style codebase with heavy inline documentation
  (doc comments explain *why*, not just *what*) and thorough unit tests, especially in
  Rust. Match that bar: don't add a vault operation, FFI function, or safety check without
  a test, and don't remove an existing test to make a change easier.
- Prefer extending `markdown_vault::tools.rs` and its schema/tests over adding new FFI
  surface — see invariant #3 above.
- When changing anything under `rust/`, run `cargo test` before considering the change
  done — the suite is fast (network-free, in-process stub servers) and catches
  regressions in confinement, sanitization, and the agent caps that are easy to
  reintroduce accidentally.
- No `.md`/planning files beyond what's asked for — this repo already has a docs
  convention (`.claude/docs/`, `.claude/plans/`); put new reference material there rather
  than scattering ad hoc notes elsewhere.
