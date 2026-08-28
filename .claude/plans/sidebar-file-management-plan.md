# Plan: sidebar file management (create / rename / delete) + All-vs-Markdown filter — macOS only

**Status: implementation complete, pending manual verification (Phase E).** Checklist-style  
plan; check items off as they land, and keep it in  
sync if the design changes during implementation (same convention as  
`.claude/plans/file-type-viewers-plan.md` / `recent-vaults-plan.md` /  
`drag-drop-attachments-plan.md`).

Scope, per explicit user direction: **macOS only.** Windows (`win/MarkdownWin/`) is  
deliberately not touched here — it mirrors macOS file-for-file today, so this will widen  
the parity gap already tracked in `.claude/docs/windows-app.md`; a follow-up plan should  
port the same shape once the macOS side is proven.

What is being added, all inside the sidebar:

- **Create** a new note and a new folder, anywhere in the open vault.
- **Rename** any note or folder.
- **Delete** any note or folder (recursively, with confirmation).
- **Filter** the tree between **All files** and **Markdown only**.
- All of it reachable from **context menus** on the tree (file row, folder row, and the  
empty area / root header), plus the sidebar toolbar and the File menu.

## Context

Confirmed by reading the macOS app, `markdown_vault`, and the vault tool catalogue  
(read-only exploration; no changes made yet):

