# Plan: persist access to previously opened vault folders/files (Recent Vaults)

**Status: not started.** Checklist-style plan; check items off as they land, keep in sync  
if the design changes during implementation (same convention as  
`.claude/plans/drag-drop-attachments-plan.md` / `file-type-viewers-plan.md`).

Scope, per explicit user choice: **recent-vaults quick switch, not simultaneous**  
**multi-vault background access.** Exactly one vault/file is open and active at a time,  
same as today — this just lets the user reopen a previously-granted folder or file  
without going through `NSOpenPanel`/`.fileImporter` again, across app launches.

## Context

Confirmed via research (read-only, `Workspace.swift`, `ContentView.swift`,  
`MarkdownApp.swift`, `SidebarView.swift`, and a search for entitlements/bookmarks):

- `Workspace` already calls `url.startAccessingSecurityScopedResource()` in  
`open(folder:)` (line 107) and `open(file:)` (line 149), storing the result in a  
single `scopedResource: URL?` (line 72) that gets released on every subsequent open or  
close (`releaseScopedAccess()`, line 380). This access is **never persisted** — it's  
re-derived from a fresh `.fileImporter` pick every time.
- No `URL.bookmarkData`/`URL(resolvingBookmarkData:)` calls exist anywhere in the app.
- No `.entitlements` file exists at all (`find` confirmed) — the app runs unsandboxed  
today, matching the known gap already flagged in `security.md`/`CLAUDE.md`.
- No "recent folders" list exists anywhere (no `@AppStorage` key, no `UserDefaults`  
entry, no "Open Recent" menu item) — `FolderCommands` in `MarkdownApp.swift` only has  
"Open File…", "Open Folder…", "Close Folder/File".
- The app is strictly single-vault: one `Workspace`, one `root: FileNode?`, one  
`WindowGroup`.

The user wants folders/files the app has previously been granted access to to be  
reopenable later — including after a relaunch — without re-prompting, using Apple's  
persistent-access mechanism (security-scoped bookmarks), rather than the current  
"ask again every time" behavior.

## Key design decisions

