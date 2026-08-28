# Plan: drag-and-drop file import into the editor (vault assets)

**Status: code-complete, manual verification pending.** Phases A (Rust), B (Vue/Tiptap), and C  
(macOS) are implemented and build/test-verified. Phase D (Windows) is implemented but could  
only be reviewed, not built, from this macOS session. Nothing has been run interactively  
against a real vault on either platform yet — see the cross-cutting verification checklist.  
Checklist-style plan; check items off as they land, keep in sync if the design changes during  
implementation (same convention as `.claude/plans/live-preview-editing-plan.md`).

## Context

The WYSIWYG editor (Tiptap, `vue-project/src/editor/`) currently has no way to bring a local  
file into a note. The only "insert image" affordance is a URL-only popover on both platforms  
(`EditorFormattingToolbar.swift`'s `imageButton`, Windows' `ImageUrlBox` flyout) — there is no  
local-file import at all, and it was explicitly flagged as out-of-scope future work in  
`.claude/plans/live-preview-editing-plan.md`'s Phase 5 backlog: *"local-asset import (paste*  
*image → vault file — needs a new* `markdown_vault` *tool; out of scope until explicitly*  
*requested)."* That request has now been made, for drag-and-drop specifically (paste comes for  
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
"drop a folder/.md file → open it as the document." **This is the single biggest assumption**  
**in this plan and must be manually verified first** (drop a random file onto the editor pane  
in a dev build and confirm the JS `drop` event fires before/instead of the native handler).  
If it doesn't hold, the fallback is coordinate-checking in the native handlers to skip files  
dropped within the WebView's frame — a contained fix, not a redesign.
2. **Assets live in one vault-root-level** `assets/` **folder**, matching the user's literal  
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

### Phase A — Rust (`markdown_vault`) — DONE

- [x] Add `base64` as a new dependency (`0.22`, matching the version already resolved

  transitively in `Cargo.lock`).
- [x] `store.rs`: \`import\_asset(&amp;self, filename: &amp;str, bytes: &amp;\[u8\]) -&gt; Result&lt;(String,

  Option&lt;String&gt;), VaultError&gt;`— sanitizes`filename`to a basename, auto-creates`assets/`via`resolve\_for\_create`+`fs::create\_dir\_all(parent)`(mirroring`move\_path`), picks a collision-free name (`name-1.ext`,` name-2.ext`, ...) via a loop over` resolve\_for\_create`,` fs::write`s raw bytes, commits via` history.commit\_all("Import {path}")`. Enforces` MAX\_ASSET\_BYTES = 25 MiB`via new`VaultError::TooLarge\` variant.
- [x] `store.rs`: `read_asset(&self, path: &str) -> Result<Vec<u8>, VaultError>` — binary

  `fs::read` (not `read_to_string`), confinement + directory rejection.
- [x] `store.rs`: `mime_for(name: &str) -> &'static str` extension→MIME helper, plus a private

  `split_stem_ext` helper for collision-suffixing.
- [x] `tools.rs`: `import_asset` tool (`read_only: false, destructive: false`) — input

  `{filename, content_base64}` → `{path, mime, commit, changed}`.
- [x] `tools.rs`: `read_asset` tool (`read_only: true`) — input `{path}` →

  `{content_base64, mime}`.
