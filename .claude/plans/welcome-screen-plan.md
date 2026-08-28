# Plan: SwiftUI welcome screen (shown when no folder/file is open)

**Status: not started.** Checklist-style plan; check items off as they land (same  
convention as `.claude/plans/recent-vaults-plan.md`, `file-type-viewers-plan.md`).

## Context

The app never persists "which vault was open" across launches (confirmed this session,  
and unchanged by the just-shipped Recent Vaults feature — that only remembers a *list* to  
reopen from, not an auto-reopened current one). So `Workspace` always starts with  
`root == nil`, `selectedFile == nil` on launch — every launch currently lands on  
`ContentView.detail`'s `.markdown` case showing the untitled placeholder document  
(`Workspace.untitledText = "Hello, world!"`) in the WYSIWYG editor, with the full  
Markdown formatting toolbar active, which reads as "you already have a document open"  
when nothing meaningful is. The user wants a real welcome screen for that state instead,  
surfacing the recently-opened folders/files (`RecentVaultsStore`, added this session) so  
reopening one is one click instead of a picker round-trip.

## Key design decisions

1. **New** `Workspace.isEmpty: Bool { root == nil && selectedFile == nil }`, next to  
`isSingleFile` (`Workspace.swift:98`) — the single source of truth for "nothing is  
open," reused by both `ContentView.detail`'s branch and its toolbar gating so they  
can't disagree.
2. **New file** `macos/Markdown/Markdown/WelcomeView.swift`, a plain SwiftUI `View`  
(no `NSViewRepresentable` needed — this is ordinary SwiftUI content, unlike  
`ImageViewer`/`PDFViewerView`). Takes `workspace: Workspace` (read-only use: reads  
`workspace.recentVaults.entries`, calls `workspace.openRecent(_:)` and  
`workspace.recentVaults.remove(_:)`) plus `openFolder: () -> Void` /  
`openFile: () -> Void` closures — same shape `SidebarView` already takes, so  
`ContentView` wires it identically to how it wires `SidebarView` today  
(`ContentView.swift:57-65`).
3. **Layout**: centered `VStack` — a title/subtitle, then a prominent "Open Folder…" /  
"Open File…" button pair (calling the passed closures — the exact same  
`.fileImporter`s `ContentView` already owns, no new picker plumbing), then, only when  
`workspace.recentVaults.entries` isn't empty, a "Recent" section listing each entry:  
the real system icon (`NSWorkspace.shared.icon(forFile:)`, matching  
`SidebarView.fileIcon`'s existing pattern at `SidebarView.swift:266-271`),  
`entry.displayName`, an abbreviated `entry.path` as a secondary line, tappable to call  
`workspace.openRecent(entry)`, with a context-menu "Remove from Recent" calling  
`workspace.recentVaults.remove(entry)`. No new recent-vaults logic — this view is a  
pure consumer of what `RecentVaultsStore` (`RecentVaults.swift`) already exposes.
4. `ContentView.detail` (`ContentView.swift:182-207`) gets a new top branch: when  
`workspace.isEmpty`, render `WelcomeView(...)` instead of entering the  
`switch workspace.selectedFileKind` — which still defaults to `.markdown` when empty,  
so the branch order matters (check `isEmpty` first).
5. **Toolbar gating** (`ContentView.swift:72`, `if workspace.selectedFileKind ==  .markdown`): change to `if !workspace.isEmpty && workspace.selectedFileKind ==  .markdown`, so the formatting toolbar/Source/Contents toggles don't float over the  
welcome screen (today they show over the untitled placeholder document; that's the  
exact behavior being replaced).
6. `SidebarView`**'s existing** `emptyState`**/**`singleFileState` **(**`SidebarView.swift:180-202`**)**  
**stay exactly as they are** — they're a minor, narrow-column affordance and don't  
conflict with a richer main-pane welcome screen; both can show "no folder open"  
simultaneously without being redundant in a confusing way (same relationship as, e.g.,  
Xcode's sidebar empty state vs. its main-pane welcome window).

## Checklist

### Phase A — `Workspace.isEmpty` — DONE

- [x] `Workspace.swift`: add `var isEmpty: Bool { root == nil && selectedFile == nil }`
  ```
  next to `isSingleFile` (line 98).
  ```

### Phase B — `WelcomeView` — DONE

- [x] New file `macos/Markdown/Markdown/WelcomeView.swift`: title/subtitle, Open
  ```
  Folder…/Open File… buttons, conditional "Recent" list sourced from
  `workspace.recentVaults.entries`, tap-to-reopen via `workspace.openRecent(_:)`,
  remove via `workspace.recentVaults.remove(_:)` (context menu per row).
  ```

### Phase C — Wire into `ContentView` — DONE

- [x] `ContentView.detail` (lines 182-207): branch on `workspace.isEmpty` first, showing

  `WelcomeView(workspace: workspace, openFolder: { isChoosingFolder = true }, openFile: { isChoosingFile = true })`; kept the existing `switch workspace.selectedFileKind` for the non-empty case unchanged.  
  **Correction:** this branch was originally missed — only the toolbar-gating edit  
  below was applied, so the welcome screen never actually appeared despite being  
  checked off. Fixed and rebuilt green.
- [x] `ContentView.swift:72`: gated the Markdown-only toolbar block on
  ```
  `!workspace.isEmpty && workspace.selectedFileKind == .markdown`.
  ```

### Phase D — Verification — PARTIAL

- [x] \`xcodebuild -project Markdown.xcodeproj -scheme Markdown -configuration Debug
  ```
  -destination 'platform=macOS' build` green.
  ```
- [ ] Manual pass: launch the app fresh (it always starts empty — nothing persists the
  ```
  last-open vault) and confirm the welcome screen shows instead of the old untitled
  placeholder document, with no formatting toolbar floating over it. Confirm "Open
  Folder…"/"Open File…" still work exactly as before. With at least one recent entry
  present (from the Recent Vaults feature already shipped), confirm clicking it
  reopens that folder/file, and that opening/closing a folder correctly
  shows/hides the welcome screen (`Workspace.close()` already resets `root`/
  `selectedFile` to `nil`, so `isEmpty` flips back to `true` automatically). Not yet
  run — needs a manual pass in the running app.
  ```

## Explicitly out of scope

- Any change to `SidebarView`'s own empty/single-file states — untouched.
- Auto-reopening the last vault on launch (a different feature — persisting *which*  
vault was active, not just which ones are reachable) — not requested, not built.
- Any Windows work — this is a macOS-only SwiftUI view, mirroring how the whole  
Recent Vaults feature it depends on is macOS-only.