- **No Rust work is needed.** `rust/markdown_vault/src/tools.rs` already exposes  
`create_note`, `create_folder`, `move`, `delete`, and `undo`, each going through  
`confine::resolve_in` + `history::commit_all` (`store.rs:251/290/301/315`). Every one is  
already wrapped by a typed Swift convenience in  
`macos/Markdown/Markdown/VaultStore.swift`: `createFile` (:98), `createFolder` (:103),  
`move` (:108), `delete` (:113), `undo` (:118). Per **CLAUDE.md invariant #3**, this  
feature must ride that existing dispatch surface — do **not** add an FFI function, and do  
**not** write to vault files with `FileManager` from Swift (**invariant #1**).
- `Workspace` **has no mutation API yet.** `vaultStore()` (`Workspace.swift:368`) and  
`relativePath(of:)` (:376) are both `private`, and the only writer today is  
`flushPendingSave(to:)` (:323) plus `importAsset` (:349). New public methods are needed on  
`Workspace` so the sidebar never touches `VaultStore` directly.
- **The sidebar tree does not use the vault to list.** `FileNode.contents(of:)`  
(`FileNode.swift:112`) reads the directory with `FileManager` and filters *nothing* — it  
shows every file *and* hidden entries (`.git`, `.gitignore`), as its own doc comment at  
`FileNode.swift:15-18` states. The Rust `Vault::list` (`store.rs:197`) by contrast hides  
dot-entries and non-Markdown files. So the All/Markdown filter is purely a client-side  
concern in `FileNode`/`SidebarView`, with no Rust involvement.
- **Search results are already Markdown-only** — `FolderSearch.swift:79` ends in  
`urls.filter(MarkdownFile.matches)`. The new filter therefore applies to the *tree* only;  
the `searchResults` branch (`SidebarView.swift:122`) needs no change.
- **Context menus already exist, with one item each**: the whole `List` has  
`.contextMenu { Button("Refresh") { root.reload() } }` (`SidebarView.swift:47`), and each  
*directory* row has the same on its `DisclosureGroup` (:271). **File rows have no context**  
**menu at all** (`FileTreeRow.body`, :240-254).
- **Folders are not selectable.** `List(selection: selectedFileBinding)` (:37) is bound to  
`Workspace.selectedFile: URL?`, and only file rows carry `.tag(node.url)`; the  
`DisclosureGroup` label is untagged. There is consequently no "currently selected folder"  
concept to hang a toolbar "New Note in…" off — see decision 6.
- **Tree refresh after an external change already works**: the FSEvents `VaultWatcher`  
calls `absorbExternalChanges` (`Workspace.swift:265`), which calls `root?.refresh()` —  
a *merging* refresh (`FileNode.swift:94`) that keeps existing node objects and expansion  
state. Its coalescing latency is 0.3 s (`VaultWatcher.swift:22`), which is too slow to  
feel like a direct manipulation, so mutations should also refresh synchronously.
- **Autosave is a real hazard here.** `scheduleAutosave()` (`Workspace.swift:298`) leaves a  
debounced 800 ms write pending against `selectedFile`. Renaming or deleting the selected  
file without flushing first would either write to the stale path or re-create a file the  
user just deleted. `Workspace.save()` (:294) is the existing public flush and already  
drains the WYSIWYG editor's own pending edit first (`flushPendingSaveAsync`, :314).
- **Single-file mode has no vault.** `isSingleFile` (`Workspace.swift:98`) is true when a  
file was opened on its own; there is no folder, no `VaultStore`, and (per `open(file:)`'s  
doc comment) no access granted to the parent directory. Every command added here must be  
disabled in that state and in the no-folder empty state.
- **The vault opens lazily on first write** (`vault` property doc comment,  
`Workspace.swift:80`) so browsing leaves no `.git` behind. Creating/renaming/deleting is a  
write, so it will open the vault and create `.git` — consistent with existing behavior for  
the first edit, and no special handling is needed.

## Key design decisions

1. **All mutations go through new** `Workspace` **methods, which call the existing**  
\*\*\*\* `VaultStore` **conveniences.** No new FFI, no new Rust tool, no direct `FileManager`  
writes (CLAUDE.md invariants #1 and #3). New API on `Workspace`:
  ```swift
   @discardableResult func createNote(named name: String, in directory: URL) async -> Bool
   @discardableResult func createFolder(named name: String, in directory: URL) async -> Bool
   @discardableResult func rename(_ url: URL, to newName: String) async -> Bool
   @discardableResult func delete(_ url: URL) async -> Bool
  ```

   `async` because each must `await save()` first (decision 3). Each returns `false` and  
   sets `errorMessage` on failure rather than throwing, matching how every other failure in  
   `Workspace` is surfaced (the banner under the tree, `SidebarView.swift:52-60`).
2. **Paths are always converted to vault-relative with the existing**  
\*\*\*\* `VaultStore.relativePath(of:in:)` (`VaultStore.swift:151`) — reuse the private  
`relativePath(of:)` helper (`Workspace.swift:376`). A `nil` result means "outside the  
open folder" and must be refused with a clear message, never silently ignored.
3. **Every mutation flushes pending edits first**: `await save()` at the top of each of the  
four methods above, before computing paths. This closes the autosave-vs-rename/delete  
race described in Context.
4. **Selection follows the change.**
  - Rename of the currently selected file → `selectFile(newURL)` after the move succeeds  
   (also correct when the *ancestor folder* of the selected file is renamed: recompute by  
   replacing the renamed prefix of the selected path).
  - Delete of the currently selected file, or of a folder containing it → `selectFile(nil)`  
  and reset `text` to `Workspace.untitledText`, clearing `hasUnsavedChanges` so the  
  dying file's buffer cannot be written back.
  - Create note → select the new file so the user lands in it, ready to type.
5. **Refresh immediately, don't wait for FSEvents.** After a successful mutation call  
`root?.refresh()` (merging, preserves expansion). For a create inside a folder that has  
never been expanded (`children == nil`, so `refresh()` no-ops there by design,  
`FileNode.swift:95`), explicitly `loadChildren()` + set `isExpanded = true` on the target  
node so the new item is visible. The later FSEvents callback is then a harmless no-op.
6. **The context menu is the primary surface; the toolbar/File menu are the fallback.**  
Because folders are not selectable (see Context), "where does a new file go?" is  
answered as:
  - From a **folder row**'s context menu → inside that folder.
  - From a **file row**'s context menu → alongside it (its parent directory).
  - From the **root header / empty list area**, the **sidebar toolbar**, or the **File**  
  **menu** → the parent of `selectedFile` if there is one, else the vault root.

   A `targetDirectory(for: FileNode?) -> URL` helper in `SidebarView` centralizes this.
7. **Superseded 2026-08-28, per explicit user direction: create and rename are inline,**  
**Finder-style, not an alert.** The original decision here specced one reusable  
`.alert`-based name prompt and explicitly rejected inline in-row editing (reasoning kept  
below for context). That rejection turned out wrong in practice for what the user  
actually wanted: **create** now happens immediately with an auto-generated name  
(`Untitled.md`/`Untitled 2.md`/…, `New Folder`/`New Folder 2`/…, computed by  
`Workspace.availableName(base:extension:in:)` against whatever siblings are already  
loaded) and drops the new row straight into edit mode; **rename** (via the context menu)  
puts the existing row into the same edit mode. Implementation, in `SidebarView.swift`:
  ```swift
   @State private var editingNodeID: URL?   // which row, if any, shows a TextField
  ```

   `FileTreeRow`/`InlineNameField` swap `Label { Text(node.name) }` for a `TextField`  
   when `editingNodeID == node.url`, using `@FocusState` to focus it.  
   `Return` or losing focus commits (`Workspace.rename`, skipped if the name is unchanged  
   or empty); `Escape` (`.onKeyPress(.escape)`) reverts without calling the vault at all.  
   An `isResolved` flag guards commit/cancel from firing twice, since removing the focused  
   field from the hierarchy on Escape also fires the focus-loss commit path.  
   `Workspace.createNote(named:in:)`/`createFolder(named:in:)` (explicit name, `Bool`  
   result) were replaced by `createNote(in:)`/`createFolder(in:)` (auto-named, `URL?`  
   result so the caller knows what to point `editingNodeID` at); `rename(_:to:)` is  
   unchanged and still the only path that calls `Workspace.nameValidationError`.  
   *Original reasoning, no longer operative:* a `TextField` inside a `List` row that is  
   simultaneously a selection `.tag` target was expected to fight the list's own selection  
   and keyboard handling. It does, in exactly the way originally feared — a single  
   `.onAppear { isFocused = true }` routinely lost the race against the `List`'s own  
   selection-driven focus, since creating an item also selects it  
   (`Workspace.createNote(in:)` calls `selectFile(newURL)`, decision 4), and that  
   selection change and the field's own focus request land at the same moment. Fixed  
   2026-08-28 by re-asserting `isFocused = true` on a short retry loop (`.task`, 15×40 ms)  
   instead of trusting one attempt, gated by an `isSettled` flag so the loop's own  
   transient `isFocused` flips don't themselves trip the focus-loss-commits-the-name  
   `onChange` before the row has actually settled. Widened from an initial 8×40 ms after  
   the user reported "Rename" from the context menu specifically not taking keystrokes:  
   that path sets `editingNodeID` synchronously from the menu item's own action, right as  
   the just-dismissed `NSMenu` is still reclaiming focus — closer to that reclaim, in  
   time, than create's (which lands after an `await` round-trip through the vault call) —  
   so it needed more retries to reliably win. Unverified live; if it's still flaky the  
   next lever is a longer window or more retries, not a different mechanism.  
   **Separately, the same report ("also breaks the state of the tree") turned up a real,**  
   **deterministic bug, not a timing race**: `FileNode.refresh()` (used unchanged since  
   before this feature) matches old and new directory contents by URL to decide which  
   node objects to keep. A *renamed* folder's URL is, by definition, new — so it never  
   matches its own pre-rename entry, and comes back as a brand-new `FileNode` with  
   `children == nil` and `isExpanded == false`, silently collapsing and discarding  
   whatever was loaded underneath it even though nothing on disk changed but the name.  
   Fixed by capturing the pre-rename node (`Workspace.node(for:)`) before calling  
   `root?.refresh()` in `rename(_:to:)`, then calling a new `FileNode.adoptSubtree(from:)`  
   on the freshly-refreshed replacement node: `url` is `let`, so descendants can't be  
   relocated in place, but their subtree structure and `isExpanded` state can be, and are,  
   rebuilt against the new path without touching disk again.  
   **Also added 2026-08-28, per explicit user direction**: `Return` on the sidebar `List`  
   (not currently editing anything) starts renaming the selected file —  
   `.onKeyPress(.return) { editingNodeID = workspace.selectedFile; ... }` — mirroring  
   Finder. This *reverses* the "Return... not safely claimable" reasoning in decision 13  
   below, but safely: `onKeyPress` only fires when the `List` (or a row in it) actually  
   holds focus, which the text editor never does, so the worry decision 13 raised (a  
   global shortcut firing while the editor has focus) doesn't apply to a handler scoped  
   to the sidebar. `InlineNameField` itself claims `Return` first via its own  
   `.onKeyPress(.return)` (returning `.handled`) — otherwise committing a rename via  
   Return would bubble up to the `List`'s handler and immediately reopen the same row,  
   since by the time it bubbles, `editingNodeID` is already `nil` and the row is already  
   selected.
8. **Delete gets a confirmation dialog, and says what it will actually do.**  
`.confirmationDialog` with a `.destructive` button. Folder deletion is recursive on the  
Rust side (`fs::remove_dir_all`, `store.rs:322`), so the folder wording must say  
"and everything inside it". Mention recoverability: the deletion is a commit in the  
vault's history.
9. **Name validation happens in Swift before the call, and vault errors are surfaced**  
**verbatim after it.** Reject, with a specific message: empty/whitespace-only; containing  
`/` or `:` (`:` is the path separator Finder hides); `.` or `..`; and a leading `.`  
(which would create a file the tree now hides — see decision 11). Everything else —  
in particular "already exists" — is left to the vault, whose `VaultError` messages are  
already written to be read by a person (`VaultStore.swift:22-29`).  
*Extension policy for a new note:* if the typed name has no extension at all, append  
`.md`; if it has one, keep it exactly as typed (so `notes.txt` is honored).  
*Rename policy:* keep whatever the user typed, including a changed or removed extension  
— renaming `note.md` to `note` is their call, and `FileKind.of` will simply route it to  
the plain-text editor afterwards.  
**Narrowed 2026-08-28 for** `.md` **specifically, per explicit user direction**: the inline  
field hides the `.md` extension while editing (`FileTreeRow.hiddenExtension`/  
`baseNameForEditing`) and `InlineNameField.resolve(commit:)` restores it automatically  
whenever the committed text has no extension of its own — so typing "My Note" and  
hitting Return produces `My Note.md`, without ever seeing or touching the extension.  
This is a one-way door for `.md` notes edited inline: since the field never shows the  
extension, there is no way to type "no extension at all" through it any more, so the  
"renaming `note.md` to `note` is their call" case above is no longer reachable *inline*  
for `.md` files (typing an explicit different extension, e.g. `note.txt`, still works  
exactly as before). Other extensions (`.txt`, images, …) are untouched by this — the  
field still shows them, and this whole policy doesn't apply to folders (no extension).
10. `.git` **is never a mutation target.** With a Delete command in the tree, deleting  
`.git` would destroy the vault's entire undo history in one click — and  
`confine::resolve_in` would happily allow it, since `.git` *is* inside the vault. Two  
layers:
  - The tree stops listing dot-entries at all (decision 11), so it is not reachable.
  - `Workspace` refuses any mutation whose vault-relative path's first component is  
  `.git`, with a plain message. Belt and braces, because the tree filter is a display  
  concern and could be relaxed later.
11. **The filter is** `SidebarFilter { all, markdownOnly }`**, and "all" means "all**  
**non-hidden".** Declared next to `MarkdownFile`/`FileKind` in `FileNode.swift`, persisted  
with `@AppStorage` under a new `PreferenceKey.sidebarFilter` in `WebPreferences.swift`  
(:11-16), defaulting to `.all`.
  - Folders are **always** shown, under both settings. Hiding folders that contain no  
  Markdown would require eagerly walking the whole tree — defeating `FileNode`'s  
  load-on-expand design (`FileNode.swift:78`) — and would make a folder the user just  
  created vanish instantly.
  - **This changes existing behavior**: dot-entries (`.git`, `.gitignore`, …) are shown  
  today and will no longer be. That is deliberate (decision 10) and brings the tree in  
  line with what `Vault::list` already does (`store.rs:210-213`). The doc comment at  
  `FileNode.swift:15-18` that documents the old behavior must be updated in the same  
  change, and so must `.claude/docs/macos-app.md`.
  - Filtering is applied **at render time**, in `FileTreeRow`, not in  
  `FileNode.contents(of:)` — so flipping the filter is instant and does not re-read the  
  disk or discard node identity/expansion state.
12. **The filter is passed explicitly down the row recursion**, as a parameter on  
`FileTreeRow`, rather than each row reading `@AppStorage` itself. The recursion already  
rebuilds each row through `AnyView(FileTreeRow(node:))` (`SidebarView.swift:41`, :259),  
so threading one more value is trivial, and it avoids attaching a `UserDefaults`  
observer to every visible row.
13. **Keyboard shortcuts, kept out of the editor's way.** `⌘N` = New Note, `⇧⌘N` = New  
Folder (Finder's own pairing) in the File menu via `FolderCommands`  
(`MarkdownApp.swift:44-77`), which already replaces `.newItem`. Rename/Delete are  
context-menu-only in v1 — `⌫` / `Return` on a list selection are not safely claimable  
while the editor may hold focus.  
**Partially superseded 2026-08-28** (see decision 7): `Return` *is* now claimed, but on  
the sidebar `List` specifically via `.onKeyPress`, not as a scene-wide/File-menu  
shortcut — it only fires while the `List` (or a row in it) holds focus, which the text  
editor never does, so the "editor may hold focus" hazard this decision was guarding  
against doesn't actually apply to that scoped a handler. `⌫`-to-delete remains  
context-menu-only; only `Return`-to-rename changed.

## Checklist

### Phase A — Model + filter (`FileNode.swift`, `WebPreferences.swift`)

- [x] `FileNode.swift`: add `nonisolated enum SidebarFilter: String, CaseIterable, Identifiable`
  ```
  with cases `all` / `markdownOnly`, a `title` (`"All Files"` / `"Markdown Only"`), and
  `func shows(_ node: FileNode) -> Bool` returning `true` for any directory, and for
  files `self == .all || MarkdownFile.matches(node.url)`.
  ```
- [x] `FileNode.swift`: in `contents(of:)` (:112), skip entries whose
  ```
  `lastPathComponent.hasPrefix(".")` — matching `Vault::list` (`store.rs:210-213`) and
  making `.git` unreachable from the tree (decision 10).
  ```
- [x] `FileNode.swift`: update the `MarkdownFile` doc comment (:15-18), which currently
  ```
  states the tree "shows every file and folder, hidden ones (`.git`, `.gitignore`, …)
  included" — no longer true after the change above.
  ```
- [x] `FileNode.swift`: add `func visibleChildren(_ filter: SidebarFilter) -> [FileNode]`
  ```
  returning `(children ?? []).filter(filter.shows)`, so both the root section and the
  recursive rows share one rule.
  ```
- [x] `WebPreferences.swift`: add `static let sidebarFilter = "sidebarFilter"` to
  ```
  `PreferenceKey` (:11-16).
  ```

### Phase B — `Workspace` mutation API (`Workspace.swift`)

- [x] Add a `private func vaultRelative(_ url: URL) throws -> String` that wraps
  ```
  `relativePath(of:)` (:376) and throws a readable error when the URL is outside the
  open folder or there is no folder open (`isSingleFile`).
  ```
- [x] Add a `private func rejectIfGitInternals(_ relative: String) throws` guard
  ```
  (decision 10) refusing any path whose first component is `.git`.
  ```
- [x] **Superseded (decision 7)**: `createNote(in:) async -> URL?` and
  ```
  `createFolder(in:) async -> URL?` — auto-named (`availableName(base:extension:in:)`,
  not a caller-supplied name, since there is no prompt any more), same shape otherwise:
  `await save()`, build the relative path, `try vaultStore().createFile/createFolder`,
  `root?.refresh()`, reveal the parent (decision 5). `createNote` also `selectFile(newURL)`.
  Return `URL?` (not `Bool`) so the caller knows what to point `editingNodeID` at.
  **Note:** git does not track empty folders, so `createFolder`'s `nil` commit
  (`store.rs:298-300`) is *not* a failure and must not be reported as one.
  ```
- [x] Add `func rename(_ url: URL, to newName: String) async -> Bool`: `await save()`,
  ```
  validate the new name, compute `from`/`to` relative paths (same parent, new last
  component), `try vaultStore().move(from:to:)`, then `root?.refresh()` and re-point
  `selectedFile` per decision 4 (including the renamed-ancestor case).
  ```
- [x] Add `func delete(_ url: URL) async -> Bool`: `await save()`, guard,
  ```
  `try vaultStore().delete(path)`, then clear the selection if the deleted item is (or
  contains) `selectedFile` — resetting `text` and `hasUnsavedChanges` *before*
  `selectFile(nil)` so nothing can be flushed back to the deleted path — and
  `root?.refresh()`.
  ```
- [x] Every method: on `catch`, set `errorMessage` from `error.localizedDescription`
  ```
  (the vault's messages are already human-readable) and return `false`; on success,
  clear `errorMessage`.
  ```
- [x] Add `private(set) var lastChangeCommit: String?`, set from the commit id each
  ```
  successful mutation returns (`nil` for the empty-folder case above) — the hook Phase F
  needs, and cheap to add now.
  ```

### Phase C — Sidebar UI (`SidebarView.swift`)

- [x] Add `@AppStorage(PreferenceKey.sidebarFilter) private var sidebarFilter = SidebarFilter.all`
  ```
  to `SidebarView`.
  ```
- [x] **Superseded (decision 7)**: `@State private var editingNodeID: URL?` (which row, if
  ```
  any, is showing an inline `TextField`) and `@State private var pendingDelete: FileNode?`
  (decision 8) — no `namePrompt`/`promptedName`, since create/rename never leave the row.
  ```
- [x] **Superseded (decision 7)**: no `NamePrompt` enum — add
  ```
  `targetDirectory(for: FileNode?) -> URL?` (decision 6) and an `InlineNameField` view
  (name field + focus/commit/cancel handling, reused by both file and folder rows).
  ```
- [x] Root `List` (:37-49): drive the `ForEach` from `root.visibleChildren(sidebarFilter)`
  ```
  instead of `root.children ?? []`.
  ```
- [x] Root `List`'s existing `.contextMenu` (:47): extend from just "Refresh" to
  ```
  New Note… / New Folder… / `Divider()` / the filter `Picker` / `Divider()` / Refresh.
  ```
- [x] Root `Section` header (:44-46): keep showing `root.name`; give it the same context
  ```
  menu so right-clicking the vault name behaves like right-clicking empty space.
  ```
- [x] `FileTreeRow`: add a `let filter: SidebarFilter` stored property and thread it through
  ```
  both recursive construction sites (:41 and :259).
  ```
- [x] `FileTreeRow.directory` (:256-274): drive its `ForEach` from
  ```
  `node.visibleChildren(filter)`.
  ```
- [x] `FileTreeRow.directory`: extend the existing `.contextMenu` (:271) to New Note… /
  ```
  New Folder… (both inside this folder) / `Divider()` / Rename… / Delete / `Divider()` /
  Refresh. **Verify at run time** that the menu attaches to the disclosure *label* only
  and not to the expanded child rows — if it bleeds, move `.contextMenu` from the
  `DisclosureGroup` onto its `label:` content.
  ```
- [x] `FileTreeRow`: add a context menu to the **file** row (:245-253, which has none
  ```
  today): New Note… / New Folder… (alongside, i.e. in the parent) / `Divider()` /
  Rename… / Delete / `Divider()` / Reveal in Finder
  (`NSWorkspace.shared.activateFileViewerSelecting` — free, and expected on macOS).
  ```
- [x] **Superseded (decision 7)**: no `.alert` — "New Note"/"New Folder" call
  ```
  `Workspace.createNote(in:)`/`createFolder(in:)` directly and set `editingNodeID` to the
  result; "Rename" just sets `editingNodeID` on the existing node. Both land on the same
  `InlineNameField`, which calls `Workspace.rename(_:to:)` on commit. Name validation
  (decision 9) still lives entirely in `Workspace`, now reachable only through `rename`.
  ```
- [x] Add a `.confirmationDialog` for `pendingDelete` with a `.destructive` "Delete" button,
  ```
  wording that names the item and, for folders, says everything inside goes too
  (decision 8).
  ```
- [x] Sidebar toolbar (`SidebarView.swift:69-101`): add a second `Menu` (or extend the
  ```
  existing "Open" one with a divider) carrying New Note… / New Folder… / `Divider()` /
  the All-vs-Markdown `Picker`, so the commands are discoverable without a right-click.
  Disable the create items when `workspace.root == nil`.
  ```

### Phase D — Menu bar (`MarkdownApp.swift`, `ContentView.swift`)

- [x] `FolderCommands` (`MarkdownApp.swift:44-77`): add "New Note…" (`⌘N`) and "New Folder…"
  ```
  (`⇧⌘N`) above the existing Open items, both disabled when `workspace?.root == nil`.
  ```
- [x] Route them through a new `@FocusedValue` binding (mirroring `folderPicker`/
  ```
  `filePicker` in `ContentView.swift:212-217`) so the File menu drives the frontmost
  window's sidebar prompt rather than reaching into `Workspace` with no target folder.
  ```
- [x] `ContentView.swift`: declare the new `@Entry` focused values and publish them, next to
  ```
  `.focusedSceneValue(\.folderPicker, …)` (:210-212).
  ```

### Phase E — Verification

- [x] `cd rust && cargo test` — expected to be a no-op pass (no Rust changed), but run it,
  ```
  per CLAUDE.md's working conventions, to prove nothing was disturbed.
  ```
- [x] Build the macOS app in Xcode (`macos/Markdown/Markdown.xcodeproj`).
- [ ] Manual pass, folder open: create a note at root and inside a nested folder; create a
  ```
  folder; rename a file; rename a folder that contains the open file; delete a file;
  delete a non-empty folder; cancel each dialog and confirm nothing changed.
  ```
- [ ] Manual pass, autosave interlock: type into a note, then immediately (&lt; 800 ms) rename
  ```
  it — the edit must land in the *renamed* file, not re-create the old one.
  ```
- [ ] Manual pass, filter: toggle All ↔ Markdown Only and confirm non-Markdown files
  ```
  disappear/reappear, folders stay, expansion state survives, and `.git` never appears
  under either setting.
  ```
- [ ] Manual pass, disabled states: with a single file open (`isSingleFile`) and with
  ```
  nothing open, every create/rename/delete affordance is disabled or absent.
  ```
- [ ] Manual pass, external agreement: make a change here, then confirm the FSEvents
  ```
  refresh 0.3 s later does not double-apply, collapse the tree, or clear the selection.
  ```
- [ ] Confirm each change appears in the vault history (`git -C <vault> log --oneline`)
  ```
  with the messages `store.rs` writes (`Create …`, `Move … to …`, `Delete …`) — proof
  that invariant #2 held and the change is undoable.
  ```
- [x] Update `.claude/docs/macos-app.md` (sidebar section) and the feature-parity matrix in
  ```
  `.claude/docs/architecture.md` to record the new macOS-only capability.
  ```

### Phase F — Optional follow-on (not required for this feature)

- [ ] Surface `Workspace.lastChangeCommit` as an "Undo Last Change" File-menu item calling
  ```
  `VaultStore.undo(commit:)`, mirroring `ChatViewModel.undo(commit:vaultRoot:)`
  (`ChatViewModel.swift:94`). It must stay disabled when the commit is `nil` (the
  empty-folder create case) and should be one-shot per commit, as the chat undo is.
  ```
- [ ] Drag-and-drop move inside the tree, on top of the same `Workspace.rename` / `move`
  ```
  path — a natural next step once `move` is wired, but out of scope here.
  ```
- [ ] Port all of the above to Windows (`win/MarkdownWin/`), which already has the matching
  ```
  `VaultStore.cs` facade. Track alongside the existing Windows gap list.
  ```

## Explicitly out of scope

- **Windows.** Stated above; tracked as Phase F.
- **Any Rust change.** The tool catalogue already covers every operation needed  
(`tools.rs`); adding to it would violate CLAUDE.md invariant #3 for no benefit.
- **Duplicate / copy-paste / multi-select** file operations — one item at a time.
- **Trash semantics.** `delete` removes the file and records the removal as a commit; it  
does not move anything to the macOS Trash. The vault's history *is* the recovery story.
- **Making folders selectable** in the `List`. It would change what `selectedFile` means and  
ripple into the editor; decision 6 avoids needing it.
- **Filtering search results.** `FolderSearch` is already Markdown-only  
(`FolderSearch.swift:79`).
- **New-note templates / front-matter.** New notes are created empty.

