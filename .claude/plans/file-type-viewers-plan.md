# Plan: per-file-kind viewers (image zoom, PDF view, plain-text edit)

**Status: macOS done (build-verified; interactive GUI click-through not performed — see**  
**Phase D), Windows explicitly skipped for now per user direction.** Checklist-style plan;  
check items off as they land, keep in sync if the design changes during implementation  
(same convention as `.claude/plans/drag-drop-attachments-plan.md`).

## Context

The sidebar file tree on both macOS and Windows was recently changed to show every file  
in the vault, not just Markdown-flavored ones (`FileNode.swift`/`FileNode.cs`). Nothing  
downstream was updated to match: selecting any file still funnels into the same  
hardcoded Markdown WYSIWYG surface (`MarkdownWebView` + raw-source `TextEditor`/  
`TextBox` overlay). `Workspace.loadSelectedFile()`/`LoadSelectedFileAsync()` force a  
UTF‑8 text decode on every selection; a binary file (image, PDF) just throws and shows a  
generic "could not read" error banner. Now that those files are visibly clickable, this  
needs real handling:

- **Images** — view with pan/zoom, read-only.
- **PDFs** — view only, no editing.
- **Other text files** (`.txt`, `.html`, `.json`, `.yaml`, `.css`, `.js`, …) — a plain  
text editor, edits saved through the existing autosave path. Explicitly **not** routed  
through the Markdown WYSIWYG editor/webview — no rendering, no formatting.
- **Markdown files** — unchanged, keep using today's WYSIWYG editor.

