# Plan: live-preview (Typora-style) WYSIWYG markdown editing

**Status: in progress. Phases 0-3 merged into `main`** (2026-08-25, merge commit after  
`worktree-agent-a893373f5d6decb76` — re-verified post-merge with a real `bun run test`  
(26/26), `bun run type-check`, and a real `xcodebuild clean build` of `main`'s own  
`macos/Markdown/Markdown.xcodeproj`, all clean). Opening the project normally in Xcode now  
shows the real WYSIWYG editor. This is the actionable checklist derived from the research  
in  
`.claude/docs/live-preview-editing-research.md` (full rationale, code citations, and  
alternatives-considered live there and in its four linked prior-art docs — jotty,  
MarkText/Muya, Tiptap, Quill). This plan file tracks *progress*; check off items as they  
land, and keep it in sync if the design changes during implementation.

## Decisions locked in (see research doc for why)

- Editing surface moves into the Vue WebView using **Tiptap** (`@tiptap/core` +
`@tiptap/vue-3` + `@tiptap/pm` + extensions), not raw ProseMirror.
- Markdown↔doc conversion uses the first-party **`@tiptap/markdown`** package directly —
no hand-written `markdown-it`/`prosemirror-markdown` layer.
- **Typora-style true WYSIWYG** (not Obsidian-style decorations); both **macOS and
Windows** in scope together.
- Native `TextEditor`/`EditorOverlay` are **kept**, repurposed as a "Source" fallback —
not deleted.
- Reading view (`MarkdownPreview.vue` + Rust's sanitized `render_markdown`) is **kept
unchanged** as an alternate mode.
- Two custom extensions are needed on top of `@tiptap/markdown`: **footnotes** and
**`{#custom-id}` heading anchors** — both absent from Tiptap itself and from every
prior-art app researched.

## Open items to confirm before/at implementation start

- [x] Confirm exact current Tiptap package names/versions at install time — task list/item
  ```
  packaging (`@tiptap/extension-list` vs. separate packages) has already changed once
  between the version jotty pinned and the version researched here.
  ```
- [x] Decide and confirm the fixture directory location (`fixtures/markdown-roundtrip/*.md`
  ```
  proposed, sibling to `rust/`/`vue-project/`) before creating a new top-level
  directory.
  ```
- [x] Re-verify all new dependency licenses (expected MIT throughout) at actual install
  ```
  time, not just from this research pass.
  ```

---

## Phase 0 — Spike (hard gate; Vue-only, no native changes)

**Status: DONE, gate passed.** Implemented by a forked subagent in an isolated worktree
(`.claude/worktrees/agent-a893373f5d6decb76`, branch `worktree-agent-a893373f5d6decb76`,
commit `cd6187c`), then independently re-verified (re-ran `bun install && bun run test`,
`bun run type-check`, and a production `vite build`) rather than taken on the agent's
report alone. **Merged into `main`** along with Phases 1-3 — see the status line at the
top of this file.

- [x] Add Tiptap deps (`@tiptap/core`, `@tiptap/vue-3`, `@tiptap/pm`, `@tiptap/starter-kit`,
  ```
  `@tiptap/markdown`, `@tiptap/extension-table`, `@tiptap/extension-list`,
  `@tiptap/extension-image`, `@tiptap/extension-link`,
  `@tiptap/extension-code-block-lowlight` + `lowlight`) to `vue-project/package.json`
  via `bun`, all resolved at 3.30.3. **Deviation**: dropped the separate
  `-table-row`/`-header`/`-cell` packages named in the research doc — confirmed via
  actual `node_modules` source that `@tiptap/extension-table` already bundles those.
  ```
- [x] Define the ProseMirror schema (`vue-project/src/editor/schema.ts`): doc, paragraph,
  ```
  heading w/ `id` attr, blockquote, lists, task list/item, code block w/ language,
  table w/ `align` attr, image, horizontal rule, hard break, footnote nodes; marks
  bold/italic/strike/code/link — no raw-HTML node type. **Deviation**: table column
  `align` needs no custom attr — `@tiptap/extension-table`'s bundled `TableCell`/
  `TableHeader` already carry a native `align` attr.
  ```
- [x] Minimal dev-only `WysiwygEditor.vue` spike (reachable only via `bun run dev` →
  ```
  `/wysiwyg-spike.html`; confirmed absent from the production `vite build` output —
  `dist/` unchanged at 68.69 kB JS / 27.12 kB gzip, no Tiptap code shipped).
  ```
- [x] Footnote custom extension (`vue-project/src/editor/markdown/footnoteExtension.ts`):
  ```
  hand-written `marked` tokenizers for `[^label]` refs/defs (zero prior art anywhere —
  Tiptap, jotty, and Quill all lack footnotes; only MarkText's Muya has a reference
  implementation, which this follows for the 4-space continuation-indent rule).
  ```
- [x] Heading `{#custom-id}` custom extension
  ```
  (`vue-project/src/editor/markdown/headingIdExtension.ts`): `splitHeadingAttributes`
  ported byte-for-byte from `rust/markdown_vault/src/outline.rs`.
  ```
- [x] `vitest` devDependency + `test` script (`vitest run`). Fixture corpus at
  ```
  `fixtures/markdown-roundtrip/{headings,footnotes,full-document}.md` (repo root,
  confirmed location).
  ```
- [x] `roundtrip.spec.ts`: parse→serialize→parse structural-equality assertions +
  ```
  first-pass-serialization snapshot tests. **7/7 passing**, independently re-verified
  via `bun install && bun run test` — including confirming the snapshot baseline is
  real and stable (`vitest run` clean/no-diff on repeat, not silently rewriting
  itself). `vue-tsc --build` also clean.
  ```
- [x] **Gate check: PASSED.** Fidelity for both custom extensions and their interaction
  ````
  with standard GFM constructs (tables w/ alignment, task lists, nested lists, code
  fences with a backtick run) is trustworthy. One real bug was caught by the fixture
  corpus and fixed: Tiptap's stock `CodeBlock`/`CodeBlockLowlight` always emits a fixed
  ` ``` ` fence regardless of content, which corrupts on re-parse if the code contains
  a backtick run — fixed with a new `codeBlockFenceExtension.ts` that recomputes fence
  length from the content's longest backtick run (same rule Muya uses). Link protocol
  safety (`javascript:`/`vbscript:`) confirmed safe by default via
  `@tiptap/extension-link`'s `isAllowedUri`, no config change needed — `Image`'s `src`
  has no scheme validation, low-risk as-is since `<img src>` doesn't execute script,
  but worth a second look in Phase 2/5.
  ````

## Phase 1 — Bridge protocol

**Status: DONE.** Same worktree/branch as Phase 0
(`.claude/worktrees/agent-a893373f5d6decb76`, branch `worktree-agent-a893373f5d6decb76`),
commit `2d82f96`. Independently re-verified (`bun run test` → 14/14, `bun run type-check`
clean, plus direct code review of `nativeBridge.ts` and `useWysiwygDocument.ts`) rather
than taken on the agent's report alone.

- [x] Added `{ method: 'documentEdit', text: string }` to `HostRequest` in
  ```
  `vue-project/src/bridge/nativeBridge.ts`; `reportEdit(text): Promise<void>` follows
  the exact `reportOutlineState` shape (ack-only, swallows "unknown method" for hosts
  that predate this).
  ```
- [x] Undebounced "first keystroke of a burst" signal: \*\*design choice — reused
  ```
  `reportEdit` itself** rather than adding a second bridge method. The composable
  tracks burst-in-flight state and fires the same call immediately on the first
  keystroke, debounced (200ms default) thereafter. Keeps the bridge surface at one
  method; Phase 3/4 only need one inbound native case, not two.
  ```
- [x] `flushPendingEdit(): Promise<string>` on the composable — cancels any pending
  ```
  debounce, reports immediately, returns the flushed markdown text.
  ```
- [x] `useWysiwygDocument()` composable (`vue-project/src/editor/useWysiwygDocument.ts`):
  ```
  owns a real Tiptap `Editor` over the Phase 0 schema; applies inbound pushes only
  when `text !== editor.getMarkdown()` (verified via a test asserting **no ProseMirror
  transaction is even applied** on an identical push, not just a no-op check); resets
  undo/redo by rebuilding `EditorState` via `EditorState.create` (not `.apply(tr)`) —
  `prosemirror-history` has no public clear API, this is the standard technique;
  verified undo depth genuinely reaches 0 after an external push, via a real
  `undoDepth()` check, not a mock. All bridge calls are dependency-injected so tests
  don't need a real WebView.
  ```
- [x] Tests (`useWysiwygDocument.spec.ts`, `happy-dom` env scoped to just this file so
  ```
  Phase 0's round-trip suite stays on faster plain `node`): 7 tests, real
  `Editor`/ProseMirror integration (not just extracted pure-logic stubs) — burst/
  debounce timing, `flushPendingEdit`, the identical-push guard, undo-depth-resets,
  and mid-burst-external-push debounce cancellation. **14/14 total tests green**
  (7 from Phase 0 + 7 new), `vue-tsc --build` clean.
  ```
- [x] **Real deviation found by testing, not assumed**: Tiptap's `element: null` "headless"
  ```
  mode skips `createView()` entirely, leaving the editor with **zero ProseMirror
  plugins** (no undo history, no input rules, no keymaps) — confirmed by reading
  `@tiptap/core`'s source after a first test run silently proved it (`undoDepth`
  stayed 0 with no error). Fixed by defaulting to a **detached** `<div>` (created, never
  appended to the page) instead, which does run `createView()` — invisible until
  something mounts it. Documented in the composable's own doc comment so Phase 2
  doesn't rediscover this.
  ```

## Phase 2 — Editor component (`vue-project/`)

**Status: DONE.** Same worktree/branch, commit `1086ce7`. Independently re-verified
(`bun run test` → 26/26, `bun run type-check` clean, production `bun run build-only`
confirming the reported bundle size, plus direct code review of `headingIdExtension.ts`,
`useWysiwygDocument.ts`'s history-reset fix, `useEditorOutline.ts` + its test cross-checked
line-for-line against `rust/markdown_vault/src/outline.rs`'s actual test module, and
`pasteSafety.spec.ts`) rather than taken on the agent's report alone.

- [x] `WysiwygEditor.vue` wired into `App.vue` alongside the kept `MarkdownPreview.vue`
  ```
  Reading view, via a `mode: 'reading' | 'edit'` toggle using `v-show` (not `v-if`, so
  switching never rebuilds the editor or loses undo history) — both share one
  scrolling container so `useActiveHeading` scroll-spy keeps working in both modes.
  **`dist/` size, measured before/after**: 68.69 kB → 733.98 kB raw (27.12 kB →
  235.30 kB gzip), confirmed by an independent rebuild — the real, expected cost of
  Tiptap/ProseMirror/lowlight now shipping in the production bundle.
  ```
- [x] Table node views: `@tiptap/extension-table` + a `TableControls.vue` toolbar
  ```
  (add/delete row/column, gated on `editor.isActive('table')`). **Scope tradeoff,
  flagged rather than silently substituted**: this is a single toolbar, not the
  research doc's per-table-edge hover handles (which needs a custom Vue NodeView) —
  documented in the component itself as a deliberate v1 simplification.
  ```
- [x] Task item checkboxes: confirmed via a real mounted-component test (`@vue/test-utils`,
  ```
  new MIT devDependency) — an actual `<input type="checkbox">` that toggles state on
  click, not just a schema-level assertion.
  ```
- [x] Image node view: inline render only, no resize handles (v2 deferred, as directed).
- [x] Code block: `@tiptap/extension-code-block-lowlight` + curated language subset,
  ```
  confirmed via a mounted test that `.hljs-*` highlight spans actually render.
  ```
- [x] `slugify()` extracted verbatim into `vue-project/src/composables/slugify.ts`
  ```
  (Reading view unaffected — `useDocumentOutline.ts` just imports it now).
  ```
- [x] `useEditorOutline.ts` (+ pure `buildOutlineFromDoc` helper) ports
  ```
  `useDocumentOutline.ts`'s exact ancestor-stack/dedupe-suffix algorithm onto
  `doc.descendants`. Tests port **all** of `outline.rs`'s test cases — duplicate ids,
  explicit `{#id}`, emoji-only fallback, skipped-heading-level nesting, and the full
  `matches_the_previews_outline_for_the_reference_document` case — **19/19 match
  byte-for-byte**, cross-checked directly against the Rust source in this review, not
  just trusted. One structural divergence honestly flagged in the test file itself
  (not glossed over): `outline.rs`'s "heading inside a fenced code block" case has no
  equivalent here, since a parsed doc's code-block content can never re-parse into
  heading nodes in the first place — a real difference between the two
  implementations' input domains, not a quietly-accepted gap.
  ```
- [x] Paste handling: real tests (not re-assertions) confirm `javascript:`/`vbscript:` link
  ```
  hrefs are rejected on HTML paste, a control-case `https:` link still works (so the
  rejection isn't "reject everything"), and `<img src="javascript:...">` is confirmed
  to pass through **unvalidated** exactly as the research doc suspected — now pinned
  down by a test tracking that known, low-risk-as-is behavior instead of asserting it
  a third time on faith.
  ```
- [x] **Real bugs found by testing, not assumed**:
  - `headingIdExtension.ts` had `rendered: false` on the `id` attr, so explicit `{#id}`
  headings never got a real DOM `id` — broke outline anchor-scrolling entirely. Fixed;
  auto-slugged headings (the common case) get their id stamped onto the rendered DOM
  directly by `WysiwygEditor.vue` from the computed outline (mirroring how Reading
  view's `buildOutline` mutates ids onto parsed HTML).
  - Switching `useWysiwygDocument.ts` to `@tiptap/vue-3`'s `Editor` subclass (needed for
  `<EditorContent>` to type-check) silently broke the Phase 1 undo-reset: the Vue
  subclass tracks state in a separate Vue `customRef` that only its own
  `registerPlugin`/`unregisterPlugin` keep in sync — the raw `view.updateState()` from
  Phase 1 bypassed it, so `editor.state` stayed stale after a reset even though the
  underlying view was correct. Caught by the *existing* Phase 1 test failing after the
  class swap (good regression-catching in its own right). Fixed via
  `editor.unregisterPlugin('history')` + `editor.registerPlugin(history())` — the public
  API the subclass does track — verified correct by direct code review of the fix's
  reasoning, not just the test passing.
  - happy-dom has no real layout engine, so simulated clicks can't hit-test to a text
  position; table-toolbar tests use `editor.commands.setTextSelection()` directly
  instead, documented as the "headless-safe equivalent."
- [x] Removed the now-superseded Phase 0 dev-only spike (`wysiwyg-spike.html`/
  ```
  `wysiwygSpikeMain.ts`) since `WysiwygEditor.vue` is the real thing now.
  ```

## Phase 3 — macOS integration (`macos/Markdown/Markdown/`)

**Status: DONE except one flagged gap.** Same worktree/branch, commit `3475499`.
Independently re-verified with a **real, from-scratch `xcodebuild` run** (not taken on the
agent's report alone) — `xcodebuild -project macos/Markdown/Markdown.xcodeproj -scheme Markdown -configuration Debug build` → `** BUILD SUCCEEDED **`, real code-signing, real
link against `libmarkdown_core.a` — plus direct code review of both Swift diffs and the
two small Vue-side bridge additions, plus `bun run test` re-confirmed at 26/26 (unaffected
by the Swift-side changes).

*Note on IDE diagnostics*: SourceKit briefly showed a wall of "cannot find X in scope"
errors on these files (including for types this phase never touched, like `Workspace`/
`Account`/`WebPreferences`) — that's stale/false-positive, not a real problem: this
worktree had no DerivedData/build cache until the `xcodebuild` run above populated one.
Confirmed by the real build succeeding cleanly with zero warnings or errors.

- [x] `MarkdownWebView.swift`: `onDocumentEdit: (String) -> Void` threaded through
  ```
  `makeCoordinator`/`updateNSView`/`updateUIView`/`WebPreviewCoordinator`'s init; new
  `"documentEdit"` case sets `text = newText` **before** calling `onDocumentEdit` (this
  ordering, protected by an explicit "do not reorder these two lines" comment in the
  code, is the entire echo-suppression mechanism — it's what makes the existing
  `setDocumentText`'s `guard newText != text` no-op correctly).
  ```
- [x] `ContentView.swift`: toolbar relabeled "Edit"→"Source" (label, icon, `.help()` text),
  ```
  `TextEditor` kept unchanged behind the same toggle; `onDocumentEdit: { workspace.text
  = $0 }` wired into the one `MarkdownWebView(...)` call site.
  ```
- [x] **New, beyond the plan's original scope**: built the reverse (native→JS) flush
  ```
  primitive needed for the next item — `flushPendingEdit() async -> String?` on
  `WebPreviewCoordinator` (via `callAsyncJavaScript`), plus
  `MarkdownHost.flushPendingEdit?(): Promise<string>` on the Vue side, installed
  single-owner (assign/restore, not the multi-subscriber chain `setDocument` uses)
  by `useWysiwygDocument`.
  ```
- [x] **`flushPendingEdit()` wiring gap — closed** (2026-08-25, commit `89c7e44`, same
  ```
  worktree/branch). Independently re-verified with a **real `xcodebuild clean build`**
  (not just incremental — confirmed zero Swift warnings/errors, only benign toolchain
  notes) plus direct review of all five changed files.
  `Workspace.selectedFile` is now `private(set)` (a property observer can't `await`);
  `open(folder:)`/`open(file:)`/`open(dropped:)`/`close()`/`save()` are all `async` and
  route through a new private `flushPendingSaveAsync(to:)`, which awaits
  `flushEditorPendingEdit` (a plain closure `Workspace` holds, `nil`-tolerant, set by
  `MarkdownWebView`'s new `registerFlushPendingEdit` once the coordinator exists —
  matching `Workspace`'s existing style of taking the vault/watcher as closures rather
  than concrete UI types) and folds a fresher result into `text` before the existing
  synchronous disk-write logic runs. A new `selectFile(_:)` gives synchronous callers
  (SwiftUI `Binding`s) an entry point that does the async work internally.
  **Every** call site in the app was found and updated, not just the ones Phase 3
  flagged: both `SidebarView.swift` `List(selection:)` bindings (folder tree and
  search results) via a new `selectedFileBinding` computed property, its drop handler,
  `ContentView.swift`'s two `.fileImporter` closures + drop handler + `.onOpenURL`, and
  `MarkdownApp.swift`'s File-menu "Close Folder/File" command — each wrapped in
  `Task { @MainActor in await ... }` where the call site is synchronous.
  **A real bug the compiler caught, not manual review**: the first
  `flushPendingEdit()` implementation used `try await webView.callAsyncJavaScript(...)`
  expecting a return value — it compiled, but silently resolved to a different,
  `Void`-returning SDK overload (this SDK's `callAsyncJavaScript` only has a
  completion-handler form), so the flush would always have returned `nil` at runtime
  despite looking correct. The build's own warnings caught it
  (`result` inferred as `()`, "cast from `()` to `String` always fails"); fixed by
  bridging the completion-handler form through `withCheckedContinuation`, matching
  `pushDocument()`/`pushPreferences()`'s established pattern. Second consecutive
  Phase-3-family bug a real compile caught that Swift-syntax-level review alone would
  have missed — reinforces that the `xcodebuild` verification step (not just reading
  the diff) is load-bearing for this platform, not a formality.
  ```
- [ ] Manual test matrix — **honest status, not all run against a real vault**:
  - Type → autosave → git commit, no cursor jump: **code-inspection + build-verified
  only**, not run. Full chain traced (`documentEdit` → `text=newText` →
  `onDocumentEdit` → `workspace.text` → existing 800ms autosave → `VaultStore.write` →
  git commit) and the echo-suppression ordering confirmed correct by reading the code.
  - External edit mid-typing → conflict banner: **not run**. `absorbExternalChanges` is
  untouched this phase; reasoned (not tested) to still work identically since
  `hasUnsavedChanges` flips the same way regardless of which UI surface set
  `workspace.text`.
  - Chat-agent revert + undo interaction: **partially test-verified**. The Vue-side half
  (`applyExternalText`/`resetHistory`) is real-test-verified from Phase 2; the
  native→Vue handoff itself (`setDocumentText`→`pushDocument`→Vue) is
  code-inspection-only, not run end-to-end.
  - Fast file-switch, no lost keystrokes: **wiring gap now closed** (see above,
  commit `89c7e44`) — build-verified, but still **not run against a real vault**.
  - **All four items need a human with Xcode running the real app against a real vault to
  close out** — flagged here rather than claimed done.

**Real bug from actual human testing (2026-08-25), fixed** — the first bug this whole
effort caught by someone other than an agent or me: the user built and ran the app, clicked
the toolbar toggle (relabeled "Source" in this phase, still bound to Cmd+E), and reported
"still shows old source editor." Root cause: `vue-project/src/App.vue`'s Phase 2
`mode: 'reading' | 'edit'` ref defaulted to `'reading'`, so opening a file landed in the
read-only Reading view, with the actual new WYSIWYG editor reachable only via a small
in-content toggle — easy to miss, and exactly backwards for an app whose whole point is
live-preview editing. Fixed (commit `b982906`, same worktree/branch) by defaulting `mode`
to `'edit'`; Reading view is now the opt-in mode, not the entry point. Re-verified: 26/26
tests, type-check clean, and a full `xcodebuild build` with the rebuilt Vue bundle embedded
— `** BUILD SUCCEEDED **`, zero warnings.

**Follow-up report ("doesn't work, not editing"), root-caused as a testing-location issue,
not a code bug**: checked Xcode's DerivedData and found the user had most recently built
`/Volumes/T7/Projects/markdown/macos/Markdown/Markdown.xcodeproj` — the **main working
tree**, not the worktree branch this entire feature lived on. Confirmed directly: main's
`ContentView.swift` still had the toolbar labeled `"Edit"` (pre-Phase-3) and
`vue-project/src/editor/` didn't exist there at all — so every prior test session had been
against the old, unmodified app, which fully explains both this report and the "still
shows old source editor" one before it. Resolved by merging Phases 0-3 into `main` (see
top-of-file status) rather than continuing to develop on an isolated branch the user's
normal workflow never saw.

**Real pre-existing bug, found via this feature and fixed directly on `main`** (commit
`3b5f046`): "bold text doesn't work" — `vue-project/src/assets/base.css` has a global
`*, *::before, *::after { font-weight: normal; }` reset that silently neutralized the
browser's default bold weight for `<strong>`/`<b>` (and headings, masked there by large
font-size). This predates this whole feature and affected the original Reading view too,
not just the new editor — the underlying `Bold` mark/HTML was always applied correctly;
it was a pure CSS gap. Fixed with explicit `font-weight` overrides in both
`MarkdownPreview.vue` and `WysiwygEditor.vue`. Re-verified: 26/26 tests, type-check, real
`xcodebuild build` — clean.

## Phase 4 — Windows integration (`win/MarkdownWin/MarkdownWin/`)

**Status: DONE except manual verification.** Built directly on `main` (no worktree,
following Phase 6/7's precedent — the worktree round trip is what caused Phase 3's earlier
testing-location confusion). Not yet committed — see the note at the end of this section.
No Vue changes were needed; only already-existing bridge methods (`documentEdit`,
`flushPendingEdit`, `runEditorCommand`, `editorStateChanged`) were consumed, exactly as
scoped.

Verification approach, and why it goes beyond what Phase 3/6/7 could do on macOS: this
session runs directly on the Windows machine that builds this project, so — unlike every
prior phase, which could only build and had no way to check API surface beyond memory/docs
— every WinUI API assumption below (`Symbol` enum member names, `AppBarToggleButton.Click`
existing and not looping back from programmatic `IsChecked` changes, `FlyoutBase.Opening`'s
exact delegate signature, `CommandBarLabelPosition` only having `Default`/`Collapsed`, no
`Right`) was checked against the **actual compiled `Microsoft.WinUI.dll`** from a prior
build, loaded via `System.Reflection.MetadataLoadContext` in a throwaway scratch console
app (real reflection over the real assembly, not guessed from memory) — then the whole
project was built for real: `dotnet build MarkdownWin.slnx -c Debug -p:Platform=x64`, both
an incremental build and a `-t:Rebuild`, both clean (`0 Error(s)`, the only warning being
the pre-existing, expected "reusing existing vue-project/dist" Rust build-script notice
every Windows build produces). Only x64 Debug was built, not x86/ARM64 — the change is pure
C#/XAML with no P/Invoke or platform-conditional code, so cross-platform risk is low, but
this wasn't independently confirmed the way x64 was.

### 4a — Core edit bridge (mirrors Phase 3's macOS work)

- [x] `MarkdownWebView.xaml.cs`: `event EventHandler<string>? DocumentEdited` added; new
  ```
  `"documentEdit"` case in `OnWebMessageReceived` sets `text = newText` **before**
  invoking the event — same echo-suppression ordering as macOS, with an equivalent
  "do not reorder these two lines" comment. `"editorStateChanged"` case added in the
  same pass (see 4b).
  ```
- [x] Reverse (native→JS) flush primitive: `Task<string?> FlushPendingEditAsync()`.
  ```
  **Deviation from the plan's literal instruction to "mirror `PushDocumentAsync`
  exactly"**: `PushDocumentAsync`'s retry-until-mounted polling loop doesn't apply here
  (there's nothing to retry — a flush before the editor has mounted has nothing to
  flush) and isn't the relevant pattern for a value-returning call anyway. Instead, this
  uses `CoreWebView2.ExecuteScriptAsync`'s documented behavior of awaiting a returned JS
  `Promise` itself and JSON-encoding its resolved value — so wrapping the JS in an async
  IIFE and awaiting the one call is sufficient; there is no second, wrong-overload trap
  to fall into here the way macOS's `callAsyncJavaScript` had only a completion-handler
  form — .NET's `ExecuteScriptAsync` has exactly one signature, already `Task<string>`.
  Confirmed by an actual clean build catching zero warnings on this method.
  ```
- [x] `MainWindow.xaml`/`.xaml.cs`: `EditorOverlay` kept unchanged; `EditToggle` relabeled
  ```
  "Source" (icon left as `Edit` — the plan only asked for a label change).
  `Preview.DocumentEdited += (_, newText) => workspace.Text = newText;` wired in the
  constructor. `OnEditorTextChanged`/`isUpdatingEditor` untouched, as directed.
  ```
- [x] `Workspace.FlushEditorPendingEdit` (a `Func<Task<string?>>?`, mirroring
  ```
  `Workspace.swift`'s `flushEditorPendingEdit`) added and awaited inside
  `FlushPendingSaveAsync` — **one call site, not several**: unlike macOS, Windows'
  `Workspace.cs` already funneled every flush point (`OpenAsync`, `CloseFolderAsync`,
  `SelectFileAsync`, `SaveAsync`) through this single private method before this phase
  started, and Windows has no single-file-open or drag-drop feature yet (confirmed by
  grep — no `OnOpenFileClick`/`FileOpenPicker`/drop handler exists anywhere in the
  project), so there was no macOS-style hunt for five separate call sites to find.
  Ordering matters here the same way it did on macOS: the flush (which may reassign
  `Text`, rescheduling autosave via its setter) now runs *before* the
  `autosaveCts?.Cancel()` line, not after — documented inline with the same reasoning
  as `Workspace.swift`'s `flushPendingSaveAsync(to:)`/`flushPendingSave(to:)` ordering.
  `MainWindow.xaml.cs` wires `workspace.FlushEditorPendingEdit = () =>
  Preview.FlushPendingEditAsync();` in the constructor.
  ```

### 4b — Native formatting toolbar (ports Phase 6, macOS-only until now)

- [x] `EditorToolbarState.cs` (new): `EditorMode`/`EditorMark`/`EditorBlock` enums, a
  ```
  `readonly record struct EditorToolbarState` with an `Initial` static default and a
  `TryParse(JsonObject)` factory tolerant of unknown mark/block strings (dropped, not
  fatal) — mirrors `EditorToolbarState.swift` field-for-field, using
  `System.Text.Json.Nodes` (this codebase's established convention — see
  `WebPreferences`'s `ToPayload()`/`FromRaw()` pattern in `AppSettings.cs`) rather than
  Swift's manual `[String: Any]` decoding.
  ```
- [x] `MarkdownWebView.xaml.cs`: `event EventHandler<EditorToolbarState>? EditorStateChanged`
  ```
  raised from the `"editorStateChanged"` case; `Task<bool> RunEditorCommandAsync(string
  command, JsonObject? payload = null)` using the same `ExecuteScriptAsync`-awaits-a-
  promise mechanism as `FlushPendingEditAsync`.
  ```
- [x] XAML toolbar spliced into `MainWindow.xaml`'s existing `CommandBar`, before the
  ```
  (relabeled) Source toggle: a mode toggle (Reading View/Edit, dynamic icon+label+
  tooltip), Bold/Italic/Strikethrough/inline-Code mark toggles, a heading-level
  `MenuFlyout` (Paragraph, H1-H6), Blockquote/Bullet-list/Ordered-list/Task-list/
  Code-block toggles, a horizontal-rule insert, and Link/Image/Footnote insert buttons
  each with a `Flyout` containing a `TextBox` + Apply/Insert button (Enter key submits
  too) — the WinUI analogue of macOS's `.popover`. No Underline button (matches macOS's
  Phase 6 rationale — not CommonMark/GFM). No Undo/Redo buttons — same as macOS,
  deferred pending human verification that WebView2's contenteditable undo already works
  via Ctrl+Z with focus in the web view; nothing wired speculatively.
  Table row/column controls were **not** duplicated here — `TableControls.vue` stays
  the only place for them, as directed.
  Every mark/block/heading/rule/insert control is disabled when
  `!toolbarState.IsEditable || EditToggle.IsChecked == true` (the Source-view check),
  recomputed both on every `EditorStateChanged` event and on every Source-toggle flip
  (`OnEditToggleChanged` now re-applies the cached toolbar state for its
  enabled/disabled side effect — the mark/block *active* state itself only ever changes
  via `EditorStateChanged`).
  **A real design deviation, caught and resolved before it became a bug, not found by
  the build**: `AppBarToggleButton`'s `Checked`/`Unchecked` events (the ones
  `EditToggle` already used) fire on *any* `IsChecked` change, including the
  programmatic ones `ApplyToolbarState` makes to reflect state pushed from the web
  view — wiring those would have created a feedback loop back into
  `RunEditorCommandAsync`. Used `Click` instead (confirmed via the same
  `MetadataLoadContext` reflection check to be inherited from `ButtonBase`, and to fire
  only on real user interaction, not on programmatic `IsChecked` assignment) for every
  mark/block/mode toggle button; `ApplyToolbarState` sets `IsChecked` directly with no
  guard flag needed as a result.
  **Icon accuracy is best-effort and visually unverified**, same caveat as macOS's SF
  Symbol choices: `Icon="Bold"/"Italic"/"Link"/"Pictures"/"Bullets"/"List"` were
  confirmed to be real `Symbol` enum members (see the verification note above) so
  they're guaranteed to compile and show *something*, but several buttons
  (Strikethrough, inline Code, heading, Blockquote, Task List, Code Block, Horizontal
  Rule, Footnote) use hand-picked `FontIcon` glyph codepoints that could not be
  confirmed to compile-fail if wrong (glyph strings are untyped) and were not visually
  checked — worth a look once someone can actually run the app.
  ```

### 4d — Open File and drag-and-drop (added post-hoc, outside the plan's original Phase 4 scope)

**Status: DONE.** Requested directly by the user after trying Phase 4 ("open folder/files
doesn't work. also implement drag/drop") — Windows never had single-file open or
drag-and-drop at all (only "Open Folder…" existed; macOS has had both since before this
plan started, via `Workspace.swift`'s `open(file:)`/`open(dropped:)`), so this folds Windows
up to parity rather than fixing a regression in Phase 4's own work.

- **Likely root cause of "doesn't work", found by code review**: `OnOpenFolderClick` invoked
`OpenFolderAsync()` as a discarded, fire-and-forget `Task` (`_ = OpenFolderAsync();`), and
the picker call itself — `await picker.PickSingleFolderAsync()` — sat **outside** the
method's only try/catch, which wrapped just `workspace.OpenAsync(...)`. If the picker call
throws for any reason (a real possibility for `FolderPicker`/`FileOpenPicker` in a WinUI3
desktop app — window-handle/COM activation issues are a well-documented failure mode for
these pickers), that exception becomes an unobserved fault on a discarded `Task` — in
modern .NET this does **not** crash the process, it is simply swallowed, with nothing
visible to the user. That failure mode matches "click Open Folder, nothing happens" more
precisely than any bug found in the folder-tree-population code itself (which was read
end-to-end — `Workspace.OpenAsync`, `FileNode.LoadChildren`/`Contents`,
`SidebarView.RenderState`/`RenderFileTree` — and shows no defect). **Fixed** by moving the
entire picker-and-open sequence inside one try/catch in both `OpenFolderAsync` and the new
`OpenFileAsync`, so any failure now reaches `Workspace.ReportOpenFailure` and shows in the
sidebar's existing error banner instead of vanishing. **Honestly caveated**: this could not
be confirmed against the user's exact failure — see the verification note below — so if
the sidebar now shows a real error message on click, that error text is the next lead.
- **`Workspace.OpenFileAsync(string path)`** (new): mirrors `Workspace.swift`'s
`open(file:)` — opens a single file with no folder/vault context, or just selects it if it
already lives inside the currently-open folder. **A real correctness gap this closes,
found while porting**: `FlushPendingSaveAsync` only ever wrote through `VaultStore`
(`RelativePath(url) is not { } relative` short-circuited the whole write for any URL
outside an open folder) — a single file opened with no folder would have silently never
saved at all, autosave included, since `HasUnsavedChanges` would flip back and forth but
the write branch could never run. Fixed with the same direct-disk-write fallback
`Workspace.swift`'s `flushPendingSave(to:)` already has for this exact case.
- **`Workspace.OpenDroppedAsync(string path)`** (new) + **`UnsupportedDropException`**:
mirrors `open(dropped:)`/`UnsupportedDropError` — routes a directory to `OpenAsync`, a
recognised Markdown extension (`MarkdownFile.Matches`, now also exposed as
`PickerExtensions` for the file picker's filter) to `OpenFileAsync`, anything else to
`ReportOpenFailure` rather than silently doing nothing.
- **XAML/`MainWindow.xaml.cs`**: an "Open File…" `AppBarButton` (Ctrl+O, matching macOS's
Cmd+O — "Open Folder…" already used Ctrl+Shift+O, matching macOS's Cmd+Shift+O) added
before "Open Folder…". Drag-and-drop wired on the outermost `Grid` (`AllowDrop`,
`DragOver`/`DragLeave`/`Drop`), so a drop lands the same way regardless of which part of
the window it's over — mirrors `ContentView.swift`'s window-wide `.onDrop`. A
`DropHighlight` border (`IsHitTestVisible="False"` so it can't itself intercept the drag)
shows/hides on `DragOver`/`DragLeave`/`Drop`, mirroring `ContentView.swift`'s
`isDropTargeted` overlay. `DragEventArgs.GetDeferral()`/`.Complete()` used around the
`async` `Drop` handler, since `IStorageItem`s are only available via
`DataView.GetStorageItemsAsync()`, an async WinRT call the synchronous event needs a
deferral to await past. Only the first dropped item is opened (matches
`ContentView.swift`'s `providers.first`).
- **Verification**: `dotnet build`/`-t:Rebuild` clean (0 errors) after every change above,
same as 4a/4b. `DragEventArgs`/`UIElement` drag-and-drop members
(`AllowDrop`/`DragOver`/`Drop`/`AcceptedOperation`/`DataView`/`GetDeferral`) were confirmed
against the real compiled `Microsoft.WinUI.dll` the same reflection way as 4a/4b's API
checks; `DataPackageView.GetStorageItemsAsync`/`StandardDataFormats.StorageItems` are
system `Windows.ApplicationModel.DataTransfer` types outside that assembly and were
**not** independently re-verified this way — trusted as long-stable, unchanged-since-UWP
API. **A real interactive launch was attempted and did not succeed**, but for a reason
unrelated to this app's code: a `dotnet publish` (self-contained, unpackaged — this
project has no MSIX signing certificate checked in, so a properly packaged/signed launch
wasn't attempted) crashed at process startup, before any app code runs, with
`COMException 0x80040154 (REGDB_E_CLASSNOTREG)` inside the Windows App SDK's own
`DeploymentManager` auto-initializer — a known unpackaged-deployment requirement (the
Windows App SDK **runtime redistributable**'s COM registration, distinct from the AppX
framework packages already present on this machine) that installing
`Microsoft.WindowsAppRuntime.1.7`/`.2` via `winget` did not resolve. Since this crash
happens in SDK bootstrap code before `App`/`MainWindow` construction, it is provably
unrelated to anything in this diff — but it does mean **none of Phase 4's work (4a/4b/4d)
has been run interactively by anyone yet, this session included**. Needs the user to
rebuild via Visual Studio (the packaged/deployed path this app is actually designed for)
and confirm both the original bug and the new features.

### 4c — Testing

- [x] Build clean: `dotnet build MarkdownWin.slnx -c Debug -p:Platform=x64`, both a plain
  ```
  build and a `-t:Rebuild`, both `Build succeeded`, `0 Error(s)`, only the pre-existing
  benign Rust-reuse warning. x86/ARM64 not independently built (see the note above).
  ```
- [ ] Manual test matrix — \*\*honest status, not run, same limitation as every prior
  ```
  phase**: this environment has no way to interactively launch/click through a WinUI
  app (packaged-app activation, WebView2 runtime interaction, and a real vault are all
  needed). None of type→autosave→commit-no-cursor-jump, external-edit-mid-typing
  conflict banner, chat-agent revert+undo interaction, fast file-switch-loses-no-
  keystrokes, or the toolbar-specific checks (buttons reflect selection state, flyouts
  commit values on both button-click and Enter, mode toggle switches correctly) have
  been run against a real vault. Everything above is build-verified and
  reflection-verified against the real compiled WinUI assembly, not code-inspection
  alone — a meaningfully stronger bar than Phase 3/6/7 could reach on macOS, where no
  equivalent introspection was available — but still not the same as a human actually
  running the app. **Needs a human with the app running against a real vault to close
  out**, flagged here rather than claimed done. Not yet committed to `main`, pending
  that verification (or the user's go-ahead to commit anyway, following Phase 3's
  pattern of merging before full manual verification once code review + build were
  solid).
  ```

## Phase 5 — Polish

- [ ] "Paste as markdown source" nicety for plain-text markdown clipboard content.
- [ ] Table controls UI refinement (hover affordances, keyboard access).
- [ ] Footnote UX (insert/jump-to-definition affordance).
- [ ] Re-confirm paste-sanitization gaps from Phase 2 are actually closed, not just
  ```
  verified in isolation.
  ```
- [ ] Revisit image resize handles (v2 stretch goal) and local-asset import (paste image →
  ```
  vault file — needs a new `markdown_vault` tool; out of scope until explicitly
  requested).
  ```

## Phase 6 — Native SwiftUI formatting toolbar (macOS)

**Status: DONE.** Built directly on `main` (no worktree this time — the worktree round
trip is what caused the earlier "doesn't work"/testing-location confusion, so this phase
was built and verified where the user actually opens the project), across two commits:
`1b0f211` (Vue-side bridge + composable) and `5a74ae9` (Swift-side toolbar). Verified with
`bun run test` (48/48, 22 new), `bun run type-check` (clean), and **two** real
`xcodebuild` runs — an incremental build and a full `clean build` — both
`** BUILD SUCCEEDED **` with zero real warnings (only the two benign toolchain notes every
prior build has also shown: destination-selection and AppIntents-metadata-skip).

### Decisions locked in (confirmed with user, 2026-08-25)

- **Underline is skipped entirely** — not added to the schema or toolbar. Tiptap's own
`Underline` extension serializes it as `++text++`, which isn't CommonMark/GFM; Rust's
`render_markdown` (pulldown-cmark) has no such extension enabled and would show the
literal `++` characters in Reading view — a real, visible editor/Reading-view mismatch,
and non-portable to any other markdown tool (GitHub included). Not worth it for a mark
this redundant with bold/italic/strikethrough. (Confirms and closes the review the
original `underline: false` schema comment from Phase 0 was flagging.)
- **The Reading/Edit mode toggle moves from its current in-content Vue button into the
native toolbar**, consolidated alongside the existing "Source" toggle and the new
formatting buttons — one coherent native toolbar instead of two separate UIs.

### Toolbar surface

- **Marks**: Bold, Italic, Strikethrough, inline Code.
- **Blocks**: heading level (Paragraph, H1-H6) via a `Menu`; Blockquote, Bullet list,
Ordered list, Task list, Code block — each a toggle button; Horizontal rule (insert-only).
- **Link**: add/edit/remove via a small popover with a URL `TextField`.
- **Image**: URL-based insert via a popover (not local-file insert — no vault-relative
asset storage path exists yet, per Phase 2's paste-safety research; local-file insert
stays out of scope until that gap is addressed, same as Phase 5's existing note on this).
- **Footnote**: insert via a popover for the label, same shape as link/image.
- **Table row/column controls stay as the existing in-content `TableControls.vue`** —
contextual/spatial to being inside a table, doesn't belong in a global toolbar.
- **Undo/redo**: verify first whether Cmd+Z/Cmd+Shift+Z already work correctly via the
WebView's own focus (WKWebView's contenteditable undo is DOM-native, so this may already
just work with no custom wiring) before adding toolbar buttons/commands for it — don't
build what might not be needed. **Deferred, not built**: this environment has no way to
interactively drive the GUI to verify it, and the plan explicitly said not to build
speculatively — no `undo`/`redo` commands or buttons exist yet.
`EditorToolbarState.canUndo`/`canRedo` are still computed and decoded on both sides
(harmless, forward-compatible), just not wired to anything yet. **Needs a human to
verify Cmd+Z with the WebView focused before this is picked back up.**
- No Rust changes needed for this phase — dropping underline removes the one thing that
would have required checking/extending `render.rs`'s ammonia sanitizer allowlist.
Confirmed true: this phase touched no Rust file.

### Bridge protocol additions

- [x] **Native → JS command dispatch**: `runEditorCommand(command, payload?)` installed by
  ```
  `useWysiwygDocument` (single-owner assign/restore on `window.__markdownHost`, same
  pattern as `flushPendingEdit`). The lookup table itself lives in a new, separately
  testable module, `vue-project/src/editor/formatCommands.ts`
  (`runFormatCommand(editor, command, payload, onSetMode)`), covering every command
  the plan named: `toggleBold/Italic/Strike/Code`, `setHeading`, `toggleBlockquote/
  BulletList/OrderedList/TaskList/CodeBlock`, `setHorizontalRule`, `toggleLink`,
  `setImage`, `insertFootnote`, `setMode`. `undo`/`redo` intentionally **not** added
  (see the Undo/redo bullet above). Synchronous, matching Tiptap's own
  `chain().run()` — no `Promise` wrapper needed on either side.
  **Deviation**: `insertFootnote` needed real logic, not just a chain call — the
  footnote extension defines two node types but no insertion command of its own (an
  atom reference plus a possibly-new block definition isn't a single-node concern).
  Implemented as one atomic chained transaction: insert the reference, and only if no
  `footnoteDefinition` with that label already exists in the doc, append an empty one
  at the end — verified by a test that a *second* reference to the same label doesn't
  duplicate the definition.
  ```
- [x] **JS → native state reporting**: `EditorToolbarState` (exact shape as planned) lives
  ```
  in `nativeBridge.ts` as the canonical type; `reportEditorState()` sends
  `{method: 'editorStateChanged', state}`. Computed by a new
  `vue-project/src/composables/useEditorToolbarState.ts`.
  **Deviation from "compute both together, don't add a second raw listener"**: this
  composable installs its **own** `editor.on('transaction', ...)` listener rather than
  sharing `useEditorOutline`'s, to keep both composables independently usable/testable
  without coupling them or touching `useEditorOutline`'s already-shipped, already-
  tested code. A second Tiptap transaction listener is a cheap, well-supported
  pattern (this is exactly what `useEditorOutline` itself already does for its own
  concern) — what actually matters (not sending a bridge message per keystroke) is
  handled where it belongs: `WysiwygEditor.vue` dedupes via a `JSON.stringify`
  comparison before calling `reportEditorState`, not by sharing the listener.
  ```
- [x] **Mode ownership stays with Vue**: confirmed working exactly as planned — native's
  ```
  toolbar toggle calls `runEditorCommand('setMode', {mode})`, `useWysiwygDocument`'s
  new `onSetMode` option routes it back up through `WysiwygEditor.vue`'s `setMode`
  emit into `App.vue`'s unchanged `mode` ref. The in-content mode-toggle button (and
  its now-dead `.mode-toolbar`/`.mode-toggle` CSS) is removed from `App.vue`.
  ```

### Native SwiftUI (`macos/Markdown/Markdown/`)

- [x] `EditorToolbarState.swift`: a plain `Equatable` struct (not `Codable` — this
  ```
  codebase's bridge structs, e.g. `WebPreferences`, decode/encode via manual
  `[String: Any]` field access rather than `JSONDecoder`, so this matches that
  existing convention rather than introducing a new one) with a `body: [String: Any]`
  failable initializer, tolerant of unknown mark/block strings (dropped, not fatal —
  mirrors `normalizePreferences`'s cross-version tolerance in the other direction).
  ```
- [x] `MarkdownWebView.swift`: `onEditorStateChange` threaded through exactly as planned;
  ```
  `runEditorCommand(_:payload:)` copies `flushPendingEdit`'s established
  `callAsyncJavaScript` + `withCheckedContinuation` bridging correctly on the first
  attempt this time (no repeat of that earlier SDK-overload mistake). New
  `"editorStateChanged"` case in `WKScriptMessageHandlerWithReply`.
  ```
- [x] `ContentView.swift`: new `@State` for `toolbarState` and a `runEditorCommand`
  ```
  closure, wired into the `MarkdownWebView(...)` call. Formatting toolbar spliced into
  the existing `.toolbar { }` alongside the unchanged Source `ToolbarItem`.
  **Deviation**: `registerRunEditorCommand`'s closure is stored as local `@State` on
  `ContentView` directly, **not** routed through `Workspace` the way
  `flushEditorPendingEdit` is — `Workspace` never needs to call it (only the toolbar
  does), so threading it through `Workspace` the way the plan's prose implied would
  have added a dependency `Workspace` has no actual use for. `onEditorStateChange`
  likewise sets local `@State` directly.
  ```
- [x] **Real bug the build caught, not review**: a flat `body` listing all \~16
  ```
  `ToolbarItem`s failed to compile ("extra arguments" pointing at items past #10) —
  `@ToolbarContentBuilder`'s `buildBlock`, like `@ViewBuilder`'s, only has overloads up
  to 10 children. Fixed by splitting into four `@ToolbarContentBuilder`-annotated
  sub-properties (`modeSection`, `markSection`, `blockSection`, `insertSection`) that
  `body` composes together (well under the limit). Confirmed `@State` popover-trigger
  properties work correctly on a `ToolbarContent`-conforming struct (not just `View`)
  once this was fixed — a real, non-obvious SwiftUI mechanics question this phase
  settled by testing rather than assuming.
  Actual toolbar surface delivered exactly as planned: relocated mode toggle,
  Bold/Italic/Strike/Code (SF Symbols `bold`/`italic`/`strikethrough`/
  `chevron.left.forwardslash.chevron.right`, tinted when active), a heading `Menu`
  (Paragraph + H1-H6), Blockquote/Bullet/Ordered/Task-list/Code-block toggles
  (`text.quote`/`list.bullet`/`list.number`/`checklist`/`terminal`), a horizontal-rule
  insert (`minus`), and Link/Image/Footnote buttons each with a `.popover` text field
  (`link`/`photo`/`textformat.superscript`). Every formatting item is
  `.disabled(!toolbarState.isEditable || isEditing)`, matching the plan exactly.
  ```

### Testing

- [x] Vue-side: `formatCommands.spec.ts` (14 tests) and `useEditorToolbarState.spec.ts`
  ```
  (8 tests), both against real `Editor` instances via `useWysiwygDocument` (not
  mocks) — including a test that specifically catches the "closed over a plain
  variable instead of a real reactive `ref`" mistake that was caught and fixed
  *while writing this phase's own tests*, before it ever reached the app.
  **48/48 tests total, `vue-tsc --build` clean.**
  ```
- [x] Swift-side: two full `xcodebuild` runs (an incremental build and a `clean build`),
  ```
  both `** BUILD SUCCEEDED **`, output grepped for `warning:|error:` and confirmed
  only the two benign toolchain notes every prior phase's build has also shown.
  **Manual UI verification (buttons toggle correctly, popovers commit their values,
  toolbar disables appropriately) was NOT done — no way to drive the GUI
  interactively from this environment. Needs a human to actually click through it.**
  ```

## Phase 7 — Copy-to-clipboard button on code blocks

**Status: DONE.** Built directly on `main` (no worktree), across two commits: `8866cb2`
(WYSIWYG editor NodeView + shared utilities) and `8cd05c3` (Reading view stamping). Real
verification: `bun run test` → **53/53** (5 new tests), `bun run type-check` clean, a real
`xcodebuild build` (`** BUILD SUCCEEDED **`, log grepped for `warning:|error:` — only the
two benign toolchain notes every prior phase has also shown), and a production
`bun run build-only` (`dist/` 733.98 kB → 748.96 kB raw, \~15 kB for the whole feature, no
new npm dependency pulled in).

- [x] **Design**: hover-revealed button, top-right corner, inline SVG copy/check glyphs
  ```
  shared between both surfaces via `vue-project/src/utils/copyIcons.ts` — one visual
  source of truth instead of duplicating the glyph markup.
  ```
- [x] **WYSIWYG editor**: `CodeBlockWithFenceLength` now has a real NodeView
  ```
  (`addNodeView()` → `VueNodeViewRenderer(CodeBlockView)`,
  `vue-project/src/editor/CodeBlockView.vue`) — `NodeViewWrapper as="pre"` +
  `NodeViewContent as="code"`, both confirmed exported by the installed
  `@tiptap/vue-3`. Button's `mousedown` handler calls `preventDefault()`/
  `stopPropagation()` so clicking it can't move the ProseMirror cursor or steal focus.
  ```
- [x] **Verified, not assumed**: wrapping the code block in a custom NodeView does **not**
  ```
  break `CodeBlockLowlight`'s decoration-based syntax highlighting — the pre-existing
  Phase 2 test asserting `.hljs-*` spans render still passes unchanged after this
  change, and a new dedicated test confirms the button itself copies the right text
  and shows a "Copied" state.
  ```
- [x] **Reading view**: `MarkdownPreview.vue` stamps a real `<button>` onto every
  ```
  `.markdown-body pre` via `watch(() => props.html, ..., { immediate: true, flush:
  'post' })`, same imperative-DOM style `useDocumentOutline.ts` uses for heading ids.
  `position: relative` added to `.markdown-body :deep(pre)`. Confirmed via test that
  re-renders don't leak stale buttons (`v-html` replacing the whole innerHTML on each
  change already guarantees this, but verified rather than assumed).
  ```
- [x] **Clipboard mechanism**: shared `vue-project/src/utils/copyToClipboard.ts` — tries
  ```
  `navigator.clipboard.writeText` first, falls back to a temporary offscreen
  `<textarea>` + `document.execCommand('copy')` if it rejects. **Could not verify
  inside the real embedded `markdown-app://` WKWebView from this environment** (same
  limitation as every prior phase's "needs a human" manual-test items) — implemented
  the fallback chain defensively either way rather than guessing, and added a test
  confirming the fallback actually engages when the Clipboard API rejects. No native
  bridge fallback was built — per the plan's own instruction, that stays speculative
  infrastructure unless real-world testing shows the JS-level fallback isn't enough.
  ```
- [x] **Tests**: `WysiwygEditor.spec.ts` gained 2 tests (Clipboard API path, execCommand
  ```
  fallback path); new `vue-project/src/components/__tests__/MarkdownPreview.spec.ts`
  (3 tests: button stamped, correct text copied, no leaked buttons across re-renders).
  ```
- [ ] **Manual verification** (does clicking the button actually put real text on the
  ```
  system clipboard when run in the real app) — needs a human, same limitation as
  Phase 6's toolbar. Not claimed done.
  ```

## Cross-cutting testing checklist

- [ ] `cd rust && cargo test` passes with new golden-fixture round-trip assertions in
  ```
  `markdown_core` (extend `a_full_featured_document_survives_sanitising`-style test).
  ```
- [ ] `cd vue-project && bun test` (new vitest suite) passes: parse/serialize round-trip +
  ```
  outline slug-parity tests.
  ```
- [ ] Adopt Muya's regression-lock pattern: run fixtures against real CommonMark/GFM spec
  ```
  examples too, with a checked-in `expected-failures.json`-style baseline that can only
  shrink.
  ```
- [ ] Full manual matrix (Phase 3/4 lists above) run on **both** platforms before calling
  ```
  this done.
  ```

## Key files

- `vue-project/src/editor/markdown/footnoteExtension.ts`,
`vue-project/src/editor/markdown/headingIdExtension.ts` (new)
- `vue-project/src/editor/WysiwygEditor.vue` + node view components (new)
- `vue-project/src/composables/slugify.ts` (new, extracted), `useDocumentOutline.ts`
(updated import), `useEditorOutline.ts` (new)
- `vue-project/src/bridge/nativeBridge.ts` (new `documentEdit` method)
- `vue-project/src/App.vue`
- `macos/Markdown/Markdown/MarkdownWebView.swift`, `ContentView.swift`
- `win/MarkdownWin/MarkdownWin/MarkdownWebView.xaml.cs`, `MainWindow.xaml`/`.xaml.cs`
- `rust/markdown_core/src/render.rs` (new round-trip golden-fixture tests)
- `rust/markdown_vault/src/outline.rs` (parity target, referenced by tests)
- `fixtures/markdown-roundtrip/*.md` (new — confirm location before creating)
- Phase 6 additions (all done, commits `1b0f211`/`5a74ae9`):
`vue-project/src/editor/formatCommands.ts` (new), `vue-project/src/composables/ useEditorToolbarState.ts` (new), `vue-project/src/editor/useWysiwygDocument.ts`
(`runEditorCommand` installed), `vue-project/src/App.vue` (in-content mode toggle
removed), `macos/Markdown/Markdown/EditorToolbarState.swift` (new),
`macos/Markdown/Markdown/EditorFormattingToolbar.swift` (new),
`macos/Markdown/Markdown/MarkdownWebView.swift`/`ContentView.swift` (toolbar wiring)
- Phase 4 additions (all done, not yet committed):
`win/MarkdownWin/MarkdownWin/EditorToolbarState.cs` (new),
`win/MarkdownWin/MarkdownWin/MarkdownWebView.xaml.cs` (`DocumentEdited`/
`EditorStateChanged` events, `FlushPendingEditAsync`/`RunEditorCommandAsync`),
`win/MarkdownWin/MarkdownWin/Workspace.cs` (`FlushEditorPendingEdit`, flush-ordering fix
in `FlushPendingSaveAsync`, `OpenFileAsync`/`OpenDroppedAsync`/`UnsupportedDropException`,
direct-disk-write fallback), `win/MarkdownWin/MarkdownWin/FileNode.cs`
(`MarkdownFile.PickerExtensions`), `win/MarkdownWin/MarkdownWin/MainWindow.xaml`/`.xaml.cs`
(native formatting toolbar, Source relabel, toolbar-state wiring, Open File…, drag-and-drop)

## Full rationale

See `.claude/docs/live-preview-editing-research.md` and its linked prior-art docs
(`jotty-editor-research.md`, `marktext-muya-research.md`, `tiptap-research.md`,
`quill-research.md`) for the complete reasoning behind every decision above.