1. **New small persistence type,** `RecentVaultsStore`, in a new file  
`macos/Markdown/Markdown/RecentVaults.swift`. `@Observable`, matching the existing  
`VaultStore`/`Account` style. Backed directly by `UserDefaults.standard` (same  
pattern `Account.swift` already uses for its own persisted fields), storing a  
JSON-encoded `[RecentVaultEntry]` under one key, most-recent-first, capped at 10  
entries.
2. `RecentVaultEntry: Codable, Identifiable`: `bookmark: Data`, `displayName: String`  
(last known last-path-component, for display before/if resolution fails),  
`path: String` (last known full path — used only to dedupe/reorder on repeat opens,  
never trusted for access), `isFolder: Bool`, `lastOpenedAt: Date`. `id` derived from  
`bookmark` (e.g. a stable hash) so list diffing works without a separate UUID.
3. **Bookmark creation tries security scope first, falls back to a plain bookmark.**  
`URL.bookmarkData(options: .withSecurityScope, ...)` is the "correct" Apple API for  
this and is forward-compatible with `security.md`'s known gap (the app may be  
sandboxed later) — but since the app isn't sandboxed today, this call's behavior in  
an unsandboxed process isn't something to assume without seeing it fail; wrap it in  
`do/catch` and fall back to `url.bookmarkData(options: [], ...)` (a plain bookmark,  
which works in any process and is all an unsandboxed app actually needs — it survives  
the item being renamed/moved on the same volume, which a raw stored path string  
would not). Both cases store into the same `RecentVaultEntry.bookmark` field; nothing  
downstream needs to know which kind it is.
4. **Resolution**: `RecentVaultsStore.resolve(_ entry: RecentVaultEntry) -> URL?` calls  
`URL(resolvingBookmarkData: entry.bookmark, options: .withSecurityScope, ...)`  
(falling back to `options: []` if that throws, mirroring creation), checks  
`isStale` and re-saves a fresh bookmark for that entry if so, and returns `nil`  
(after removing the entry from the store) if resolution fails outright — e.g. the  
folder was deleted or moved off-volume.
5. **Wiring into** `Workspace`: `Workspace` gets a `let recentVaults = RecentVaultsStore()`  
property. `open(folder:)` and `open(file:)` each call  
`recentVaults.record(url:, isFolder:)` right after the existing  
`url.startAccessingSecurityScopedResource()` block succeeds (folder: near line 109;  
file: near line 151) — recording happens on every successful open, whether it came  
from a fresh picker pick or from reopening a recent entry, so re-opening a recent  
item also refreshes its position/timestamp at the front of the list.
6. **New** `Workspace.openRecent(_ entry: RecentVaultEntry) async` **method**: resolves the  
bookmark via `recentVaults.resolve(entry)`; if `nil`, calls `reportOpenFailure` with  
a small local error type and returns; otherwise calls the existing  
`open(folder: url)` or `open(file: url)` depending on `entry.isFolder` — reusing all  
existing open logic (scoped-access start, tree load, watcher, vault, autosave-flush)  
rather than duplicating any of it.
7. **UI surfaces, both reusing** `workspace.recentVaults.entries` **directly (no new**  
\*\*\*\* `@State`**, no duplicated list)**:
  - `MarkdownApp.swift`'s `FolderCommands`: a new `Menu("Open Recent")` between "Open  
   Folder…" and "Close Folder", one `Button` per entry (`entry.displayName`) calling  
   `workspace?.openRecent(entry)`, plus a trailing `Divider()` + "Clear Menu" button  
   calling a new `recentVaults.clear()`. Disabled/hidden (empty menu) when  
   `workspace?.recentVaults.entries.isEmpty ?? true`.
  - `SidebarView.swift`'s existing toolbar "Open" `Menu` (lines 70–75): same list  
  inserted below a `Divider()` after "Open Folder…"/"Open File…", so it's reachable  
  without the menu bar too.
8. **Windows: out of scope, and not a gap to flag.** Security-scoped bookmarks are an  
Apple App Sandbox concept with no WinUI equivalent; `architecture.md` already notes  
the Windows app is unpackaged/`runFullTrust`, which gets ordinary persistent  
filesystem access with no permission-list mechanism needed at all. Nothing to build  
there.

## Checklist

### Phase A — `RecentVaultsStore` — DONE