Confirmed via research (macOS, Windows, and Vue/bridge layers, all read-only exploration)  
that this is a green-field feature on both platforms — no image/PDF/plain-text viewer  
code exists anywhere today — and that it should be built **entirely natively**, per  
platform, with **no Rust or Vue changes**. The Vue/Tiptap layer is hard-wired to  
Markdown parse/serialize (`contentType: 'markdown'`, the `Markdown` Tiptap extension,  
the `render()` bridge method) with no plain-text or non-markdown mode, so it's not a fit  
for the text/image/PDF cases and shouldn't be touched. The existing `read_asset` Rust  
tool (used for images embedded *inside* a note) isn't needed either — the  
currently-selected file is a plain on-disk path already reachable directly, exactly like  
`loadSelectedFile()`/`LoadSelectedFileAsync()` already read it today (macOS's sandbox  
scope and Windows' direct file access already cover this).

## Key design decisions

1. **File-kind classification lives next to** `MarkdownFile`, in `FileNode.swift` /  
`FileNode.cs` — the natural home, since sidebar-tree file-type logic already lives  
there. A `FileKind { markdown, image, pdf, plainText }` enum, computed from extension,  
checking `MarkdownFile.matches` first, then a new image-extension set, then `"pdf"`,  
else falling through to `plainText`.
2. **Image extension set (both platforms):** `png, jpg, jpeg, gif, webp, bmp` — the  
common raster formats both `NSImage` and WinUI's `BitmapImage` render natively.  
Deliberately excludes `svg` (XML/text — WinUI's `Image`/`BitmapImage` won't rasterize  
it, and a broken viewer is worse than falling through to the plain-text editor, which  
handles it fine as markup) and `ico` (niche, not worth a special case).
3. **Unrecognized extensions fall through to** `plainText`**, reusing today's existing**  
**UTF‑8-decode-or-error behavior** — so genuinely unknown binary files keep exactly  
today's graceful "Could not read X" fallback, no new dead end needed. This also means  
the load path (`loadSelectedFile()`/`LoadSelectedFileAsync()`) is *identical* for  
Markdown and plain text; only the *view* differs. Only `.image`/`.pdf` skip the text  
read entirely.
4. **No Rust or Vue changes, no** `read_asset` **round-trip for the selected file itself.**  
Every new viewer loads bytes directly from the selected file's own path/URL — the  
same direct-file-I/O pattern `loadSelectedFile()`/`LoadSelectedFileAsync()` already  
use today — rather than going through the vault RPC layer. `read_asset` stays exactly  
as it is, serving assets referenced *inside* rendered Markdown.
5. **Reuse the existing raw-text** `TextEditor`**/**`EditorOverlay` **widget for plain-text**  
**files** rather than building a new text-editing control. On both platforms this  
widget already exists (as the Markdown "Source" raw-text overlay) — for `.plainText`  
kind it's shown unconditionally as the sole view, independent of the Source toggle.
6. **Let the platform's native renderer do PDF/image work, don't hand-roll it.**  
macOS: `PDFKit.PDFView` (pan/zoom/paging built in) and `NSScrollView` with  
`allowsMagnification` (pan/zoom built in). Windows: WinUI has no built-in PDF control,  
so a second minimal `WebView2` instance gets Chromium's built-in PDF viewer for free  
by just navigating to the local file — far less code than `Windows.Data.Pdf` manual  
page rasterization; and `ScrollViewer` with `ZoomMode="Enabled"` around an `Image`  
control for images (WinUI's built-in pinch/ctrl-scroll zoom).

## Checklist

### Phase A — Shared file-kind classification

- [x] macOS `FileNode.swift`: added `ImageFile.extensions` (\`png, jpg, jpeg, gif, webp,
  ```
  bmp`) and `FileKind { markdown, image, pdf, plainText }` with `static func
  of(_ url: URL) -> FileKind` and a `systemImage` helper (also used for the sidebar
  row icon — `FileTreeRow` in `SidebarView.swift` now shows `photo`/`doc.richtext`/
  `doc.plaintext`/`doc.text` per kind instead of a hardcoded `doc.text`; symbol names
  verified to actually resolve via `NSImage(systemSymbolName:)`, not just guessed —
  `doc.pdf` does **not** exist in this SDK, `doc.richtext` does and is used instead).
  Superseded (below): hand-picked SF Symbols + manual tints were replaced with real
  system icons.
  ```
- [x] `SidebarView.swift`'s `FileTreeRow` now renders \`NSWorkspace.shared.icon(forFile:
  ```
  node.url.path)` (via `Image(nsImage:).resizable().scaledToFit().frame(width: 16,
  height: 16)`) instead of an SF Symbol + manual tint — this is Finder's own icon
  lookup, so folders/files get the real system colors and per-type glyphs (including
  QuickLook-style thumbnails for some kinds) automatically, correct by construction
  rather than by guessing SF Symbol names or tint colors. `FileKind.systemImage`/
  `.tint` were removed as a result (dead code, no longer called anywhere) — `FileKind`
  itself stays, still driving `Workspace.selectedFileKind`/content-area routing.
  ```
- [ ] Windows `FileNode.cs` — **explicitly skipped for now** per user direction. Also
  ```
  means the Windows sidebar row icons weren't done (same hardcoded glyph as before);
  revisit together with Phase C.
  ```

### Phase B — macOS (`macos/Markdown/Markdown/`) — DONE (build-verified)

- [x] `Workspace.swift`: added `var selectedFileKind: FileKind` near `isSingleFile`.
- [x] `Workspace.swift`: `loadSelectedFile()` branches on `FileKind.of(url)` first —
  ```
  `.markdown`/`.plainText` unchanged; `.image`/`.pdf` skip the text decode, leaving
  `text`/`hasUnsavedChanges`/autosave untouched.
  ```
- [x] `ContentView.swift`: `detail` now switches on `workspace.selectedFileKind` —
  ```
  `.markdown` keeps `ZStack { preview; if isEditing { editor } }`; `.plainText` shows
  `editor` unconditionally as the sole view; `.image`/`.pdf` show the new
  `ImageViewer(url:)`/`PDFViewerView(url:)`.
  ```
- [x] `ContentView.swift`: the `.toolbar` block (`EditorFormattingToolbar` + "Source"
  ```
  toggle) now only attaches when `workspace.selectedFileKind == .markdown`.
  ```
- [x] New file `ImageViewer.swift` — `NSViewRepresentable` wrapping `NSScrollView` +
  ```
  `NSImageView`, `allowsMagnification = true`. Uses a `Coordinator` (matching
  `MarkdownWebView.swift`'s existing pattern) to track the last-loaded `url` and
  avoid redundant `NSImage(contentsOf:)` disk reads on unrelated re-renders.
  Post-implementation fix (user-reported after real GUI testing): zooming out pinned
  the image to the bottom-left corner instead of centering — `NSClipView` doesn't
  center a document view smaller than its own bounds by default. Fixed with a
  `CenteringClipView: NSClipView` overriding `constrainBoundsRect(_:)`, installed via
  `scrollView.contentView = CenteringClipView()` before setting `documentView`.
  ```
- [x] New file `PDFViewerView.swift` — `NSViewRepresentable` wrapping `PDFKit.PDFView`,
  ```
  `autoScales = true`. **No Xcode project change needed** — `import PDFKit` linked
  automatically (Swift autolinking for system frameworks); confirmed by a clean
  build.
  ```
- [x] Follow-up (user-requested): page-thumbnail panel, toggleable from the toolbar on
  ```
  the right side. `PDFViewerView` now wraps a plain `NSView` container laying out
  `PDFView` (leading, flexible) and `PDFThumbnailView` (trailing, width-animated
  0↔160 via constraint) bound to the same `PDFView` instance via a `Coordinator`, so
  clicking a thumbnail navigates the main view and stays in sync. Real API pitfall
  caught by an actual build (not just SourceKit): `PDFThumbnailView.layoutMode` is
  iOS-only per `PDFThumbnailView.h` — macOS instead uses
  `maximumNumberOfColumns = 1` to force a single vertical column. New
  `ContentView.swift` state (`isShowingPDFThumbnails`, default off) + a toolbar
  toggle button shown only for `.pdf` kind, mirroring the existing "Source" toggle
  pattern for Markdown.
  ```
- [x] \`xcodebuild -project Markdown.xcodeproj -scheme Markdown -configuration Debug
  ```
  -destination 'platform=macOS' build` → **BUILD SUCCEEDED**, twice (once after the
  icon/classification change, again after the viewer/routing change). New files
  (`ImageViewer.swift`, `PDFViewerView.swift`) picked up automatically — this
  project uses Xcode's file-system-synchronized groups, no `.pbxproj` edit needed.
  ```

### Phase C — Windows (`win/MarkdownWin/MarkdownWin/`) — SKIPPED for now (user direction)

- [ ] `Workspace.cs`: add \`public FileKind SelectedFileKind =&gt; SelectedFile is { } path ?
  ```
  FileKindClassifier.Of(path) : FileKind.Markdown;` near `DocumentTitle` (line 127).
  ```
- [ ] `Workspace.cs`: in the `SelectedFile` setter (lines 52–60), alongside the existing
  ```
  `Notify(nameof(DocumentTitle))`, add `Notify(nameof(SelectedFileKind))`.
  ```
- [ ] `Workspace.cs`: rework `LoadSelectedFileAsync()` (lines 557–586) with the same
  ```
  branch as macOS — `.Markdown`/`.PlainText` keep today's
  `File.ReadAllText(url, StrictUtf8)` path into `Text` unchanged; `.Image`/`.Pdf`
  skip the text read entirely, just clear `ErrorMessage`.
  ```
- [ ] `MainWindow.xaml`: extend the content `Grid` at `Grid.Column="2"` (lines 201–212):
  ```
  add an `Image` control inside a `ScrollViewer` with `ZoomMode="Enabled"` for
  images; add a second, minimal `WebView2` control (e.g. `PdfViewer`) for PDFs,
  `Source` set to the local file when visible; both `Visibility`-bound to the
  matching `FileKind`.
  ```
- [ ] `MainWindow.xaml`: reuse `EditorOverlay` (existing `TextBox`, lines 203–211) as the
  ```
  plain-text-file editor — visible whenever kind is `PlainText`, independent of
  `EditToggle`'s checked state (which stays meaningful only for `.Markdown`).
  ```
- [ ] `MainWindow.xaml.cs`: `OnWorkspacePropertyChanged` (lines 69–93) — add a
  ```
  `case nameof(Workspace.SelectedFileKind):` that shows/hides `Preview`/
  `EditorOverlay`/the new image and PDF controls to match the kind, and sets the new
  PDF `WebView2`'s `Source`/the `Image` control's `Source` (`BitmapImage` with
  `UriSource = new Uri(SelectedFile)`) when switching into those kinds.
  ```
- [ ] `MainWindow.xaml.cs`: gate `OnEditToggleChanged` (lines 111–127) and the
  ```
  `CommandBar`'s formatting buttons/`EditToggle` itself on
  `workspace.SelectedFileKind == FileKind.Markdown`, matching the macOS toolbar
  gating.
  ```
- [ ] Cannot be built from this (macOS) session — flag for a Windows-side build pass
  ```
  (`.slnx` via Visual Studio/MSBuild).
  ```

### Phase D — Verification

- [x] `cd rust && cargo test` still green (no Rust changes made, as designed).
- [x] macOS build green (see Phase B) and a basic launch smoke test (app opens, stays
  ```
  running, quits cleanly with the new routing code in place — no startup crash).
  ```
- [ ] macOS **interactive** manual pass — NOT done. This session has no
  ```
  accessibility/screen-recording automation available to drive the GUI (click the
  sidebar, verify the image pans/zooms, etc.) from the shell, so this still needs a
  human (or a future session with that tooling) to: open a vault containing a `.md`
  file, an image, a `.pdf`, and a `.txt`/`.json`/`.yaml` file; click through each in
  the sidebar and confirm Markdown/image/PDF/plain-text each render as designed, and
  that plain-text edits autosave to disk.
  ```
- [ ] Windows — skipped along with Phase C.

## Explicitly out of scope

- Sidebar row icons per file kind (currently hardcoded to a generic doc icon in both  
`FileTreeRow`/`SidebarView.xaml.cs`) — a nice adjacent follow-up, not required for  
content-area rendering.
- Live-reload/file-watcher special-casing for images/PDFs beyond what already exists  
(the tree refresh mechanism is already file-type-agnostic; re-selecting a changed file  
reloads it the same way text files do today).
- Any Rust or Vue/webview changes — none needed, per the design decisions above.

