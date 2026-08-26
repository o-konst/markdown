# Plan: drag-and-drop file import into the editor (vault assets)

**Status: not started.** Checklist-style plan; check items off as they land, keep in sync if
the design changes during implementation (same convention as
`.claude/plans/live-preview-editing-plan.md`).

## Context

The WYSIWYG editor (Tiptap, `vue-project/src/editor/`) currently has no way to bring a local
file into a note. The only "insert image" affordance is a URL-only popover on both platforms
(`EditorFormattingToolbar.swift`'s `imageButton`, Windows' `ImageUrlBox` flyout) — there is no
local-file import at all, and it was explicitly flagged as out-of-scope future work in
`.claude/plans/live-preview-editing-plan.md`'s Phase 5 backlog: *"local-asset import (paste
image → vault file — needs a new `markdown_vault` tool; out of scope until explicitly
requested)."* That request has now been made, for drag-and-drop specifically (paste comes for
free from the same plumbing, so it's included in the same phase).

The ask: drop a file onto the editor → copy it into the vault's `assets/` folder, insert a
markdown attachment link at the drop point, and if the file is an image, render it inline
instead of a bare link.

This requires new capability at every layer: a binary-safe vault tool (today's `write_note`/
`create_note` only accept UTF-8 text — confirmed in `markdown_vault/src/tools.rs`), a way for
the WebView to actually load a vault file's bytes as an `<img src>` (confirmed absent on both
platforms — the existing `WKURLSchemeHandler`/`WebResourceRequested` handlers only serve the
embedded Vue UI bundle, never vault files), and Tiptap-level drop/paste interception (the
`Editor` construction in `useWysiwygDocument.ts` has no `editorProps` at all today).

## Key design decisions

