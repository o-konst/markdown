# Security reference

This app lets both a human and, increasingly, an AI agent mutate a folder of the user's
notes, and renders arbitrary markdown (including embedded raw HTML) inside a WebView. Two
things make that safe in principle: **path confinement** (nothing escapes the vault
folder) and **HTML sanitization** (nothing executes script in the preview). This doc
summarizes both, plus credential handling, safety caps, and — importantly — the gaps that
are still open.

## 1. Path confinement — status: strong, well-tested, but duplicated

`markdown_vault::confine::resolve_in` (see `rust-core.md` §3.1) is the single
implementation every vault-mutating/reading operation is required to route through:
rejects `..` traversal outright (doesn't normalize it away), rejects absolute
paths/Windows drive letters/UNC paths, canonicalizes and resolves symlinks before a
component-wise (not string-prefix) containment check, and handles the write-to-a
not-yet-existing-file case by confining the parent directory instead. 16 dedicated tests
include adversarial cases: symlink escapes (both read and write), percent-encoding (not
decoded — `%2e%2e` stays a literal filename), and the sibling-directory string-prefix bug
(`/vault-evil` vs `/vault`).

**Open gap: this boundary is implemented twice.** The vendored MCP server
(`rust/vendor/solomd-mcp`) ships its **own independent** `safety.rs` path-confinement
logic, completely separate from `markdown_vault::confine`. Nothing in the repo confirms
the two implementations are equivalent, and there's no shared test suite exercising both
against the same adversarial inputs. The vendoring author's own `PROVENANCE.md` names the
intended fix (repoint `solomd-mcp`'s tools at `markdown_vault::tools::call`, delete its
`safety.rs`/`workspace.rs`) as *not yet done*. **This is the most consequential open
security item found while documenting this codebase** — until it's converged, any
divergence between the two confinement implementations is a potential escape that would
only be caught in one of the two code paths.

## 2. HTML sanitization — status: fixed

The design plan (`.claude/plans/ai-assistant-mcp-and-chat.md`) flagged that `render.rs`
set no HTML-filtering option, so raw HTML in a note (e.g. `<img src=x onerror=…>`) would
pass straight through `pulldown-cmark` into the Vue preview's `v-html`, executing script
in the WebView. **This has been fixed**: `render.rs` now pipes rendered HTML through an
`ammonia::Builder` (an allow-list HTML sanitizer) before returning it, widened only for
what the renderer itself emits (generic `id`/`class` attributes, disabled task-list
checkboxes). Ten Rust tests directly assert `<script>`, `onerror=`, and `javascript:`
hrefs do not survive `render_markdown` (see `rust-core.md` §2.1).

**This fix is single-layered.** `vue-project/src/components/MarkdownPreview.vue` still
uses `v-html="html"` with no client-side sanitizer (no DOMPurify or equivalent) — see
`frontend.md` §7. That's an acceptable design *given* the Rust-side guarantee holds, but
it means there is no defense-in-depth: any future render path that skips
`markdown_core::render::render_markdown` (a new renderer, a different asset-serving
route, a bug in the ammonia builder configuration) would have nothing to catch it before
`v-html`. Treat `render.rs`'s test suite as a hard gate on any change touching rendering.

This fix is what makes shipping agent-writable notes safe at all: once an AI agent (or an
external MCP client) can author notes, a malicious or compromised note author's payload
has to survive rendering, and now it doesn't.

## 3. Credential handling

- The Anthropic API key is entered in **macOS Settings** (`SettingsView.swift`) and stored
  in the **macOS Keychain** (`Keychain.swift`) under service
  `com.ogay.webviewtest.Markdown.anthropic-api-key`,
  `kSecAttrAccessibleAfterFirstUnlock`. It is **never** stored in `UserDefaults` and
  **never** pushed into the WebView/JS layer.
- It's passed into Rust per-session via `md_agent_open(vault_path, api_key)`
  (`agent_ffi.rs`), held only inside the `Agent`/`AgentConfig` struct, and attached as the
  `x-api-key` request header when calling `https://api.anthropic.com/v1/messages`. Rust
  necessarily sees the raw value at call time but never persists or logs it — the JSONL
  `Trace` only records prompt text, tool calls/results, and control-flow events, never
  request headers or config.
- **The key never crosses the native↔web bridge** — this is deliberate defense-in-depth
  independent of the sanitization fix above: even if a future rendering bug reintroduced
  script execution in the preview, the API key still wouldn't be reachable from JS,
  because it never reaches the process boundary that renders untrusted content.
- **Windows has no credential storage implemented at all** — there is no chat feature on
  Windows, so no Credential Manager usage exists yet (`windows-app.md` §7).

## 4. Write/loop caps (agent safety)

`markdown_agent::session::Agent` enforces three checks, all **before** any side effect,
not after:

1. **Dirty-tree refusal**: a turn refuses to start at all if the vault's git working tree
   is dirty (`history().is_dirty()`) — so an agent's commits never entangle with unsaved
   human edits. Tested to make zero HTTP requests in this case.
2. **Write cap**: `max_write_calls` (default 5, hard ceiling 50 via
   `WRITE_CALL_CEILING`) is checked *before* dispatching each mutating tool call — a tool
   call past the cap is never executed, just answered with an `is_error: true` result
   explaining the limit. Tested directly (`the_write_cap_refuses_before_the_file_changes`).
3. **Tool-loop cap**: `max_tool_rounds` (default 8) bounds how many request/tool-dispatch
   round-trips one turn can make; exceeding it emits a `Failed` event rather than looping
   forever. Tested with a model script designed to never stop asking for tools.

All three caps are enforced identically regardless of which tool is being called, because
they gate at the dispatch layer (`run_tools()` in `session.rs`), not per-tool.

## 5. Recoverability as a safety net

Every mutation — human or agent — goes through `markdown_vault::history` (a git repo
inside the vault), so even a wrong tool call reaching disk is a revertable commit, never
silent data loss. `Vault::open` bakes a baseline commit on first adoption of a folder so
even the very first write is undoable back to the pre-existing content. `revert()` applies
the inverse as a *new* commit rather than rewriting history, so undo is itself undoable.
This is the trade the design plan explicitly accepted in exchange for auto-apply writes
(no approval step before an agent's edit lands on disk).

**Gap**: the macOS chat UI doesn't currently expose an Undo action, even though every
tool-result event carries the commit id needed to call `VaultStore.undo(commit:)`
(`macos-app.md` §6, §10).

## 6. App-level sandboxing

**macOS**: the app **is sandboxed**. Before 2026-08-28 this was done entirely through
declarative Xcode 16+ build settings (`ENABLE_APP_SANDBOX = YES`,
`ENABLE_USER_SELECTED_FILES = readwrite`, `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` in
`Markdown.xcodeproj/project.pbxproj`) with **no `.entitlements` file on disk at all** —
Xcode synthesizes the entitlements at sign time, which is why an earlier pass of this doc
(and a plain `find -iname "*.entitlements"`) concluded there was no sandboxing; the
synthesized result is only visible via `codesign -d --entitlements - Markdown.app`, which
showed `com.apple.security.app-sandbox`, `.files.user-selected.read-write`, and
`.network.client` all `true`. As of 2026-08-28 there is also an explicit
`macos/Markdown/Markdown/Markdown.entitlements` (via `CODE_SIGN_ENTITLEMENTS` in both
build configs), added to support the Recent Vaults feature
(`.claude/plans/recent-vaults-plan.md`): it adds
`com.apple.security.files.bookmarks.app-scope` (required to resolve a security-scoped
bookmark in a *later* launch — without it, a sandboxed app's persisted bookmarks can't
actually be reopened after quitting) and `com.apple.security.application-groups`
(`group.com.ogay.webviewtest.Markdown`, used by `RecentVaultsStore` so the same recent-
vaults list could later be read by another target — a Share Extension, widget, or the MCP
server sidecar — none of which exist yet). `rust/README.md`'s assumption of eventual
sandboxing is therefore already true, not just a target state.

**Given this, revisit `security.md` §1's `solomd-mcp` vendored server** the next time
sandboxing-sensitive behavior changes here — it has its own independent confinement logic
and was vendored/built assuming no sandbox constraints applied to the host app; that
assumption should be re-checked now that the sandbox is confirmed active.

**Windows**: `Package.appxmanifest` declares `runFullTrust` (broad access, no itemized
capabilities needed) plus an unused `systemAIModels` capability. No sandboxing model
equivalent to macOS App Sandbox is in play; this is normal for an unpackaged WinUI 3 app
but worth knowing if MSIX Store packaging is ever pursued.

## 7. Summary of open items, ranked by consequence

1. **Two independent path-confinement implementations** (`markdown_vault::confine` vs.
   `solomd-mcp`'s `safety.rs`) — unconverged, unverified for parity. (§1)
2. **No client-side HTML sanitization backstop** in the Vue preview — currently fine
   because Rust sanitizes, but a single point of failure. (§2)
3. **The macOS app has been sandboxed since before this doc's last full pass** (previously
   reported here as not sandboxed — that was stale; declarative build settings synthesize
   the entitlements with no `.entitlements` file needed, which is what hid it from a plain
   file search). Confirm `solomd-mcp`'s own confinement logic still behaves correctly
   under this sandbox — it wasn't necessarily designed assuming one. (§6)
4. **No Undo affordance in the chat UI**, despite the data needed for it already flowing
   through. (§5)
5. **No Windows credential storage or write/agent safety surface at all** — not a
   regression, since the corresponding features don't exist yet on that platform, but
   worth building the caps/undo/confinement story correctly the first time when they do.
