# AI assistant feature: comprehensive plan

## Purpose of this document

The original plan (`ai-assistant-mcp-and-chat.md` in this folder) was written before any
code existed. Two full implementation sessions have since landed Phase 0, Phase 1, and a
version of Phase 2 that deliberately diverges from what was originally proposed. This
document replaces it as the source of truth: what is actually built and verified, exactly
where it diverges from the original plan and why, the concrete gaps that implementation
surfaced, and the remaining work — prioritized, not just listed.

**Read this before touching the feature again.** The old plan describes a `markdown_mcp`
crate written from scratch and a Vue-based chat panel — neither exists. What exists instead
is documented below.

## Todo list

One flat checklist, pulled from "Remaining work, prioritized" below — that section has the
full rationale for each item; this is the quick-scan version. Nothing here is checked off yet.

**P0 — before this is usable day to day**
- [x] Wire the Undo button in the chat UI — **macOS done 2026-08-25** (`ChatViewModel.undo`,
      `ChatMessageRow`'s Undo button in `ChatView.swift`). Windows still open: its mirror in
      `ChatView.xaml.cs` still receives a commit id and discards it.
- [ ] Verify the success path with a real API key (every check so far used an invalid key;
      a real conversation with tool calls has never been run)
- [ ] Surface the `.git` side effect the first time a vault gains history

**P1 — makes the MCP half actually reachable**
- [ ] MCP registration UI: Settings row with the config snippet / `claude mcp add` command
      for the bundled `solomd-mcp` binary, plus an `--allow-write` toggle
- [ ] Show thinking summaries in the chat transcript (data already arrives, just not shown)

**P2 — consolidation and cross-platform parity**
- [ ] Converge vendored `solomd-mcp`'s tools onto `markdown_vault::tools::call`, delete its
      duplicate `safety.rs` / `workspace.rs`
- [x] Windows parity: `VaultStore.cs`, a `ReadDirectoryChangesW` watcher, autosave, a
      Credential Manager key store, and a chat UI — done 2026-08-24, native WinUI (see
      "Windows parity" under Shipped, below). Not yet run against a real vault or key.
- [ ] Destructive-op confirmation for `move`/`delete` tool calls, distinct from ordinary edits

**Deferred — not scheduled, revisit only if a concrete need shows up**
- [ ] Diff-preview-before-apply, as an alternative to auto-apply-with-undo
- [ ] Embedding-based semantic search, as an alternative to lexical search

**Decisions needed before some of the above can start**
- [ ] Native SwiftUI chat vs. switching to the originally-planned Vue-shared panel
- [ ] Converge `solomd-mcp` now vs. let it keep drifting from `markdown_vault`
- [ ] Whether P1 (reachability) should actually come before P0 (polish) if this is meant to
      be shown to other people rather than used solo

---

## Shipped and verified

### Phase 0 — `markdown_vault` crate (foundation)

`rust/markdown_vault/src/`: `confine.rs`, `history.rs`, `store.rs`, `outline.rs`, `search.rs`,
`tools.rs`. **79 tests**, all passing.

- **`confine.rs`** is the security boundary every path passes through. Paths are always
  vault-relative; `..`, absolute paths, NUL bytes, and symlinks pointing outside the vault
  are all rejected before touching disk. 16 tests, including a `vault-evil` sibling-directory
  case proving containment is component-wise, not a string prefix.
- **`history.rs`** is git, not a hand-rolled journal — one commit per save, undo is `revert`
  (a new commit, so undo is itself undoable), `is_dirty()` gates agent turns on a clean tree.
  `Vault::open` records a baseline commit on an adopted folder, fixing a real bug a test
  caught: without it, undoing the *first* change deleted the file instead of restoring it.
- **`outline.rs`** slug rules were verified against the actual TypeScript implementation
  (`vue-project/src/composables/useDocumentOutline.ts`) run in Node, not reasoned about —
  this caught a wrong assumption (`Über` → `u-ber`, not `uber`).
- **`search.rs`** ports the caps already tuned in the macOS `FolderSearch.swift`: skip huge
  files, cap snippets per file, cap total hits. Snippets are heading-anchored using the same
  outline logic.
- **`tools.rs`** is the single dispatch point (`call(vault, name, input) -> Result<Value,
  String>`) both the MCP server and the agent loop use, so the tool contract cannot drift
  between them. Ten tools; `edit_note` refuses ambiguous or absent matches rather than
  guessing.

**Also landed in Phase 0, cross-cutting:**
- **XSS fix in `render.rs`** (`markdown_core`, not `markdown_vault`): `pulldown-cmark` passes
  raw HTML through by default, and the preview injects it with `v-html`. A crafted note could
  execute script in the web view. Fixed with `ammonia` sanitization, allow-listing exactly
  what the renderer itself emits (heading `id`s, task-list checkboxes). 7 tests, including one
  asserting nothing legitimate was lost.
- **Autosave** (`Workspace.swift`): debounced (800ms), flushed on file switch/folder
  close/quit. Required because the agent and a human editing the same file would otherwise
  silently clobber each other.
- **`VaultWatcher.swift`**: FSEvents, `.git` paths filtered, merges into `FileNode` rather
  than rebuilding (a rebuild would collapse every expanded folder on any external write). A
  dirty buffer is never overwritten by an external change — flagged instead.
- **FFI**: `md_vault_open/close/call/tools` in `markdown_core/src/vault_ffi.rs`, plus
  `VaultStore.swift` — a thin ~130-line facade, JSON in and out.

### Phase 1 — MCP server: vendored `solomd-mcp`, not a fresh `markdown_mcp`

**Deviation from the original plan.** The plan called for writing `markdown_mcp` in Rust
using `rmcp`, linking `markdown_vault` directly. Instead, `solomd-mcp` — a MIT-licensed,
already-shipping MCP server from a comparable product (SoloMD) — was vendored into
`rust/vendor/solomd-mcp/`. It happens to also be Rust + `rmcp`, so the language/framework
decision was validated independently, but the tool implementation itself is **not**
`markdown_vault`'s — it has its own `safety.rs` (path confinement) and `workspace.rs` (vault
walking, search). See `rust/vendor/solomd-mcp/PROVENANCE.md` for the exact diff from
upstream: `git2` bumped 0.19→0.21 to resolve a workspace conflict, four SoloMD-coupled tools
removed (`share_url`, `sync_status`, `export_note`, `read_agent_trace` — they call SoloMD's
own web service and app-bundle scripts, which don't exist here), their orphaned helpers and
tests removed, `--help` text corrected.

**Now ships inside the app.** `build-xcode.sh` builds the `solomd-mcp` binary for each
architecture Xcode requests, lipo's the slices together, and — critically — **signs it with
the same identity as the app** and places it in `Contents/MacOS/`, not `Contents/Resources/`.
Both of those were real bugs found and fixed this session:
- A Mach-O in `Contents/Resources/` inside a signed bundle is refused execution outright
  (SIGKILL, no diagnostic) — moved to `Contents/MacOS/`.
- Cargo's own signature is `adhoc,linker-signed`, which taskgated rejects once nested inside
  a properly signed bundle (`CODESIGNING / Taskgated Invalid Signature` in the crash report).
  Fixed by having the build script sign it with `$EXPANDED_CODE_SIGN_IDENTITY` and
  `--options runtime`.

**Verified end-to-end**, not just "it compiles": driven over real JSON-RPC stdio from outside
the app while the app had the same vault open, confirming (a) `write_note`/`create_note`
land on disk, (b) the app's `VaultWatcher` picks up the change and the tree updates live,
(c) an unsaved buffer is protected — the conflict is surfaced, not silently overwritten, and
(d) the sidecar binary runs and the bundle's signature still verifies
(`codesign --verify --deep --strict`, exit 0).

**Read-only by default.** `--allow-write` is required for any write tool; `--allow-destructive`
gates `move`/`delete` further (adopted from SoloMD's defaults, tightened for the folder tools
this app added).

### Phase 2 — Agent loop + chat UI: native SwiftUI, not Vue

**Deviation from the original plan.** The plan specified the chat panel as `ChatPanel.vue`,
shared with a future Windows app over the existing `markdownBridge`. What shipped is a native
SwiftUI sheet (`ChatView.swift`). Rationale recorded at the time: the part that's genuinely
shared — the agent loop, the safety caps, the FFI — is unaffected by this choice and is
already done; only the chat bubbles are platform-specific, and building them natively meant
the whole feature could be delivered and verified end-to-end in one sitting rather than also
touching the bridge and the Vue app. **This is the single largest open decision in this
document** — see "Open decisions" below.

**`rust/markdown_agent/src/`**: `request.rs`, `sse.rs`, `session.rs`. **29 tests**, all
against a hand-rolled stub HTTP server (no tokens, no network, no flakiness) replaying
canned SSE transcripts. Notably:
- `parallel_tool_results_go_back_in_one_message` — asserts the follow-up request carries
  exactly one user message with both `tool_result` blocks, not two messages (splitting them
  is documented to teach the model to stop parallelizing tool calls).
- `the_write_cap_refuses_before_the_file_changes` — asserts the *absence* of the file the
  capped call would have written, not just an error message.
- `a_dirty_vault_refuses_before_any_request` — asserts zero requests reached the stub server.
- `thinking_blocks_are_echoed_back_unchanged` — thinking blocks (including the `signature`
  field) must round-trip verbatim for replay on the same model; a test pins this.

Request shape: `claude-opus-5`, `thinking: {type: "adaptive"}` (never `budget_tokens`, a 400
on this model), `output_config.effort`, streaming, `fallbacks: "default"` with its beta
header, one `cache_control` breakpoint on the system block (tools + prompt cached, turns
not), no assistant prefill.

**FFI** (`markdown_core/src/agent_ffi.rs`, 5 tests): `md_agent_open/close/send_start/
poll_event`. Deliberately no callback from Rust into Swift — `send_start` spawns a
background thread running the loop; `poll_event` blocks for the next event and returns NULL
when the turn ends. One turn at a time; a second `send_start` while one is in flight is
refused, verified by test.

**Swift**: `AgentClient.swift` (facade, polls on a dedicated `Thread` — not a `Task`, since
the call blocks for as long as the model takes), `Keychain.swift` (API key storage; never
`UserDefaults`, never sent to the web view — a crafted note can run script in the preview, so
anything JS-reachable is exfiltratable), `ChatViewModel.swift` (transcript state), `ChatView.swift`
(the sheet UI), an "Assistant" sparkles icon in `SidebarView.swift`'s toolbar, and an
"Assistant" section in `SettingsView.swift` for the key.

**Verified against the live Anthropic API** with a deliberately invalid key — not a stub —
confirming the entire chain works: TLS via `rustls`, request shape accepted well enough to
get a structured `401` back, the non-streaming-error branch in `Agent::round()`, JSON
encoding, the FFI channel, the poll loop, Swift decoding, the background-thread-to-MainActor
hop, and the UI's error state. Also verified: `Keychain` round-trips exactly and clears
correctly; `ChatViewModel.send()` with no key stored adds zero messages and sets the correct
guidance string, without even attempting to open an `AgentClient`.

---

## Known gaps (found during implementation, not yet closed)

These are concrete, not speculative — each was either directly observed or confirmed absent
by grep during this session.

1. **~~The Undo affordance is plumbed but not surfaced, on either platform.~~ macOS closed
   2026-08-25.** `ChatMessage.tool` carries a `commit: String?` specifically so the chat
   panel could offer "undo this change" next to the tool row (`ChatViewModel.swift:15`).
   `ChatMessageRow` in `ChatView.swift` now has an Undo button reading it, calling a new
   `ChatViewModel.undo(commit:vaultRoot:)` that opens the vault independently of the agent
   `client` and calls `Vault::undo`; each commit can only be undone once per transcript
   (`undoneCommits`), and success/failure both post a `.notice` row. Verified with a real
   `xcodebuild` build, not just inline diagnostics.

   **Windows still open**, with the identical gap: `ChatMessage.cs`'s `ToolCommit` is
   populated by `ChatViewModel.cs` but nothing in `ChatView.xaml`/`.xaml.cs` reads it. The
   `Vault::undo`/`History::revert` machinery is reachable from `VaultStore.cs` the same way;
   only the WinUI button and the `ChatViewModel.Undo` method are missing.
2. **No MCP registration UI.** Nothing in the app writes or displays a `.mcp.json` /
   Claude Desktop config snippet pointing at the bundled `solomd-mcp` binary. A user who
   wants Claude Code or Claude Desktop to use it today has to find the binary inside the
   `.app` bundle and configure it by hand.
3. **The chat's success path is unverified.** Every end-to-end check this session used an
   invalid key (by necessity — no real key was available). The `401` path is confirmed
   working in full; a real conversation with actual tool calls has not been run once.
4. **Thinking is received but never shown.** `ChatViewModel.apply()` has `case .thinking:
   break // not shown; kept internal for now` — the assistant's reasoning summary is decoded
   and then dropped on the floor.
5. **The vault silently grows a `.git` directory on first write, with no notice.** Flagged as
   an accepted consequence when `history.rs` was designed, but no UI communicates it — a user
   whose "notes folder" is inside another sync tool (Dropbox, iCloud, an existing git repo)
   finds out only by looking at the filesystem.
6. **~~Windows (`win/MarkdownWin/`) is completely untouched.~~ Closed 2026-08-24.** Windows
   gained `VaultStore.cs`, `VaultWatcher.cs`, debounced autosave in `Workspace.cs`,
   `FolderSearch.cs`, a `CredentialStore.cs` backed by the Windows Credential Locker, and a
   full native chat UI (`AgentClient.cs`, `ChatViewModel.cs`, `ChatView.xaml(.cs)`) plus a
   local account/settings UI (`Account.cs`, `LoginDialog.xaml.cs`, `SettingsDialog.xaml.cs`)
   — each file mirrors its Swift counterpart closely enough to say so in its own header
   comment. This resolves "Open decisions" #1 below in practice (native per-platform UI, not
   a shared Vue panel), though no one has ratified that as a decision. What's left: it has
   never been run against a real vault from a real user, or against a real Anthropic API
   key — the same unverified-success-path gap as macOS (see gap #3), now doubled. It also,
   correctly, has no MCP server — that stays macOS-only by design.
7. **`solomd-mcp`'s tool implementation duplicates `markdown_vault`'s.** Both have their own
   path confinement and search. `PROVENANCE.md` names the convergence step (rewrite
   `solomd-mcp`'s tool bodies to call `markdown_vault::tools::call`, delete its `safety.rs`
   and `workspace.rs`) but it has not been done — the two are independent implementations
   today, verified independently, not by a shared test suite.
8. **No destructive-op confirmation anywhere.** Auto-apply-with-undo was the explicit choice,
   but nothing distinguishes "the agent added a paragraph" from "the agent deleted a folder"
   in the UI — both just appear as a tool row with a checkmark.

---

## Remaining work, prioritized

### P0 — before this is usable day to day

- [x] **Wire the Undo button — macOS.** Done 2026-08-25: `ChatMessageRow` shows an Undo
  button on any tool row with a commit, calling `ChatViewModel.undo(commit:vaultRoot:)`,
  which opens a `VaultStore` (separate from the agent `client`) and calls `Vault::undo`.
- [ ] **Wire the Undo button — Windows.** `ChatMessage.cs` already exposes `ToolCommit` the
  same way; the WinUI chat template needs the equivalent button and a
  `ChatViewModel.Undo(commit)` calling into `VaultStore.cs`. Same shape as the macOS change
  just landed — port it. This is otherwise the cheapest, highest-value item left on this
  list — the backend is fully done.
- [ ] **Verify the success path with a real API key.** Everything is built to make this work,
  but "the model successfully edits a note via tool calls, streams text, and the UI updates
  correctly" has literally never been observed. Do this before calling Phase 2 complete.
- [ ] **Surface the `.git` side effect.** At minimum, a one-time note the first time a vault
  gains history ("This folder now tracks changes with git, so the assistant's edits can be
  undone"). Better: detect a vault already under an *existing* unrelated git repo or a
  cloud-sync folder and say something more specific.

### P1 — makes the MCP half actually reachable

- [ ] **MCP registration UI**: a Settings row (or a new section) that shows the exact config
  snippet for Claude Desktop and the `claude mcp add` command for Claude Code, pointing at
  `Contents/MacOS/solomd-mcp` inside the running app's own bundle, with a copy button and an
  `--allow-write` toggle. The app is sandboxed, so it cannot write Claude Desktop's config
  file directly — this has to be "show me the command," not "do it for me."
- [ ] **Show thinking summaries** in the chat transcript (collapsed by default is fine) —
  the data already arrives, it's one `ChatMessage` case away from being visible.

### P2 — consolidation and cross-platform parity

- [ ] **Converge `solomd-mcp` onto `markdown_vault`.** Keep its `main.rs` (CLI, transport
  selection, the `--allow-write`/`--allow-destructive` gates, workspace federation), replace
  its tool bodies with calls into `markdown_vault::tools::call`, delete `safety.rs` and
  `workspace.rs`. Closes gap #7 and means a fix to path confinement only has to happen once.
- [x] **Windows parity** — done 2026-08-24: `VaultStore.cs`, `VaultWatcher.cs`, autosave,
  `CredentialStore.cs`, and a native WinUI chat panel (`ChatView.xaml`), not the
  originally-planned shared Vue panel. Remaining before this can be called verified: run it
  against a real vault and a real API key (it has never been exercised end-to-end, same as
  macOS's gap #3).
- [ ] **Destructive-op confirmation**: a distinct visual treatment (or an actual confirm step)
  for `move`/`delete` tool calls in the chat transcript, separate from ordinary edits.

### Deferred, not scheduled

- Diff-preview-before-apply (the plan's rejected alternative to auto-apply-with-undo) —
  revisit only if the undo-based safety net proves insufficient in practice.
- Embedding-based semantic search — lexical search was the deliberate choice; revisit only
  if lexical recall is demonstrated to be inadequate on a real vault.

---

## Open decisions for the user

**1. Native SwiftUI chat vs. Vue-shared chat panel.** Overtaken by events, not formally
decided: Windows shipped a second native chat panel (`ChatView.xaml`, WinUI) on 2026-08-24
rather than waiting for this decision or building on Vue, which was the Windows-reuse
argument for switching in the first place. In practice there are now two hand-mirrored
native chat UIs instead of one shared Vue one — the "every turn spent on native UI is a turn
that'd be redone in Vue" cost below has already been paid twice. Worth an explicit call now:
ratify native-per-platform (and accept a third mirror if another platform ever appears), or
treat this as the last moment to consolidate onto Vue before a third UI accretes the same
way. Arguments for staying native, as originally written: it works, it's tested, and the
underlying agent/FFI layer — the expensive part — is identical either way, so the switch cost
is bounded to UI code only, whenever it happens.

**2. Should `solomd-mcp` stay vendored, or converge onto `markdown_vault` now rather than
later?** Every day it stays vendored is another day its tool behavior can silently drift from
`markdown_vault`'s (different error messages, different edge-case handling in `edit_note` vs.
its equivalent, etc.), even though both are independently well-tested today.

**3. Priority order between P0/P1/P2** as written reflects a "make it useful, then make it
reachable, then make it clean" bias. If the goal is showing this to other people (vs. daily
personal use), P1's MCP registration UI likely belongs before P0's undo button.

---

## Verification commands, for whoever picks this up

```bash
# Rust: all four crates + vendored server, 165 tests total
cd rust && cargo test

# Vue (unaffected by anything in this document, but part of the build)
cd vue-project && npm run build

# macOS app, including the bundled + signed solomd-mcp sidecar
cd macos/Markdown && xcodebuild -project Markdown.xcodeproj -scheme Markdown \
  -destination 'platform=macOS' build

# Confirm the sidecar actually runs from inside the signed bundle (this exact check
# caught both packaging bugs described above)
APP=<DerivedData path>/Markdown.app
"$APP/Contents/MacOS/solomd-mcp" --version
codesign --verify --deep --strict "$APP"
```

Windows has a project to build (`win/MarkdownWin/MarkdownWin.slnx`) but no scripted build or
test step has been verified yet for its new vault/chat code — see gap #6. Whoever picks this
up should establish that (an MSBuild command here, plus a first real run against a live
vault and API key) rather than assuming parity with the macOS checks above.