- [x] New file `macos/Markdown/Markdown/RecentVaults.swift`: `RecentVaultEntry` (Codable,
  ```
  Identifiable) and `@Observable final class RecentVaultsStore` with `entries:
  [RecentVaultEntry]` (loaded from `UserDefaults.standard` on init), `record(url:
  URL, isFolder: Bool)`, `resolve(_ entry: RecentVaultEntry) -> URL?`, `clear()`,
  and a private `persist()` writing the JSON-encoded array back to `UserDefaults`.
  Cap at 10 entries (drop oldest). Dedupe/reorder existing entries by `path` on
  `record(...)`, not by resolving every stored bookmark.
  ```
- [x] Bookmark creation and resolution both attempt `.withSecurityScope` first, falling
  ```
  back to `[]` on failure — implemented as small private helpers on
  `RecentVaultsStore` so `Workspace` never deals with the fallback directly.
  ```

### Phase B — Wire into `Workspace` — DONE

- [x] `Workspace.swift`: add `let recentVaults = RecentVaultsStore()`.
- [x] `open(folder:)` (line 99): after the existing
  ```
  `if url.startAccessingSecurityScopedResource() { scopedResource = url }` block,
  add `recentVaults.record(url: url, isFolder: true)`.
  ```
- [x] `open(file:)` (line 135): same, `recentVaults.record(url: url, isFolder: false)`,
  ```
  after its own scoped-access block (line 149–151).
  ```
- [x] New method `openRecent(_ entry: RecentVaultEntry) async`: resolve via
  ```
  `recentVaults.resolve(entry)`; `nil` → `reportOpenFailure` with a new
  `RecentVaultUnavailableError: LocalizedError` (message naming
  `entry.displayName`); otherwise delegate to `open(folder:)`/`open(file:)` per
  `entry.isFolder`.
  ```

### Phase C — UI — DONE

- [x] `MarkdownApp.swift`'s `FolderCommands`: add `Menu("Open Recent") { ... }` sourced
  ```
  from `workspace?.recentVaults.entries`, plus "Clear Menu" below a `Divider()`,
  positioned between the existing "Open Folder…" button and the "Close
  Folder"/"Close File" button.
  ```
- [x] `SidebarView.swift`'s toolbar "Open" `Menu` (lines 70–75): same list, added below
  ```
  a `Divider()` after "Open File…", as a nested "Open Recent" submenu.
  ```

### Phase E — App Group (added post-implementation, at user request) — DONE

- [x] Discovered while wiring this that the app is **already sandboxed** — \`codesign -d
  ```
  --entitlements -` on the built app showed `com.apple.security.app-sandbox`,
  `.files.user-selected.read-write`, `.network.client` all `true`, synthesized from
  declarative build settings already in `project.pbxproj`
  (`ENABLE_APP_SANDBOX = YES`, etc.) with no `.entitlements` file — this contradicted
  `security.md`'s "not sandboxed" claim, now corrected there.
  ```
- [x] New `macos/Markdown/Markdown/Markdown.entitlements`, wired via
  ```
  `CODE_SIGN_ENTITLEMENTS` in both Debug/Release configs in `project.pbxproj`. Adds
  `com.apple.security.files.bookmarks.app-scope` (**required** for a persisted
  bookmark to resolve in a later launch under sandboxing — without it this whole
  feature would silently not survive a relaunch) and
  `com.apple.security.application-groups` = `group.com.ogay.webviewtest.Markdown`,
  alongside the pre-existing app-sandbox/user-selected-files/network entitlements.
  ```
- [x] `RecentVaultsStore.init` now defaults to \`UserDefaults(suiteName:
  ```
  "group.com.ogay.webviewtest.Markdown") ?? .standard` — falls back safely if the
  group container isn't available for some reason.
  ```
- [x] Rebuilt and confirmed via `codesign -d --entitlements -` that all five entitlements
  ```
  (`app-sandbox`, `application-groups`, `files.bookmarks.app-scope`,
  `files.user-selected.read-write`, `network.client`) are present on the signed app,
  and that automatic signing successfully picked up a provisioning profile covering
  the App Group (no manual Apple Developer portal step was needed).
  ```

### Phase D — Verification — PARTIAL

- [x] \`xcodebuild -project Markdown.xcodeproj -scheme Markdown -configuration Debug
  ```
  -destination 'platform=macOS' build` green.
  ```
- [ ] Manual pass: open folder A, open file B (no folder), quit the app, relaunch, use
  ```
  File ▸ Open Recent to reopen A, then B, confirming both load with no file-picker
  prompt. Then rename/move one of them on disk and confirm reopening it from the
  recent list either still resolves (rename on same volume) or cleanly reports an
  error and drops it from the list (moved off-volume/deleted), rather than
  crashing. Not yet run — needs a manual pass in the running app.
  ```

## Explicitly out of scope

- Keeping more than one vault's security-scoped access active/indexed at the same time  
(background indexing across all previously-granted folders) — user chose the  
simpler "quick switch" scope; still exactly one active vault.
- Any Windows work — no WinUI equivalent of this concept; the unpackaged/`runFullTrust`  
Windows app already has ordinary persistent filesystem access.
- Any Rust or Vue changes — this is purely a native macOS concern (which folder/file  
the app is granted access to), nothing about vault content or rendering.
- Turning on App Sandbox entitlements — that's the separate, larger gap already tracked  
in `security.md`; this plan's bookmark code is written to tolerate either sandbox  
state but doesn't itself add an entitlements file.