1. **No native (Swift/C#) drag-drop code for detecting the drop.** WKWebView/WebView2 both
   register themselves as OS-level drop destinations for their own content. Dropping onto the
   editor's contenteditable area is expected to be delivered to the web page's native `drop`
   DOM event, which we intercept via Tiptap/ProseMirror's `editorProps.handleDrop` — never
   reaching the outer window's existing whole-window drop handlers (`ContentView.swift:112`
   `.onDrop`, `MainWindow.xaml:16` `RootGrid`'s `Drop`), which stay untouched and keep doing
   "drop a folder/.md file → open it as the document." **This is the single biggest assumption
   in this plan and must be manually verified first** (drop a random file onto the editor pane
   in a dev build and confirm the JS `drop` event fires before/instead of the native handler).
   If it doesn't hold, the fallback is coordinate-checking in the native handlers to skip files
   dropped within the WebView's frame — a contained fix, not a redesign.

2. **Assets live in one vault-root-level `assets/` folder**, matching the user's literal
   wording. Filenames are sanitized to their basename and de-collided with a numeric suffix
   (`photo.png` → `photo-1.png` on conflict) — no existing helper for this in the codebase
   (confirmed by grep), so it's new.

3. **Serialized markdown stays a plain, portable vault-relative link**: `![alt](assets/x.png)`
   for images, `[filename.pdf](assets/filename.pdf)` for everything else — no custom node
   type, no rewriting on save. This is what both Reading view and the Tiptap doc's Markdown
   serialization already produce naturally once the `Image`/`Link` extensions hold that
   `src`/`href`. Confirmed `render.rs`'s ammonia config never overrides `url_relative`, so
   ammonia's default `PassThrough` lets relative `src`/`href` through untouched — Reading view
   needs **zero changes** to display these once the WebView can actually load them.

4. **One new pair of read-only/mutating vault tools, no new FFI function.** Per
   `vault_ffi.rs:1-5`'s explicit design philosophy ("deliberately three functions wide...
   adding a tool is a change in `markdown_vault::tools` alone"), both the write side
   (`import_asset`) and the read side (`read_asset`, used by the WebView's asset-serving
   fallback) are new entries in `markdown_vault::tools::TOOLS`, dispatched through the existing
   generic `md_vault_call`. Zero header/Swift-facade/C#-facade changes needed for the FFI
   surface itself — matches the pattern that already let Phase 6/7 ship with no core-ABI
   churn.

5. **Vault-asset serving reuses the existing scheme handler as a fallback**, not a new scheme.
   `WKURLSchemeHandler`/`WebResourceRequested` already resolve every request via
   `MarkdownCore.asset(forPath:)` (embedded Vue UI bundle only). Extend both: on a lookup miss,
   fall back to calling the new `read_asset` tool against the *currently open vault* and serve
   those bytes instead. This requires threading a vault reference into `MarkdownWebView`/
   `WebPreviewCoordinator` (neither holds one today — confirmed zero `vault`/`Vault` hits in
   either file) — the one non-trivial plumbing change on each native side.

6. **Non-image attachment links open externally, not in-page.** A vault-relative link resolves
   to the *same* `markdown-app://`/`https://markdown-app.local` origin the app already treats
   as an in-place-navigable scheme, so without a change, clicking `[report.pdf](assets/report.pdf)`
   would try to navigate the WebView in-place to a PDF instead of opening it in the OS's
   default app (the existing behavior for genuine external links). Both platforms' navigation
   policy needs a small extra case: when the target is same-scheme but resolves to a vault
   asset (not a known SPA route/embedded asset), cancel in-page navigation and open the real
   on-disk file externally (`NSWorkspace.shared.open` / `Launcher.LaunchFileAsync`) instead.

## Checklist

### Phase A — Rust (`markdown_vault`)

- [ ] Add `base64` as a new dependency (workspace has none today — confirmed via grep across
  all `Cargo.toml`s).
- [ ] `store.rs`: `import_asset(&self, filename: &str, bytes: &[u8]) -> Result<String,
  VaultError>` — sanitize `filename` to a basename, auto-create `assets/` (mirror
  `move_path`'s existing `resolve_for_create` + `fs::create_dir_all(parent)` pattern), pick a
  collision-free name (`name-1.ext`, `name-2.ext`, ...), `fs::write` raw bytes (binary-safe,
  unlike `write()`'s `&str`), commit via `history.commit_all("Import assets/{name}")`, return
  the final vault-relative path. Enforce `MAX_ASSET_BYTES` (propose 25 MiB) via a new
  `VaultError::TooLarge` variant.
- [ ] `store.rs`: `read_asset(&self, path: &str) -> Result<Vec<u8>, VaultError>` —
  `resolve_in(&self.root, path, true)`, reject directories, `fs::read` (binary, not
  `read_to_string`).
- [ ] `store.rs`: small `mime_for(path: &str) -> &'static str` extension→MIME helper (png/jpg/
  jpeg/gif/webp/svg/pdf/... → mime, default `application/octet-stream`), shared by both tools.
- [ ] `tools.rs`: `import_asset` tool entry (`read_only: false, destructive: false`) — input
  `{filename: string, content_base64: string}` → `{path, mime, commit, changed}`. Follow
  `create_note`'s existing template exactly (TOOLS entry + schema() arm + call() arm).
- [ ] `tools.rs`: `read_asset` tool entry (`read_only: true`) — input `{path: string}` →
  `{content_base64, mime}`. Follow `read_note`'s existing template.
- [ ] Tests, matching this crate's existing density: confinement (`../escaped.png` through
  both new tools), collision-suffixing, oversized-content rejection, binary round-trip (import
  then read yields byte-identical content), mime-detection table.
- [ ] `cd rust && cargo test` green (~143 existing tests + new ones).

No `markdown_core` FFI changes — `md_vault_call`/`md_vault_tools` already expose these
generically once added to `markdown_vault`.

### Phase B — Vue (`vue-project`)

- [ ] `bridge/nativeBridge.ts`: add `{ method: 'importAsset', filename: string, contentBase64:
  string }` to the `HostRequest` union (alongside the existing 5), and an exported
  `importAsset(filename, contentBase64): Promise<{path: string; mime: string}>` copying
  `render()`'s un-guarded promise pattern (lines 157-160) — the caller needs the
  result/error, unlike the ack-only `reportEdit`-style calls.
- [ ] New `vue-project/src/editor/fileImport.ts`: a pure, testable `buildInsertionContent(mime,
  path, filename)` returning either an `image` node spec or a link-marked text-run spec, plus
  the DOM-event glue (`handleDrop`/`handlePaste` bodies) that reads `File`/`Blob` objects from
  `event.dataTransfer`/`event.clipboardData`, converts to base64 (`file.arrayBuffer()` →
  base64), calls `importAsset`, computes the drop position via `view.posAtCoords`, and calls
  `editor.chain().focus().insertContentAt(pos, content).run()`.
- [ ] Client-side max-size check (25 MiB, matching the Rust cap) before calling the bridge;
  fail silently-but-logged for v1 (no toast UI — v2 nicety, not blocking).
- [ ] `editor/useWysiwygDocument.ts`: add `editorProps: { handleDrop, handlePaste }` to the
  `new Editor({...})` call (currently has none at all, lines 75-81), wired to the new module.
  `handleDrop` returns `false` (defers to ProseMirror's default) when `moved` is true (an
  internal drag-reorder, not an external file drop).
- [ ] Tests: `fileImport.spec.ts` (pure-function unit tests + a mocked-bridge integration test,
  following `useWysiwygDocument.spec.ts`'s dependency-injected-bridge convention so no real
  WebView is needed), extending `pasteSafety.spec.ts` with a paste-file case.
- [ ] `bun run test` / `bun run type-check` green.

Reading view (`MarkdownPreview.vue`) needs **no changes** — it already just renders whatever
HTML Rust produces via `v-html`, and relative `src`/`href` values pass ammonia unchanged.

### Phase C — macOS (`macos/Markdown/Markdown/`)

- [ ] `VaultStore.swift`: typed convenience wrappers `importAsset(filename: String, data:
  Data) -> (path: String, mime: String)?` and `readAsset(path: String) -> (data: Data, mime:
  String)?`, base64 encode/decode around the existing generic `call(_:_:)`.
- [ ] `MarkdownWebView.swift`: new `"importAsset"` case in the `WKScriptMessageHandlerWithReply`
  switch (matching `MarkdownWebView.swift:307-375`'s pattern) — decode `filename`/
  `contentBase64` from the message body, call `vaultStore.importAsset(...)`, reply with
  `{path, mime}` JSON (or an error string, matching the existing `"render"` case's guard
  style).
- [ ] Extend `WKURLSchemeHandler.webView(_:start:)` (`MarkdownWebView.swift:270-303`): on
  `MarkdownCore.asset(forPath:)` returning `nil`, fall back to `vaultStore.readAsset(path:)`
  before failing the task; respond with those bytes and the returned mime type.
- [ ] Extend the navigation-policy delegate: when a would-be in-place navigation's URL is
  same-scheme but not a known embedded route, resolve it against the vault root and open
  externally via `NSWorkspace.shared.open(_:)` instead of navigating/failing.
- [ ] Thread a vault reference (`VaultStore?` / vault root `URL?`) into `MarkdownWebView`'s
  properties and `WebPreviewCoordinator`'s init (neither holds one today), sourced from
  `Workspace.vault`/`Workspace.root` at the `ContentView.swift` call site — same pattern as
  Phase 3's `flushEditorPendingEdit` closure threading.
- [ ] `xcodebuild -project macos/Markdown/Markdown.xcodeproj -scheme Markdown build` clean.

### Phase D — Windows (`win/MarkdownWin/MarkdownWin/`)

Windows already has a real `VaultStore.cs` and `Workspace.cs` vault plumbing (confirmed —
`Workspace.cs:127,474`; the `windows-app.md` doc's "no vault facade" claim is stale). Mirror
macOS file-for-file, this codebase's established convention.

- [ ] `VaultStore.cs`: `ImportAsset`/`ReadAsset` convenience wrappers, same shape as macOS.
- [ ] `MarkdownWebView.xaml.cs`: new `"importAsset"` case in `OnWebMessageReceived`.
- [ ] Extend `OnWebResourceRequested`'s `MarkdownCore.Asset(path)` miss to fall back to
  `VaultStore.ReadAsset`.
- [ ] Extend `OnNavigationStarting`/`OnNewWindowRequested` the same way as macOS, using
  `Launcher.LaunchFileAsync` for the resolved on-disk vault file.
- [ ] Thread the vault reference the same way, sourced from `Workspace.cs`'s `vault`/
  `GetOrOpenVault()`.
- [ ] `dotnet build MarkdownWin.slnx -c Debug -p:Platform=x64` (plain + `-t:Rebuild`) clean.
- [ ] Manual interactive verification — needs a human with the app actually running; not
  claimable from a non-Windows environment (same limitation every prior phase hit).

### Cross-cutting verification

- [ ] Test the drop-target-conflict assumption (Decision #1) **first**, before investing in
  the rest of the feature — confirms whether "no native drop code needed" actually holds.
- [ ] `cd rust && cargo test` — new + existing tests green.
- [ ] `cd vue-project && bun run test && bun run type-check` — new + existing tests green.
- [ ] macOS manual matrix: drag an image and a non-image file (e.g. a PDF) onto an open note
  in the editor; confirm the image renders inline, the PDF becomes a clickable link that opens
  externally, both persist correctly after reopening the note (plain markdown link survives a
  save/reload round-trip; Reading view also shows the image).
- [ ] Windows manual matrix: same, once a human can run the packaged app.
- [ ] Update `.claude/plans/live-preview-editing-plan.md`'s Phase 5 backlog line ("local-asset
  import... out of scope until explicitly requested") to point at this plan once done.

## Out of scope (flag, don't build)

- Image resize handles in the editor (already an existing Phase 5 backlog item).
- A toast/error UI for a failed or oversized import (log-only for v1).
- Multi-file drop (only the first dropped file is handled, matching this codebase's existing
  `providers.first`/`items[0]` convention for the whole-window drop handlers).
- In-app preview for non-image attachment types — clicking always hands off to the OS.
