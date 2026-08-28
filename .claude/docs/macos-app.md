# macOS app reference (`macos/Markdown/`)

A SwiftUI document browser/editor built around one large `@Observable` model
(`Workspace`) plus a set of thin, single-purpose facades over the Rust core. This is the
**full-featured** platform — vault writes, search, AI chat, and credential storage all
work here today; see `windows-app.md` for the much smaller Windows surface.

## 1. File responsibilities


| File                                     | Owns                                                                                                      |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `MarkdownApp.swift`                      | App entry point (`@main`), window scene, File-menu commands                                               |
| `ContentView.swift`                      | Top-level layout (`NavigationSplitView`), per-file-kind detail routing, sheet presentation, preference plumbing |
| `SidebarView.swift`                      | Folder tree, search results list, account menu row, toolbar buttons. Row icons come from `NSWorkspace.shared.icon(forFile:)` — Finder's own icons, not a hand-picked SF Symbol |
| `Workspace.swift`                        | The opened folder, selected file, buffer text, `selectedFileKind`, autosave, search orchestration, external-change absorption |
| `FileNode.swift`                         | Recursive lazy-loaded folder-tree model; always hides dot-prefixed entries (`.git`, …), and shows every remaining file or only Markdown-flavored ones per `SidebarFilter` (see §4). Also owns `FileKind` (markdown/image/pdf/plainText classification, by extension) and `MarkdownFile`/`ImageFile` extension sets |
| `FolderSearch.swift`                     | Off-main-actor name/content search over the open folder                                                   |
| `VaultStore.swift`                       | Swift facade over Rust `markdown_vault` — the **only** path that writes to disk                           |
| `VaultWatcher.swift`                     | FSEvents wrapper; notifies `Workspace` of external changes to the open folder                             |
| `MarkdownCore.swift`                     | Swift facade over Rust `markdown_core` — render markdown, look up embedded web assets                     |
| `MarkdownWebView.swift`                  | `WKWebView` host + bidirectional JS bridge (`WebPreviewCoordinator`); also suppresses the WebView's native right-click context menu (`WKUIDelegate`) |
| `ImageViewer.swift`                      | Read-only pan/zoom image viewer (`NSScrollView`+`NSImageView`) for a selected `.image`-kind file, with a `CenteringClipView` fix so zooming out centers rather than pinning to the bottom-left corner |
| `PDFViewerView.swift`                    | Read-only PDF viewer (`PDFKit.PDFView`) for a selected `.pdf`-kind file, with an optional page-thumbnail panel (`PDFThumbnailView`, toggled from the toolbar, animates open/closed via a width constraint) |
| `WebPreferences.swift`                   | Rendering-option enums/keys, `UserDefaults` storage, JSON payload sent to the web UI                      |
| `ChatView.swift` / `ChatViewModel.swift` | Assistant sheet UI and its transcript/state machine                                                       |
| `AgentClient.swift`                      | Swift facade over Rust `markdown_agent` — one blocking call pumped on a background thread                 |
| `Account.swift` / `LoginView.swift`      | Local-only "signed in" identity (no backend)                                                              |
| `Keychain.swift`                         | Stores the Anthropic API key in the macOS login keychain                                                  |
| `SettingsView.swift`                     | Settings sheet: API key field, appearance/width/font-size controls (the outline visibility toggle moved out — see §6) |
| `Markdown-Bridging-Header.h`             | Imports `markdown_core.h` so Swift sees the C ABI                                                         |


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
branches on `FileKind.of(url)` (see §3): `.markdown`/`.plainText` read directly via
`String(contentsOf:encoding:.utf8)` (a plain disk read, not through the vault; throws —
surfaced as `errorMessage` — for anything that isn't valid UTF-8, which is also today's
fallback for a file kind the classifier didn't recognize); `.image`/`.pdf` skip the text
read entirely and leave `text`/`hasUnsavedChanges`/autosave untouched, since
`ImageViewer`/`PDFViewerView` load their own bytes straight from the file's `URL`.
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

## 3. Per-file-kind content viewers (image, PDF, plain text)

Before this feature, the sidebar tree only ever showed Markdown-flavored files and
`ContentView.detail` unconditionally rendered the Markdown WYSIWYG surface for whatever
was selected. `FileNode.swift`'s `MarkdownFile` extension filter being (temporarily, at
the time) removed from the tree surfaced the gap: opening an image or PDF just hit
`loadSelectedFile()`'s UTF-8 decode failure path. This section is the fix — built
**entirely natively**, no Rust or Vue changes, since a selected file is already reachable
directly off its `URL` the same way `loadSelectedFile()` already read it. (The extension
filter itself came back, generalized, as `SidebarFilter` — see §4.)

