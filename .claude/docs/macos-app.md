# macOS app reference (`macos/Markdown/`)

A SwiftUI document browser/editor built around one large `@Observable` model
(`Workspace`) plus a set of thin, single-purpose facades over the Rust core. This is the
**full-featured** platform — vault writes, search, AI chat, and credential storage all
work here today; see `windows-app.md` for the much smaller Windows surface.

## 1. File responsibilities

| File | Owns |
|---|---|
| `MarkdownApp.swift` | App entry point (`@main`), window scene, File-menu commands |
| `ContentView.swift` | Top-level layout (`NavigationSplitView`), sheet presentation, preference plumbing |
| `SidebarView.swift` | Folder tree, search results list, account menu row, toolbar buttons |
| `Workspace.swift` | The opened folder, selected file, buffer text, autosave, search orchestration, external-change absorption |
| `FileNode.swift` | Recursive lazy-loaded folder-tree model; filters to markdown-like extensions |
| `FolderSearch.swift` | Off-main-actor name/content search over the open folder |
| `VaultStore.swift` | Swift facade over Rust `markdown_vault` — the **only** path that writes to disk |
| `VaultWatcher.swift` | FSEvents wrapper; notifies `Workspace` of external changes to the open folder |
| `MarkdownCore.swift` | Swift facade over Rust `markdown_core` — render markdown, look up embedded web assets |
| `MarkdownWebView.swift` | `WKWebView` host + bidirectional JS bridge (`WebPreviewCoordinator`) |
| `WebPreferences.swift` | Rendering-option enums/keys, `UserDefaults` storage, JSON payload sent to the web UI |
| `ChatView.swift` / `ChatViewModel.swift` | Assistant sheet UI and its transcript/state machine |
| `AgentClient.swift` | Swift facade over Rust `markdown_agent` — one blocking call pumped on a background thread |
| `Account.swift` / `LoginView.swift` | Local-only "signed in" identity (no backend) |
| `Keychain.swift` | Stores the Anthropic API key in the macOS login keychain |
| `SettingsView.swift` | Settings sheet: API key field, rendering-option controls |
| `Markdown-Bridging-Header.h` | Imports `markdown_core.h` so Swift sees the C ABI |

Data generally flows: `Workspace` (buffer/state) → `ContentView` (layout) →
`MarkdownWebView` (render) and `TextEditor` (raw edit), with `VaultStore` as the sole
write path and `VaultWatcher`/`FileNode.refresh()` as the read-back path for external
changes.

## 2. Document/workspace model

**Writes are implemented.** This supersedes the design plan's original "the app cannot
write anything today" framing — `Workspace` no longer uses `FileManager` for writes at
all; every save goes through `VaultStore.write(_:contents:)`, which calls into Rust
`markdown_vault` (`md_vault_call` → `write_note`), giving every save a git commit and undo
history.

- **Loading**: `open(folder:)` starts a security-scoped resource, builds a `FileNode` tree
  (`FileNode.loadChildren()` lazily reads one directory level at a time — expanding a row
  in `SidebarView` triggers deeper reads), and starts a `VaultWatcher`. Selecting a file
  reads it directly via `String(contentsOf:encoding:)` — a plain disk read, not through
  the vault.
- **Editing/saving**: typing sets `text`, which calls `scheduleAutosave()` — a debounced
  (800 ms) `Task` calling `flushPendingSave(to:)`. Switching files or closing the folder
  flushes synchronously first, so no edit is lost to navigation.
- **Vault opened lazily**: `Workspace.vault` is `nil` until the first write — deliberate,
  so merely browsing a folder never creates a `.git` directory inside it.