- [x] Tests added: confinement (`read_asset` added to the existing tools-layer escape test;

  `import_asset`'s basename-only sanitization tested directly in `store.rs`), collision  
  suffixing (with and without an extension), oversized-content rejection, binary round-trip  
  (0-255 byte content), mime-detection table, invalid-base64 tool-layer error, tool-layer  
  import→read round trip.
- [x] `cd rust && cargo test` green — **90/90** in `markdown_vault` (was 77), whole workspace

  (`markdown_core` 29, `markdown_agent` 35, vendored `solomd-mcp` 22) unaffected, all green.

No `markdown_core` FFI changes — `md_vault_call`/`md_vault_tools` already expose these  
generically once added to `markdown_vault`.

### Phase B — Vue (`vue-project`) — DONE

- [x] `bridge/nativeBridge.ts`: added `{ method: 'importAsset', filename, contentBase64 }` to

  `HostRequest`, an `ImportedAsset { path, mime }` reply type, and an exported  
  `importAsset(filename, contentBase64): Promise<ImportedAsset>` copying `render()`'s  
  un-guarded promise pattern.
- [x] New `vue-project/src/editor/fileImport.ts`: pure \`buildInsertionContent(mime, path,

  filename)`(image node for`image/\*`, link-marked text run otherwise),` importFileAt`(base64-encodes via`file.arrayBuffer()`, calls the injected` importAsset`, inserts at a position, logs-and-no-ops on oversize/failure), and` createFileImportHandlers(getEditor,  
  deps)`building the`handleDrop`/`handlePaste`pair —`getEditor`is a lazy accessor since`editorProps`must exist before the`Editor\` instance does.
- [x] Client-side `MAX_IMPORT_BYTES = 25 MiB` check before calling the bridge; failure is

  `console.error`-logged and otherwise silent (no toast UI — v2 nicety, not blocking).
- [x] `editor/useWysiwygDocument.ts`: added `editorProps: { handleDrop, handlePaste }` to the

  `new Editor({...})` call, via a lazily-assigned `editorRef` closure (handlers only ever  
  fire after construction completes) and a new `importAsset` option for test injection.  
  `handleDrop` returns `false` when `moved` is true (internal drag-reorder) or there are no  
  files (defers to ProseMirror's default paste/drop handling either way).
- [x] Tests: `fileImport.spec.ts` (12 tests — pure-function, oversize/failure handling, and

  handler-level `moved`/no-files guards with a mocked bridge), plus one wiring-confirmation  
  test added to `useWysiwygDocument.spec.ts` (`editor.view.props.handleDrop`/`handlePaste`  
  are real functions).
- [x] `bun run test` — **65/65** (was 53). `bun run type-check` clean. `bun run build-only`

  clean (750.28 kB raw, \~1.3 kB over the pre-existing 748.96 kB baseline — no new dependency  
  pulled in).

Reading view (`MarkdownPreview.vue`) needs **no changes** — it already just renders whatever  
HTML Rust produces via `v-html`, and relative `src`/`href` values pass ammonia unchanged.

### Phase C — macOS (`macos/Markdown/Markdown/`) — DONE (build-verified; manual UI test pending)

- [x] `VaultStore.swift`: `importAsset(filename:data:) throws -> (path: String, mime: String)`

  and `readAsset(_:) throws -> (data: Data, mime: String)`, base64 encode/decode around the  
  existing generic `call(_:_:)`.
- [x] `Workspace.swift`: two new public methods, `importAsset(filename:data:)` and

  `readAsset(_:)`, both routed through the existing private `vaultStore()` lazy-open helper  
  (same one `flushPendingSave` already uses). **Flagged trade-off, not solved further**:  
  since `Vault::open` always bakes a baseline commit on first open, rendering a note that  
  references a vault asset can now trigger that baseline commit slightly earlier than an  
  actual edit would have — accepted, since an asset reference can only exist because  
  something already imported it through this same vault.
- [x] `MarkdownWebView.swift`: added `importAsset`/`readAsset`/`vaultRootURL` to both the

  `MarkdownWebView` struct and `WebPreviewCoordinator`, threaded through `makeCoordinator()`  
  and both `updateNSView`/`updateUIView`. New `"importAsset"` case in the  
  `WKScriptMessageHandlerWithReply` switch. `WKURLSchemeHandler.webView(_:start:)` now falls  
  back to `readAsset(url.path)` when `MarkdownCore.asset(forPath:)` misses, sharing one  
  `respond(...)` helper for both paths. Navigation policy: a same-scheme  
  (`markdown-app://`) link-activated navigation that isn't a known embedded route now  
  resolves against `vaultRootURL` and opens externally via `NSWorkspace.shared.open(_:)`  
  instead of navigating in place.
- [x] `ContentView.swift`: wired `importAsset`/`readAsset`/`vaultRootURL` at the one

  `MarkdownWebView(...)` call site, sourced from `workspace.importAsset`/`workspace.readAsset`/  
  `workspace.root?.url`.
- [x] \`xcodebuild -project macos/Markdown/Markdown.xcodeproj -scheme Markdown -configuration

  Debug build `→ **`\*\* BUILD SUCCEEDED **\`**, zero errors (SourceKit showed the same  
  transient "cannot find X in scope" false positives this codebase's plan already documents  
  for a DerivedData-less session — confirmed stale by the real build succeeding).
- [ ] Manual UI verification (drag an image/PDF onto the editor, confirm inline render vs.

  external-open, confirm persistence across reopen) — **not run**, needs a human with the  
  app actually open against a real vault, per this plan's cross-cutting verification section.

### Phase D — Windows (`win/MarkdownWin/MarkdownWin/`) — DONE (code-complete; unbuildable from macOS)

Windows already has a real `VaultStore.cs` and `Workspace.cs` vault plumbing (confirmed —  
`Workspace.cs:127,474`; the `windows-app.md` doc's "no vault facade" claim is stale). Mirrored  
macOS file-for-file, this codebase's established convention.

- [x] `VaultStore.cs`: `ImportAsset(filename, data) -> (Path, Mime)` and \`ReadAsset(path) -&gt;

  (Data, Mime)`, same shape as macOS, base64 via` Convert.To/FromBase64String\`.
- [x] `Workspace.cs`: `ImportAssetAsync`/`ReadAssetAsync`, both routed through

  `GetOrOpenVault()` and guarded by the existing `vaultGate` semaphore (same serialization the  
  write path already uses). Same accepted vault-eager-open trade-off as macOS, documented  
  inline.
- [x] `MarkdownWebView.xaml.cs`: added `ImportAsset`/`ReadAsset`/`VaultRootPath` properties.

  `OnWebResourceRequested` is now `async void` with a `CoreWebView2Deferral`, falling back to  
  `ReadAsset` on an embedded-asset miss (shared `BuildResponse` helper factored out of the  
  original inline response-building code). New `"importAsset"` case in `OnWebMessageReceived`  
  (now `async void`). `OnNavigationStarting` restructured: a same-origin, user-initiated  
  navigation that isn't a known embedded route (`MarkdownCore.Asset(...)` misses) now resolves  
  against `VaultRootPath` and opens externally via a new `LaunchFileExternallyAsync` helper  
  (`StorageFile.GetFileFromPathAsync` + `Launcher.LaunchFileAsync`), mirroring macOS's  
  `NSWorkspace.shared.open(_:)` path.
- [x] `MainWindow.xaml.cs`: wired `Preview.ImportAsset`/`ReadAsset`/`VaultRootPath` at

  construction, plus re-syncing `VaultRootPath` in `OnWorkspacePropertyChanged`'s existing  
  `nameof(Workspace.Root)` case.
- [ ] `dotnet build` — **could not run**: this session is on macOS, and the very first step of

  `dotnet build MarkdownWin.slnx` fails immediately with `NETSDK1100` ("target Windows on this  
  operating system") before touching any project code — a pre-existing platform limitation,  
  not something introduced by this change (confirmed: the same command fails identically on  
  an unmodified checkout). Every changed file was instead reviewed line-by-line against the  
  existing codebase's established API usage (`CoreWebView2Deferral`/`GetDeferral()`,  
  `IsUserInitiated`, `StorageFile.GetFileFromPathAsync`, `Launcher.LaunchFileAsync` are all  
  long-stable WebView2/WinRT APIs already used elsewhere in this file or its Phase 4d  
  precedent) — **not build-verified**, unlike every other phase in this plan.
- [ ] Manual interactive verification — needs a human on an actual Windows machine, same

  limitation every prior Windows phase in `.claude/plans/live-preview-editing-plan.md` hit.

### Cross-cutting verification

- [x] `cd rust && cargo test` — **90/90** in `markdown_vault` (was 77); whole workspace

  (`markdown_core` 29, `markdown_agent` 35, vendored `solomd-mcp` 22) green throughout every  
  phase of this implementation, re-confirmed after the Rust changes and again after the full  
  change set landed.
- [x] `cd vue-project && bun run test && bun run type-check` — **65/65** (was 53), type-check

  clean, `bun run build-only` clean.
- [x] macOS: real \`xcodebuild -project macos/Markdown/Markdown.xcodeproj -scheme Markdown

  -configuration Debug build`→`\*\* BUILD SUCCEEDED \*\*\`.
- [ ] Windows: **not build-verified** — this implementation session ran on macOS, where

  `dotnet build` on this WinUI3 project fails immediately (`NETSDK1100`) before touching any  
  project code, a pre-existing platform limitation unrelated to this change. Code was  
  reviewed line-by-line against established API usage instead; needs a real `dotnet build`  
  (and `-t:Rebuild`) on Windows to confirm.
- [ ] Test the drop-target-conflict assumption (Decision #1) — **not empirically verified**:

  no running instance of either app was available in this session to actually drag a file  
  onto the editor and observe whether the JS `drop` event wins over the native whole-window  
  handler. The architecture (WKWebView/WebView2 registering as their own drop destinations)  
  supports the assumption, but this needs a human to actually try it, on **both** platforms,  
  before the rest of the manual matrix below is meaningful — if it doesn't hold, the native  
  handlers need a coordinate-based skip, not a redesign (see Decision #1).
- [ ] macOS manual matrix: drag an image and a non-image file (e.g. a PDF) onto an open note

  in the editor; confirm the image renders inline, the PDF becomes a clickable link that opens  
  externally, both persist correctly after reopening the note (plain markdown link survives a  
  save/reload round-trip; Reading view also shows the image).
- [ ] Windows manual matrix: same, once a human can run the packaged app.
- [ ] Update `.claude/plans/live-preview-editing-plan.md`'s Phase 5 backlog line ("local-asset

  import... out of scope until explicitly requested") to point at this plan once the manual  
  matrix above closes it out.

## Bug found in manual testing, fixed (2026-08-27)

**Report**: dropping a file onto the editor inserted `![name](assets/name.png)` correctly  
(confirmed via Source view), but the image rendered broken and the file appeared not to have  
been copied to `assets/`.

**Root cause**: `md_asset_lookup` (`MarkdownCore.asset(forPath:)` / `MarkdownCore.Asset(path)`)  
single-page-app-falls-back to `index.html` for *any* unmatched path — it never returns  
`nil`/`null`. Both the WebView scheme-handler's "is this a known embedded file, or should I  
try the vault" check and the navigation-policy's "is this a known embedded route" check  
(Phase C/D) relied on that lookup returning nil for an unmatched path, which it never does —  
so the vault-asset fallback branch was dead code on both platforms, and every request for  
`assets/whatever.png` was silently served `index.html`'s bytes as `text/html`, which a  
browser can't render as an image (hence "broken", and — since the actual imported file was  
never read — reads as "not copied," even though `import_asset` genuinely had written it).

**Fix**: added a new `md_asset_exists` FFI function (`markdown_core::assets::exact`, no SPA  
fallback) alongside the existing `md_asset_lookup`, plus `MarkdownCore.embeddedAssetExists(forPath:)`  
(Swift) / `MarkdownCore.AssetExists(path)` (C#). Both the scheme-handler fallback and the  
navigation-policy check now use the exact-match function to decide "real embedded file" vs.  
"try the vault", with the original SPA fallback preserved as the final resort after both the  
embedded and vault lookups miss. `cargo test` (37/37 in `markdown_core`, up from 29 — 8 new  
FFI tests including the specific regression case) and a real `xcodebuild build` (`BUILD SUCCEEDED`) both green after the fix. The Windows-side fix could not be build-verified for  
the same platform reason as Phase D.

## Out of scope (flag, don't build)

- Image resize handles in the editor (already an existing Phase 5 backlog item).
- A toast/error UI for a failed or oversized import (log-only for v1).
- Multi-file drop (only the first dropped file is handled, matching this codebase's existing  
`providers.first`/`items[0]` convention for the whole-window drop handlers).
- In-app preview for non-image attachment types — clicking always hands off to the OS.