- **`FileKind`** (`FileNode.swift`): `.markdown` / `.image` / `.pdf` / `.plainText`,
computed from extension by `FileKind.of(url:)` — checks `MarkdownFile.matches` first,
then `ImageFile.extensions` (`png, jpg, jpeg, gif, webp, bmp` — deliberately raster-only;
`svg`/`ico` fall through to `.plainText`, which is a better fit for XML/text-ish `svg`
than a broken `NSImage` render), then `"pdf"`, else `.plainText`. Any extension the
classifier doesn't recognize also lands in `.plainText`, reusing the pre-existing
UTF-8-decode-or-error fallback rather than needing a dedicated "unknown binary" state.
- **`Workspace.selectedFileKind`**: `selectedFile.map(FileKind.of) ?? .markdown` — drives
both `loadSelectedFile()`'s branch (§2) and `ContentView.detail`'s routing.
- **`ContentView.detail`** switches on `selectedFileKind`: `.markdown` keeps the existing
`ZStack { preview; if isEditing { editor } }`; `.plainText` shows the same `editor`
(`TextEditor(text: $workspace.text)`, 16pt horizontal padding) unconditionally as the
sole view — no Markdown rendering/formatting, by design; `.image`/`.pdf` show
`ImageViewer(url:)`/`PDFViewerView(url:)`. The toolbar's `EditorFormattingToolbar` and
"Source" toggle only attach when `selectedFileKind == .markdown` — they're meaningless
for the other three.
- **`ImageViewer`**: `NSViewRepresentable` wrapping `NSScrollView`+`NSImageView`,
`allowsMagnification = true` (native trackpad pinch/scroll pan-zoom, no hand-rolled
`MagnificationGesture` code). A `Coordinator` tracks the last-loaded `url` to avoid
redundant `NSImage(contentsOf:)` disk reads on unrelated SwiftUI re-renders. Ships a
`CenteringClipView: NSClipView` overriding `constrainBoundsRect(_:)` — `NSClipView`
pins a document view smaller than its own bounds to the origin (bottom-left) by
default, which is why zooming out looked "stuck" to that corner before this fix;
installed via `scrollView.contentView = CenteringClipView()` before `documentView` is
set.
- **`PDFViewerView`**: `NSViewRepresentable` wrapping a plain `NSView` container laying
out `PDFKit.PDFView` (`autoScales = true`, leading/flexible) and `PDFThumbnailView`
(trailing, width-animated 0↔160pt via an `NSLayoutConstraint`) bound to the *same*
`PDFView` instance via a `Coordinator`, so clicking a thumbnail navigates the main view.
`isShowingThumbnails` is a plain `Bool` passed in from `ContentView`'s
`isShowingPDFThumbnails` `@State` (default `false`), toggled by a toolbar button shown
only for `.pdf` kind. Note: `PDFThumbnailView.layoutMode` is **iOS-only** — the actual
macOS header (`PDFThumbnailView.h`) has no such property; a single vertical column comes
from `maximumNumberOfColumns = 1` instead (caught by an actual `xcodebuild` run, not
just live SourceKit diagnostics, several of which are stale/spurious in this project
regardless — cross-check any SourceKit-reported error against a real build before
trusting it).
- **Sidebar row icons**: `SidebarView.swift`'s `FileTreeRow` renders
`NSWorkspace.shared.icon(forFile: node.url.path)` (Finder's own icon lookup — correct
colors and per-type glyph, including the standard folder icon, for free) rather than a
hand-picked SF Symbol. `FileKind` itself carries no icon/tint properties (an earlier,
now-removed iteration hand-picked SF Symbols + tint colors; superseded once
`NSWorkspace` icons were adopted).
- **Not done**: Windows (`FileNode.cs`/`Workspace.cs`/`MainWindow.xaml(.cs)`) —
explicitly skipped for this pass at the user's direction. See
`.claude/plans/file-type-viewers-plan.md` for the full checklist, including the
Windows design (mirrors macOS's `FileKind`; a second `WebView2` instance for PDF
viewing since WinUI has no native PDF control, `ScrollViewer`+`ZoomMode="Enabled"` for
images) that hasn't been implemented yet. Office formats (`.docx`/`.xlsx`) were
discussed but not built: they fall into `.plainText` today and just show the
UTF-8-decode error, since they aren't valid UTF-8. `QLPreviewView` (Quartz —
**not** `QLPreviewController`, which is iOS-only) and a Rust-side `calamine`→HTML-table
path for spreadsheets were the two live options considered; neither is implemented.