- **External changes**: `VaultWatcher` (FSEvents, macOS-only; a no-op stub compiles for
  other platforms) coalesces events (300 ms latency), filters out `.git/` paths (the
  vault's own commits), and calls `Workspace.absorbExternalChanges`. This refreshes the
  `FileNode` tree (merging rather than replacing child objects, preserving `isExpanded`
  state) and reloads the currently open file **only if there are no unsaved local
  edits**; otherwise it surfaces `errorMessage` warning of a conflict — there is **no
  merge/diff UI**, the conflict is text-only.
- **Search**: `Workspace.searchQuery` debounces 250 ms then calls
  `FolderSearch.run(root:query:)`, which walks the folder off the main actor, matching
  filenames and grepping content (capped at 4 MB/file, 3 snippets/file, 200 hits total —
  mirrored in Rust's `markdown_vault::search`).

## 3. Rust FFI boundary

**`MarkdownCore.swift`** (a stateless enum) wraps `markdown_core`'s C ABI declared in
`include/markdown_core.h` (imported via the bridging header):

- `md_version()` → `MarkdownCore.version`
- `md_asset_count()` → `MarkdownCore.assetCount`
- `md_render(markdown) -> CString` (freed via `md_string_free`) →
  `MarkdownCore.render(_:)`, used by the WebView bridge's `"render"` message — the app
  itself doesn't pre-render for display; that happens inside the Vue app via the same
  bridge call.
- `md_asset_lookup(path, &MdAsset)` → `MarkdownCore.asset(forPath:)`, used exclusively by
  `WebPreviewCoordinator`'s `WKURLSchemeHandler` to serve the embedded Vue SPA.

**`VaultStore.swift`** is a separate facade over `markdown_vault`'s own C functions:
`md_vault_open(path) -> OpaquePointer`, `md_vault_call(handle, name, json) -> CString`,
`md_vault_close(handle)`. These are re-exported through the same `markdown_core.h` header
(`markdown_vault`'s FFI is declared in `vault_ffi.rs`, a submodule of `markdown_core`, not
a second crate-level header) — see `rust-core.md` §2.3 for the full function table.

`VaultStore` exposes one generic entry point, `call(_:_:) -> [String: Any]` (JSON in via
`JSONSerialization`, JSON out, checked for an `"ok"` boolean), plus typed conveniences
(`read`, `write`, `createFile`, `createFolder`, `move`, `delete`, `undo`) that are all
one-line wrappers calling specific tool names. **Adding a new vault tool requires zero
Swift changes** beyond an optional typed convenience — matching Rust's "one JSON call
reaches every tool" design. `VaultStore.relativePath(of:in:)` is a static helper
converting an absolute file URL to the vault-relative path the Rust API expects.

## 4. WebView bridge

`MarkdownWebView` is a `NSViewRepresentable` wrapping a `WKWebView`, coordinated entirely
by `WebPreviewCoordinator` (`@MainActor`). Two independent channels:

- **Asset serving** (`WKURLSchemeHandler`, scheme `markdown-app://local/...`): every
  request is answered synchronously from `MarkdownCore.asset(forPath:)` — nothing hits
  disk or network at runtime.
- **JS → Swift calls** (`WKScriptMessageHandlerWithReply`, handler name `"markdownBridge"`
  — `window.webkit.messageHandlers.markdownBridge`): three methods dispatched by a
  `method` string:
  - `"connect"` — handshake; marks `isLoaded = true`, replies with `coreVersion`,
    `assetCount`, current `text`, and the `preferences` payload, so the UI never flashes
    into the wrong state.
  - `"render"` — `{markdown}` in, `MarkdownCore.render(markdown)` out.
  - `"outlineState"` — `{available}` in, forwards to `onOutlineAvailabilityChange` (drives
    `SettingsView`'s outline toggle being disabled for sectionless documents).
- **Swift → JS pushes**: `setDocumentText`/`pushDocument` calls
  `window.__markdownHost?.setDocument(text)`; `setPreferences`/`pushPreferences` calls
  `window.__markdownHost?.setPreferences(preferences)`. Both are guarded by `isLoaded` and
  equality checks (`WebPreferences: Equatable`) to avoid redundant JS calls, and are
  re-sent from `WKNavigationDelegate.didFinish` in case the page reloaded.

Only the app's own `markdown-app://` and `about:` schemes may navigate in-place; anything
else (a link inside a rendered note) is cancelled and opened externally via
`NSWorkspace`.

`WebPreferences.swift` defines the rendering-option model (`outlineVisible`,
`contentWidth: ContentWidth`, `fontSize: Double`) with a `payload: [String: Any]` matching
what the web UI's `normalizePreferences` expects, plus `PreferenceKey` string constants
used by `Account.swift`/`SettingsView.swift`/`ContentView.swift` for
`UserDefaults`/`@AppStorage`.

## 5. AI chat feature

`ChatView` is a modal sheet (420×560) opened from the sidebar's "Assistant" toolbar
button, backed by `@State private var viewModel = ChatViewModel()`.

- **`ChatViewModel`** holds the transcript (`[ChatMessage]`: `.user`, `.assistant`,
  `.tool(name:ok:detail:commit:)`, `.notice`), the composer draft, and `isResponding`.
  `send(vaultRoot:)` lazily creates an `AgentClient` for the current vault root
  (recreated if the vault root changes), failing with a user-facing message if no API key
  is set in the Keychain or `AgentClient.init?` fails to open the Rust handle.
- **`AgentClient`** structurally mirrors `VaultStore` (`OpaquePointer` handle, closes it in
  `deinit`). Calls `md_agent_open(vaultPath, apiKey) -> OpaquePointer?`,
  `md_agent_send_start(handle, text) -> Bool`, and — critically —
  **`md_agent_poll_event(handle) -> CString?`, which blocks**. Since there's no callback
  ABI from Rust into Swift, `send(_:onEvent:)` detaches a plain `Thread` (not a `Task` —
  the call can block indefinitely) that loops `while let raw = md_agent_poll_event(handle)`,
  decoding each JSON event and invoking `onEvent` on that background thread;
  `ChatViewModel.send` re-marshals each event to `@MainActor`.
- **Event shape** (`AgentEvent`): `.text(String)` (streamed deltas, appended into the
  in-place assistant bubble), `.thinking(String)` (decoded but explicitly dropped — "not
  surfaced in this first pass"), `.toolStarted(name:)` / `.toolFinished(name:ok:detail:commit:)`
  (rendered as a status-icon row, matched by name from the end of the transcript to handle
  a tool running more than once per turn), `.refused(category:explanation:)` (a model
  safety refusal, shown as `.notice`), `.failed(String)`, `.done(stopReason:)`.

This confirms the design plan's Phase 2 (`markdown_agent`, Claude API loop with tool
dispatch, streaming via a blocking poll loop, no API key exposure to the web view) is
implemented on macOS. Every tool call the agent makes goes through the same
`markdown_vault` the editor writes through, so agent edits are versioned/undoable and show
up live in `FileNode`/`VaultWatcher`.

**Gap**: there's no UI for `.thinking` deltas, and no Undo button wired in `ChatView`
despite `VaultStore.undo(commit:)` existing and `.tool(...commit:)` carrying a commit id —
the transcript stores the commit hash but nothing currently exposes an undo action for it.

## 6. Auth/credentials

- **`Account`**: purely local identity — a name/email pair round-tripped through
  `UserDefaults`. No network call; swapping in a real backend means replacing `logIn`, not
  the views. This is cosmetic (sidebar avatar/initials) and **unrelated** to vault/API
  auth — a reader could mistakenly assume `Account.isLoggedIn` gates chat/vault access,
  but only `Keychain.apiKey()` gates the assistant.
- **`Keychain`**: stores the Anthropic API key under service string
  `"com.ogay.webviewtest.Markdown.anthropic-api-key"` using `kSecClassGenericPassword`,
  with `kSecAttrAccessibleAfterFirstUnlock` (available after first unlock post-boot, not
  iCloud-synced). Deliberately not `UserDefaults` and never pushed into the web view — the
  reasoning ties directly to the sanitization requirement: since `render.rs` used to pass
  raw HTML through, anything reachable from JS would be exfiltratable by a crafted note.
  That specific rendering hole is now fixed (see `security.md`), but the key is still kept
  Rust-side only, on the correct assumption that the web layer should never be trusted
  with secrets regardless.
- **`LoginView`**: simple sheet writing to `Account`.
- **`SettingsView`**: hosts the `SecureField` for the API key (written straight to
  `Keychain.setApiKey` on change, loaded once from `Keychain.apiKey()` — never through
  `@AppStorage`), plus rendering-option controls that *do* go through `@AppStorage`.

## 7. App entry point and lifecycle

`MarkdownApp` (`@main`) is a single `WindowGroup { ContentView() }` with `.commands`
adding `FolderCommands` (File-menu Open/Close Folder, routed via `FocusedValues`) and
`SidebarCommands()`.

`ContentView` owns the `Workspace`, `Account`, and all sheet-presentation state, lays out
a `NavigationSplitView` (sidebar + detail), and layers a `TextEditor` over the
`MarkdownWebView` preview (`ZStack`, toggled by an Edit toolbar button) rather than
swapping views — specifically to avoid tearing down/reloading the WebView (and the whole
embedded Vue app) every time edit mode toggles. `.preferredColorScheme(appearance.colorScheme)`
is applied here so native chrome and the web view's `prefers-color-scheme` stay in sync
from one setting.

## 8. Build configuration notes

- `SWIFT_OBJC_BRIDGING_HEADER = Markdown/Markdown-Bridging-Header.h`,
  `SWIFT_VERSION = 5.0`, `MACOSX_DEPLOYMENT_TARGET = 26.5`.
- `PRODUCT_BUNDLE_IDENTIFIER = com.ogay.webviewtest.Markdown` — the `webviewtest` segment
  reads like a leftover prototype name; worth renaming before shipping (it's also baked
  into the Keychain service string, so both would need to move together).
- A Run Script build phase invokes `rust/build-xcode.sh`, which builds a `cargo` slice per
  architecture in `ARCHS` and `lipo`-merges them into
  `target/apple/$PLATFORM_NAME-$CONFIGURATION/libmarkdown_core.a`; on macOS it also builds
  and code-signs the vendored `solomd-mcp` MCP server into the app bundle (see
  `build-and-development.md`).
- `ENABLE_USER_SCRIPT_SANDBOXING = NO` at the project level — required because that
  run-script phase shells out to `cargo`/`bun`.
- `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` is set in both Debug and Release.
- **No `.entitlements` file exists anywhere under `macos/`**, and no
  `CODE_SIGN_ENTITLEMENTS` build setting is present — the app is **not currently
  sandboxed**. This is inconsistent with `rust/README.md`'s claim that the sandboxed app
  needs `com.apple.security.network.client` for WebKit's helper processes to avoid
  crashing on launch: there is no sandbox entitlement and no network-client entitlement
  checked in. Either the README describes a target configuration not yet applied, or an
  entitlements file was intended but never committed. `Workspace.open(folder:)` calling
  `startAccessingSecurityScopedResource()` is effectively a no-op today since the process
  isn't sandboxed. **Worth resolving before Mac App Store distribution**, which requires
  the sandbox entitlement — and adding it later will require adding the network-client
  entitlement the README already anticipates.

## 9. Gaps, inconsistencies, and gotchas

1. **Sandboxing/entitlements mismatch** (§8) — no entitlements file despite README
   language assuming a sandboxed app.
2. **Undo is plumbed but not exposed in the chat UI** (§5) — commit ids flow through
   `AgentEvent.toolFinished` and are stored in `ChatMessage.Kind.tool`, but no undo
   affordance is rendered.
3. **`.thinking` events are decoded but discarded** — extended-thinking deltas from the
   agent loop are silently dropped from the UI.
4. **`Account` is entirely cosmetic/local** — no relationship to the Anthropic API key or
   any real authentication; don't assume it gates anything.
5. **Bundle identifier `com.ogay.webviewtest.Markdown`** looks like a prototype leftover.
6. **Conflict handling on external changes is passive** — `Workspace.absorbExternalChanges`
   only warns via `errorMessage`; no merge/diff/reload-and-discard UI exists yet.
7. **`Info.plist` is essentially empty** — no usage-description strings present yet, which
   will be needed if/when sandboxing entitlements are added.