## 4. Sidebar file management (create/rename/delete) + All-vs-Markdown filter

Added 2026-08-28. All-macOS; see `.claude/plans/sidebar-file-management-plan.md` for the
full design rationale (Windows is deliberately out of scope, tracked as a follow-up).
No Rust change — every operation already existed in `markdown_vault::tools` (`create_note`,
`create_folder`, `move`, `delete`) and was already wrapped by `VaultStore.swift`; this
feature is entirely `Workspace`/`SidebarView`/`MarkdownApp` wiring on top of that.

- **`Workspace` mutation API** (new, all `async`, all flush pending edits via `save()`
first to avoid racing the 800 ms autosave debounce): `createNote(in:)`/`createFolder(in:)`
(auto-named — see below — returning the new `URL?`), `rename(_:to:)` (validates via
`Workspace.nameValidationError`, the only remaining caller of it), `delete(_:)`. Each
rejects anything resolving outside the open folder or under `.git` (belt-and-braces — the
tree already hides dot-entries), calls the matching `VaultStore` convenience, and on
success calls `root?.refresh()` (plus an explicit `loadChildren()`/`isExpanded = true` on
the target directory if it had never been expanded, since a merging `refresh()` only
recurses where children are already loaded). Failures set `errorMessage` rather than
throwing, matching every other `Workspace` failure path. `lastChangeCommit` is populated
on success (`nil` is normal for `createFolder` — git does not track empty folders) and
reserved for a future "Undo Last Change" File-menu item mirroring
`ChatViewModel.undo(commit:vaultRoot:)`.
- **Create is inline, Finder-style, not a name prompt.** `createNote(in:)`/
`createFolder(in:)` auto-name the new item (`Untitled.md`/`Untitled 2.md`/…, `New
Folder`/`New Folder 2`/…, via `Workspace.availableName(base:extension:in:)` against
whatever siblings are currently loaded) and `SidebarView` immediately points
`editingNodeID: URL?` at the result, which swaps that row's `Label` for an
`InlineNameField` (`@FocusState`-focused `TextField`). "Rename" from the context menu, or
pressing **Return** on the sidebar `List` while a file is selected and nothing is already
being edited (`.onKeyPress(.return)` on the `List`, scoped to it — the text editor never
holds that focus, so this doesn't collide with normal typing), does the same on an
existing row. `Return`/losing focus commits (calling `Workspace.rename(_:to:)`, skipped if
the name is empty or unchanged); `Escape` (`.onKeyPress(.escape)`) reverts without any
vault call. `InlineNameField` claims `Return` itself first (`.onKeyPress(.return)`
returning `.handled`) so a commit can't bubble up to the `List`'s own Return handler and
immediately reopen the row it just closed. An `isResolved` guard stops commit/cancel from
firing twice, since dismissing the field on Escape also triggers the focus-loss commit
path. Focus itself needs a retry loop, not a single `.onAppear { isFocused = true }`: a
freshly created item is also freshly *selected* (`createNote(in:)` calls
`selectFile(newURL)`), and the `List`'s own selection-driven focus reliably won that race
against a single attempt — `InlineNameField.task` now re-asserts `isFocused = true` for
15×40 ms (widened from 8× after rename-via-context-menu, which sets `editingNodeID`
synchronously right as the just-dismissed `NSMenu` is still reclaiming focus, needed more
retries than create's async-round-trip-delayed assignment to reliably win), gated by an
`isSettled` flag so the loop's own transient focus flips don't themselves trip the
focus-loss-commits-the-name path before the row has actually settled. (An earlier
iteration used a `.alert` with a `NamePrompt` enum instead; superseded per user direction
— see decision 7 in the plan.)
- **A folder rename used to silently collapse its own subtree — fixed 2026-08-28.**
`FileNode.refresh()` (unchanged, predates this feature) matches old and new directory
listings by URL to decide which node objects survive a refresh. A renamed folder's URL is
new by definition, so it never matched its own pre-rename entry and came back as a
brand-new `FileNode` — `children == nil`, `isExpanded == false` — discarding whatever was
loaded underneath it even though nothing on disk changed but the name. `Workspace.rename`
now captures the pre-rename node (`node(for:)`) before calling `root?.refresh()`, then
calls a new `FileNode.adoptSubtree(from:)` on the freshly-refreshed replacement: since
`url` is `let`, descendants can't be relocated in place, so this reconstructs the
subtree's structure and `isExpanded` state under the new path instead of re-reading disk.
- **The `.md` extension is hidden while editing, `.txt`/images/etc. are not.**
`FileTreeRow.hiddenExtension` is non-`nil` only for a file whose extension is exactly
`md`; `baseNameForEditing` strips it for `InlineNameField`'s initial text, and
`InlineNameField.resolve(commit:)` restores it on commit whenever the typed text has no
extension of its own — typing "My Note" and hitting Return produces `My Note.md`. Typing
an explicit different extension (e.g. `note.txt`) still overrides it, exactly as before.
Trade-off, narrowed from decision 9: since the field never shows `.md`, there is no way
to type "no extension at all" through it any more for a `.md` note specifically — the
"renaming `note.md` to `note` is their call" case in decision 9 is no longer reachable
*inline* for that one extension (folders and every other extension are unaffected).
- **Selection follows the change**: renaming the selected file, or an ancestor folder of
it, re-points `selectedFile` to the new path (`Workspace.repointSelection`); deleting the
selected file, or a folder containing it, resets `text`/`hasUnsavedChanges` **before**
calling `selectFile(nil)` (`clearSelectionIfAffected`) — ordering matters here, since
`selectFile`'s own flush would otherwise try to write the buffer back to a path that no
longer exists.
- **`SidebarFilter`** (`FileNode.swift`): `.all` / `.markdownOnly`, `@AppStorage`-backed
(`PreferenceKey.sidebarFilter`), applied at render time via `FileNode.visibleChildren(_:)`
— not in `contents(of:)` — so toggling it is instant and never re-reads the disk or
discards node identity/expansion state. Folders are always shown under both settings.
Dot-prefixed entries (`.git`, `.gitignore`, …) are filtered out in `contents(of:)` itself,
unconditionally, independent of `SidebarFilter`.
- **UI surface**: context menus on the file row, folder row, and the root header/empty
area (`SidebarView`'s `FileTreeRow.fileContextMenu`/`folderContextMenu`/
`rootContextMenu(_:)`), a toolbar "New" menu, and File-menu items ("New Note" `⌘N`,
"New Folder" `⇧⌘N` in `FolderCommands`, `MarkdownApp.swift`). The File menu reaches the
sidebar's own state via two closure-typed `@FocusedValue`s
(`newNoteAction`/`newFolderAction`, declared in `ContentView.swift`) that `SidebarView`
publishes with `.focusedSceneValue` — mirroring the existing `folderPicker`/`filePicker`
pattern, since `editingNodeID` and the target-directory rule both live in `SidebarView`,
not `Workspace`. Where a create command targets a folder that isn't explicitly clicked on
(root header, toolbar, File menu) follows one rule, `SidebarView.targetDirectory(for:)`:
the parent of the selected file if one exists, else the vault root — `nil` (disabling the
affordance) whenever there is no open folder at all.
- **One `.confirmationDialog` for delete**, `.destructive` button, wording that names the
item and, for a folder, says everything inside goes too.

## 5. Rust FFI boundary

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

## 6. WebView bridge

`MarkdownWebView` is a `NSViewRepresentable` wrapping a `WKWebView`, coordinated entirely
by `WebPreviewCoordinator` (`@MainActor`). Two independent channels:

- **Asset serving** (`WKURLSchemeHandler`, scheme `markdown-app://local/...`): tries
`MarkdownCore.asset(forPath:)` (the embedded Vue SPA bundle) first; on a miss, falls back
to `readAsset(url.path)` → Rust's `read_asset` tool, serving a vault attachment's raw
bytes (e.g. an `<img src="assets/photo.png">` inside a rendered note) — this fallback,
not documented here before, is how images imported via drag/drop render inline (see
`rust-core.md` §3.6).
- **JS → Swift calls** (`WKScriptMessageHandlerWithReply`, handler name `"markdownBridge"`
— `window.webkit.messageHandlers.markdownBridge`): methods dispatched by a `method`
string — `"connect"` (handshake; marks `isLoaded = true`, replies with `coreVersion`,
`assetCount`, current `text`, and the `preferences` payload, so the UI never flashes into
the wrong state), `"render"` (`{markdown}` in, `MarkdownCore.render(markdown)` out),
`"outlineState"` (`{available}` in, forwards to `onOutlineAvailabilityChange` — drives
`ContentView`'s own toolbar "Contents" toggle being disabled for sectionless documents;
this used to disable a toggle in `SettingsView`, which no longer has one — see below),
`"importAsset"` (`{filename, contentBase64}` in, `{path, mime}` out — the drag-drop/paste
file-import path, `fileImport.ts` on the Vue side).
- **Swift → JS pushes**: `setDocumentText`/`pushDocument` calls
`window.__markdownHost?.setDocument(text)`; `setPreferences`/`pushPreferences` calls
`window.__markdownHost?.setPreferences(preferences)`. Both are guarded by `isLoaded` and
equality checks (`WebPreferences: Equatable`) to avoid redundant JS calls, and are
re-sent from `WKNavigationDelegate.didFinish` in case the page reloaded.
- **Context menu**: `WebPreviewCoordinator` also conforms to `WKUIDelegate`
(`webView.uiDelegate = self`) purely to implement
`webView(_:willOpenMenu:with:) { menu.items.removeAll() }`, suppressing WKWebView's
default right-click menu (Reload/Back/Inspect Element/…) — none of it applies to an
embedded editor UI, and "Reload" in particular would silently discard the in-memory
WYSIWYG document without saving.

Only the app's own `markdown-app://` and `about:` schemes may navigate in-place; anything
else (a link inside a rendered note) is cancelled and opened externally via
`NSWorkspace`.

`WebPreferences.swift` defines the rendering-option model (`outlineVisible`,
`contentWidth: ContentWidth`, `fontSize: Double`) with a `payload: [String: Any]` matching
what the web UI's `normalizePreferences` expects. Only `contentWidth`/`fontSize`/
`appearance` are backed by `PreferenceKey`/`UserDefaults`/`@AppStorage` now (used by
`Account.swift`/`SettingsView.swift`/`ContentView.swift`) — `outlineVisible` used to be a
fourth persisted key with a "Show contents tree" toggle in `SettingsView`; that's been
replaced by a transient `ContentView.isShowingOutline` `@State`, driven by a toolbar
open/close button (mirroring the PDF thumbnail panel's toggle, §3) rather than a
persisted setting, so `PreferenceKey.outlineVisible` was deleted rather than left unread.
`App.vue`'s outline pane also moved from the left side of the layout to the right (see
`frontend.md`).

## 7. AI chat feature

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

## 8. Auth/credentials

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

## 9. App entry point and lifecycle

`MarkdownApp` (`@main`) is a single `WindowGroup { ContentView() }` with `.commands`
adding `FolderCommands` (File-menu Open/Close Folder, routed via `FocusedValues`) and
`SidebarCommands()`.

`ContentView` owns the `Workspace`, `Account`, and all sheet-presentation state, lays out
a `NavigationSplitView` (sidebar + detail), and routes `detail` by `selectedFileKind`
(§3). Only within the `.markdown` branch does it layer a `TextEditor` over the
`MarkdownWebView` preview (`ZStack`, toggled by the "Source" toolbar button) rather than
swapping views — specifically to avoid tearing down/reloading the WebView (and the whole
embedded Vue app) every time edit mode toggles; the other three kinds each show exactly
one view, with no WebView involved at all for `.plainText`/`.image`/`.pdf`.
`.preferredColorScheme(appearance.colorScheme)` is applied here so native chrome and the
web view's `prefers-color-scheme` stay in sync from one setting.

## 10. Build configuration notes

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

## 11. Gaps, inconsistencies, and gotchas

1. **Sandboxing/entitlements mismatch** (§10) — no entitlements file despite README
 language assuming a sandboxed app.
2. **Undo is plumbed but not exposed in the chat UI** (§7) — commit ids flow through
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
8. **Per-file-kind viewers (§3) are macOS-only** — Windows has no `FileKind` equivalent,
 no image/PDF viewer, and no plain-text-only editor; selecting a non-Markdown file there
 still hits `Workspace.cs`'s `StrictUtf8`-guarded read and shows a "not a text file"
 error for anything binary. See `.claude/plans/file-type-viewers-plan.md`.
9. **No native Word/Excel preview** — `.docx`/`.xlsx` fall into `.plainText` and fail
 the UTF-8 decode (shown as the same generic read error as any other unsupported
 binary). `QLPreviewView` (Quartz) and a Rust `calamine`→HTML-table path for
 spreadsheets were discussed as options; neither is built.

