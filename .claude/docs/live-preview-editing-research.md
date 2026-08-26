# Research: live-preview (Typora/Obsidian-style) WYSIWYG markdown editing

**Status: research/design proposal only — not implemented, not yet started.** This
document captures research and a candidate implementation plan for a requested feature; it
describes proposed future work, not current code state (contrast with the other docs in
this directory, which describe verified current behavior). Treat file/line references here
as accurate as of 2026-08-25 and re-verify before relying on them.

## Context

Today `vue-project/` is **preview-only**: the embedded Vue WebView renders sanitized HTML
(`MarkdownPreview.vue`, `v-html`) from markdown text pushed down by native code, and the
*actual* editable text lives in a plain native widget — SwiftUI `TextEditor` on macOS,
WinUI `TextBox` (`EditorOverlay`) on Windows. There is no rich/live editing anywhere.

The goal is Typora-style live-preview editing: markdown renders as a real WYSIWYG document
(styled headings, bold/italic rendered inline, editable table grids, checkbox task items,
images) with no visible `**`/`#`/`|` syntax during normal editing — not the lighter
Obsidian "hide/reveal marks near cursor" style. This was chosen explicitly after weighing
the lighter alternative, understanding it requires a full AST-based document model
(ProseMirror/Tiptap) rather than a plain-text editor with decorations. Both platforms
(macOS + Windows) are in scope together, not macOS-first.

This is a genuine architecture shift: it would move the actual editing surface *into* the
WebView (Tiptap/ProseMirror), demoting the native `TextEditor`/`TextBox` to an optional
raw-source fallback view, and would make the bridge bidirectional in a new way (edits
originating in JS, not just full-document pushes from native). None of this would violate
`CLAUDE.md`'s architectural invariants: vault writes would still go exclusively through
`Workspace.text`/`.Text` → `VaultStore.write` → `markdown_vault::tools::call` (invariants
#1/#2 untouched, no new FFI surface per invariant #3), no Rust→native callback would be
introduced (#4), the sanitized `v-html` Reading-view path stays as-is with no new raw-HTML
rendering path added (#5), agent/loop caps are untouched (#6), the API key path is
untouched (#7). Invariant #8 (outline slug parity) would need active guarding (see below)
but is preserved by construction in this design.

Researched and designed via three research agents (macOS, Windows, Rust core) and two
design agents (editor architecture; bridge + native integration), all of which read the
actual current source rather than guessing.

## Architecture decision

- **Editing surface moves into the WebView.** Tiptap (`@tiptap/core` + `@tiptap/vue-3` +
  `@tiptap/pm` + extensions), not raw hand-rolled ProseMirror — thin MIT wrapper, official
  Vue 3 bindings, maintained extensions for tables/task-lists/images/code-blocks/links.
- **Typora-style true WYSIWYG**, not Obsidian-style decorations. Plain markdown text is
  *not* the live buffer — the ProseMirror doc is, serialized to markdown on save. Some
  reformatting/normalization on save is accepted (Typora itself does this); silent
  structural loss (mangled tables, dropped footnotes) is not acceptable.
- **Both platforms** (macOS + Windows) would get the same shape of native/bridge change.
- **Reading view is kept**, not replaced: `MarkdownPreview.vue` + Rust's sanitized
  `render_markdown` stay as an alternate, toggle-able read-only mode.
- **Native `TextEditor`/`EditorOverlay` are kept, not deleted** — repurposed as a "Source"
  fallback view (raw markdown text, still bound to the same `workspace.text`/`.Text`), not
  the primary editor. Cheap to keep, useful escape hatch, and requires no special-casing
  since it's a real two-way binding to the same state everything else uses.

## Prior art

- [jotty-editor-research.md](jotty-editor-research.md) — deep-dive into
  `github.com/fccview/jotty`, a real shipped Tiptap-based note app. Confirms Tiptap as a
  solid choice and validates the custom-Node/separate-reading-view patterns used here;
  this design's direct `markdown-it` → `prosemirror-markdown` conversion is judged tighter
  than jotty's HTML-mediated (remark/rehype + turndown) approach; jotty has no round-trip
  test coverage (a point in favor of this design's fixture-testing plan) and no footnote
  or `{#id}` heading-anchor support at all.
- [marktext-muya-research.md](marktext-muya-research.md) — deep-dive into MarkText's
  `@muyajs/core` engine, the flagship open-source Typora-style editor, built from scratch
  (not ProseMirror/Tiptap/CodeMirror). Its most important, load-bearing lesson: serialize
  state→markdown with **per-node-type methods directly**, never via a serialize-to-HTML-
  then-turndown detour — Muya proves this is what makes its fidelity far better than
  jotty's HTML-mediated approach. Also worth adopting from Muya: a locked "known-failures
  baseline, only allow it to shrink" conformance-test pattern (see Testing below),
  visual-width-aware table column padding for CJK/wide characters, and a real footnote
  reference implementation (jotty had none). Muya's ~7-year, substantial hand-built
  selection/undo/clipboard/inline-lexer infrastructure also validates *not* building a
  from-scratch engine here — the Tiptap/ProseMirror choice remains the right tradeoff at
  this project's scale.
- [tiptap-research.md](tiptap-research.md) — deep-dive into Tiptap itself, the chosen
  editor library, which turned up a first-party package that **changed this design**:
  `@tiptap/markdown` (MIT, `ueberdosis`-published, not the community `tiptap-markdown`
  package this design originally distrusted) does direct token↔node markdown conversion —
  the same no-HTML-detour approach Muya validated — with per-extension `parseMarkdown`/
  `renderMarkdown` hooks, native GFM table-alignment support, and its own round-trip test
  harness. **This design now adopts `@tiptap/markdown` instead of a hand-written
  `markdown-it`→`prosemirror-markdown` layer** (see Parse/Serialize pipeline below) —
  footnotes and `{#id}` heading anchors remain gaps to fill with two small custom
  extensions, following `@tiptap/markdown`'s own extension pattern.
- [quill-research.md](quill-research.md) — a "why not Quill" check on a genuinely
  different architecture (Delta ops + Blots, not ProseMirror). Verdict: stay with Tiptap.
  Quill's Delta is a flat run-list, not a block-nested tree, so markdown's recursive block
  grammar has to be reconstructed procedurally at every conversion boundary (its own
  table implementation is split into two incompatible systems partly for this reason);
  it has no first-party markdown module at all, only an unmaintained-looking community
  ecosystem; and there's no track record of Quill being used for a markdown-file-backed
  editor. Confirmation, not a course-correction.

## Part 1 — Vue-side WYSIWYG editor (`vue-project/`)

### New dependencies (all MIT/permissive; re-verify licenses and exact versions on install)

`@tiptap/core`, `@tiptap/vue-3`, `@tiptap/pm`, `@tiptap/starter-kit`, `@tiptap/markdown`
(first-party, MIT — see [tiptap-research.md](tiptap-research.md); handles markdown↔doc
conversion directly, no `markdown-it`/`prosemirror-markdown` hand-rolling needed),
`@tiptap/extension-table(-row/-header/-cell)`, `@tiptap/extension-list` (task list/item
live inside this package as of Tiptap 3.30.3, **not** separate `extension-task-list`/
`extension-task-item` packages — verify current packaging at implementation time, since
jotty's slightly older pin (`^3.7.0`) still used the separate-package shape),
`@tiptap/extension-image`, `@tiptap/extension-link`, `@tiptap/extension-code-block-lowlight`
+ `lowlight` (curated language subset — js/ts/python/rust/bash/json/yaml/html/css/markdown
— not the full grammar bundle, since `build.rs` embeds the entire `dist/` tree as
`include_bytes!` regardless of chunking, so size discipline is about total bytes shipped,
not lazy-loading), and `vitest` as a new devDependency (no test runner exists in
`vue-project` today). Install via `bun` to match what `rust/markdown_core/build.rs`
expects from `vue-project/bun.lock`.

**Revised recommendation** (supersedes this design's original stance): do not hand-write
a `markdown-it`→`prosemirror-markdown` parser/serializer layer, and do not depend on the
*community* `tiptap-markdown` package either — use the *first-party* `@tiptap/markdown`
package instead. It already does direct token↔node conversion (no HTML detour), ships
GFM table alignment and strikethrough support, and has its own round-trip test harness —
see [tiptap-research.md](tiptap-research.md) §1/§6/§9 for the full justification. This
removes an entire hand-written layer from scope; only footnotes and `{#id}` heading
anchors still need custom code (below).

### Schema (`vue-project/src/editor/`)

Nodes: `doc`, `paragraph`, `text`, `heading` (attrs `level`, `id: string|null` — `id` set
**only** when parsed from an explicit `{#id}` suffix, never invented), `blockquote`,
`bulletList`/`orderedList`/`listItem`, `taskList`/`taskItem` (attrs `checked`), `codeBlock`
(attrs `language`, via `code-block-lowlight`), `table`/`tableRow`/`tableHeader`/`tableCell`
(extended with a custom `align: 'left'|'center'|'right'|null` attr to round-trip GFM column
alignment, which prosemirror-tables has no native concept of), `image` (attrs `src`, `alt`,
`title`), `horizontalRule`, `hardBreak`, and two **new custom nodes**: `footnoteReference`
(inline atom, attrs `label`) and `footnoteDefinition` (top-level block, attrs `label`).
Marks: `bold`, `italic`, `strike`, `code`, `link`.

No raw-HTML node type would be added anywhere in this schema — that omission is itself the
paste/XSS safety property (see Sanitization below), matching invariant #5's spirit even
though this isn't the `v-html` path.

### Markdown conversion (`@tiptap/markdown`, plus two custom extensions)

Use `@tiptap/markdown`'s `MarkdownManager` as-is for every standard node/mark (paragraphs,
headings without ids, lists, task lists, tables with alignment, strikethrough, code
blocks, links, images, blockquotes, rules, hard breaks) — do not hand-write a parser or
serializer for any of these; every extension already declares its own `markdownTokenName`/
`parseMarkdown`/`renderMarkdown` (Tiptap's markdown-equivalent of `parseHTML`/
`renderHTML`), and `@tiptap/markdown` dispatches to them via a direct `marked`-lexer-token
↔ ProseMirror-node conversion with no HTML intermediate in either direction — see
[tiptap-research.md](tiptap-research.md) §1/§2 for the exact mechanism.

Two gaps need custom extensions, each following `@tiptap/extension-table`'s pattern (a
custom `markdownTokenizer` registered into the shared `marked` lexer, plus `parseMarkdown`/
`renderMarkdown` — see tiptap-research.md §2/§9 for the template):

- **Footnotes** (`footnoteReference` inline atom node, attrs `label`; `footnoteDefinition`
  top-level block node, attrs `label`): a small custom `marked` tokenizer for `[^label]`
  refs and `[^label]: ...` definitions, registered as its own extension with
  `markdownTokenName`/`parseMarkdown`/`renderMarkdown`. Serialization must emit
  `[^label]: ` prefixed onto the definition's first line with 4-space-indented
  continuations (the CommonMark footnote-definition indentation rule) — MarkText's Muya
  has a verified-working reference implementation of exactly this
  ([marktext-muya-research.md](marktext-muya-research.md) §5).
- **Heading `{#custom-id}` anchors** (extend `Heading`'s `attrs` with `id: string|null`,
  set **only** when parsed from an explicit trailing `{#id}` suffix, never invented): a
  small `parseMarkdown`/`renderMarkdown` override on the heading extension mirroring
  `rust/markdown_vault/src/outline.rs`'s `split_heading_attributes` (strip a trailing
  `\{#([^\s}]+)\}\s*$` from the heading's raw source, stash as the node's `id` attr; emit
  it back as `` {#id} `` only when non-null). Neither jotty nor Muya nor Tiptap's own
  `extension-table-of-contents` implement this custom-id syntax (all three only support
  auto-slugged anchors) — this repo's design is in genuinely uncharted territory here, so
  budget extra iteration/testing for it specifically.

`ENABLE_SMART_PUNCTUATION` (Rust's pulldown-cmark option) is a render-time-only transform
— the editor passes literal `"`/`--` through unchanged; Rust re-applies smart punctuation
for Reading view, no parity work needed on the editor side.

### Editing UX: how typed markdown syntax disappears

Worth stating explicitly, not just implied by the "no visible `**`/`#`/`|`" goal in
Context: the ProseMirror document never stores `**`/`#`/etc. as literal characters when a
mark/node is applied — `**Bold text**` becomes a `bold` **mark** on the plain text `Bold
text`; the asterisks are a serialization detail of the markdown format, not part of the
in-memory document. Two entry paths, neither of which leaves visible syntax behind:
toolbar/keyboard-shortcut application (mark applied directly, no characters typed), and
typed markdown shorthand via `@tiptap/starter-kit`'s bundled **input rules** (free,
already confirmed present — see [jotty-editor-research.md](jotty-editor-research.md) §4)
— the instant a pattern like `**...**` completes, the input rule deletes the literal
marker characters and replaces that range with marked-up text instead, so raw syntax is
visible only for the keystrokes before the pattern closes, never as steady-state content.
Saving to disk is a one-way, editor-invisible re-encoding: `@tiptap/markdown`'s serializer
walks the doc and emits `**Bold text**` into the `.md` file, but the editor view is always
driven by the doc, never by re-parsing its own saved output. Raw markdown characters are
only ever visible in Reading view or the kept "Source" fallback view, never in the
WYSIWYG surface.

### Node views

- **Tables**: `@tiptap/extension-table*` (ships column-resize + row/column commands) + a
  small custom `TableControls.vue` for hover-revealed insert/delete affordances.
- **Task items**: `@tiptap/extension-list`'s built-in task-item checkbox node view — no
  custom code needed (confirm current package/import path at implementation time; task
  list/item moved inside `extension-list` as of Tiptap 3.30.3, see New dependencies above).
- **Images**: `@tiptap/extension-image`, inline render only in v1. Resize handles are an
  explicit **v2 stretch goal**, not v1 scope.
- **Code blocks**: `@tiptap/extension-code-block-lowlight` (highlighted-while-typing via
  `lowlight`/`highlight.js` grammars, flat text node) — **not** a nested CodeMirror 6 node
  view. A nested CM6 instance means coordinating two separate cursor/undo/IME systems for a
  secondary payoff (edit-time highlighting vs. display-time highlighting); flag as a
  v2/stretch item if wanted later.

### Outline extraction (invariant #8 — must stay byte-identical to Rust)

Extract the existing `slugify()` out of `vue-project/src/composables/useDocumentOutline.ts`
verbatim into a shared `vue-project/src/composables/slugify.ts` (pure string function);
`useDocumentOutline.ts` would import it unchanged — no behavior change, just
de-duplication, and Reading view keeps using its existing HTML-DOM-walking path untouched.
Add a new `useEditorOutline.ts` that walks the live Tiptap doc (`doc.descendants`) instead
of rendered HTML, collecting `heading` nodes, reusing the **same** ancestor-stack nesting
algorithm and same dedupe-suffix loop already in `useDocumentOutline.ts`, and the same
explicit-id-else-slugify-else-`section-N` fallback as `rust/markdown_vault/src/outline.rs`.
Since the slug *algorithm* itself would be untouched (just relocated + fed a different tree
source), this preserves invariant #8 by construction — verify against `outline.rs`'s
existing test fixtures once wired up.

### Round-trip fidelity — now a narrower risk, but not zero

`@tiptap/markdown` already ships its own round-trip fixture harness covering standard
GFM/CommonMark constructs (20 spec files, 5142 lines — see
[tiptap-research.md](tiptap-research.md) §6), so this design no longer needs to
re-prove fidelity for anything it handles natively (lists, tables+alignment, strikethrough,
code blocks, links, images). The remaining risk is narrowly scoped to the **two custom
extensions** (footnotes, heading `{#id}` anchors) and their **interaction** with the rest
of the schema — still worth a real fixture suite, just a much smaller one than originally
planned.

New shared fixture corpus (would need confirmation before creating a new top-level
directory — proposal: `fixtures/markdown-roundtrip/*.md`, sibling to `rust/`/
`vue-project/`) covering: headings with/without `{#id}` and duplicates (including a
heading that also has emphasis/code-span inline content, to check the custom parser
doesn't fight `@tiptap/markdown`'s own heading handling), footnotes (single/multiple/
multi-paragraph, and a footnote reference inside a table cell or list item to check
interaction with container nodes), and a full-document fixture mixing both custom
extensions with standard GFM constructs (tables with alignment, task lists, nested lists,
code fences) to catch any conversion-order or registration conflicts between the custom
`markdownTokenizer`s and `@tiptap/markdown`'s built-in ones. No Setext headings
(unsupported on both this design and Rust's side).

- **TS test** (`vue-project/src/editor/markdown/__tests__/roundtrip.spec.ts`, needs
  `vitest`): per fixture, `parse → doc1 → serialize → md2 → parse → doc2`, assert
  `doc1.eq(doc2)` (ProseMirror structural equality) — tolerant of first-pass reformatting,
  intolerant of drift. Snapshot-test first-pass serialized markdown to catch unintended
  formatting regressions over time.
- **Rust test** (extend `rust/markdown_core/src/render.rs`'s existing
  `a_full_featured_document_survives_sanitising`-style test): feed each fixture's
  editor-serialized output (`md2`, generated once by the TS test and checked in as golden
  files) through the real `render_markdown`, assert structural markers survive (headers,
  `<table>`, `type="checkbox"`, footnote markup, `<del>`, etc.).
- **Adopt Muya's regression-lock pattern** (see
  [marktext-muya-research.md](marktext-muya-research.md) §4): rather than only hand-picked
  fixtures, also run this pipeline against real CommonMark/GFM spec examples, with any
  known-unsupported example enumerated in a checked-in `expected-failures.json`-style
  baseline that a change may only shrink, never grow — a stronger, more maintainable
  guarantee than fixtures alone.

### Paste handling / sanitization

ProseMirror's DOM parser is allowlist-based per node/mark `parseDOM` spec; since no
raw-HTML node type would exist in this schema, pasted `<script>`/`<iframe>`/
`on*`-attributed elements would have no way to become executable nodes — a real,
load-bearing property as long as nobody later adds a raw-HTML escape hatch without
re-sanitizing it the way `render.rs` does. Two gaps to close explicitly (not assume away):
1. Verify `@tiptap/extension-link`'s `protocols` allowlist rejects `javascript:`/
   `vbscript:`, and that the `image` extension's `src` doesn't naively copy non-`http(s)`/
   `data:image/*` schemes from pasted DOM.
2. **No local-asset import path exists** — `markdown_vault` has no image/attachment tool
   today. A pasted/dragged image could only become an external URL or inline base64
   `data:` URI in v1; "paste image → local vault file" would be out of scope for a first
   pass and would need a new vault tool (a genuinely separate, later piece of work —
   flagging so it isn't assumed to already work).

## Part 2 — Bridge protocol + native integration

### Bridge (`vue-project/src/bridge/nativeBridge.ts`)

One new outbound, with-reply message, matching the existing `send<T>()` pattern used by
`connect`/`render`/`outlineState`:

```ts
{ method: 'documentEdit', text: string } // → reportEdit(text): Promise<void>
```

No reply payload needed (ack only, like `outlineState`). No debounce baked into
`nativeBridge.ts` itself (it would stay a dumb transport) — debounce would live in
whatever composable wires Tiptap's `onUpdate` to `reportEdit` (~100–250ms is plenty;
independent of native's unrelated 800ms disk-write debounce).

**Race condition that would need closing, not left open**: native's
`hasUnsavedChanges`/`HasUnsavedChanges` flips only when `workspace.text`/`.Text` actually
changes — if the Vue-side debounce delays that, there's a window where the user has typed
but the watcher's "reload only if no unsaved changes" check doesn't see it yet, so a
concurrent external write (e.g. an agent tool call) could silently reload over an
in-flight edit with no conflict banner. **Proposed fix**: add a second, undebounced signal
— fire `reportEdit`'s underlying call (or a lighter `{method:'documentEditing'}` ack-only
ping) immediately on the *first* keystroke of a burst, debounced only thereafter, so native
flips its unsaved-changes flag right away. Cheap, closes the race, no architectural cost.

**Flush-before-switch**: the WYSIWYG composable would need to expose a synchronous
`flushPendingEdit(): Promise<string>` that forces immediate serialization + `reportEdit`.
Native would need to `await` it before switching `selectedFile`/`SelectedFile` (i.e. inside
`Workspace.open(file:)`/`close()` on macOS and their Windows equivalents, at the same call
sites that already call `flushPendingSave`/`FlushPendingSaveAsync` synchronously on file
switch today) — otherwise the last few keystrokes before a fast file switch could be lost,
since today's flush-on-switch logic reads `hasUnsavedChanges` at switch time.

### Echo-suppression (the core mechanism — reuses existing code)

Both platforms already have an identity guard exactly where it's needed:
`WebPreviewCoordinator.setDocumentText`'s `guard newText != text else { return }`
(`MarkdownWebView.swift`) and `SetDocumentText`'s `if (newText == text) return;`
(`MarkdownWebView.xaml.cs`). This could be reused as the echo-suppression mechanism with
**zero new state**: in the new inbound `documentEdit` handler, set that same private
`text` field to the incoming value *before* forwarding into `workspace.text`/`.Text`. When
the resulting state change triggers the next `setDocumentText`/`SetDocumentText` call, the
guard already there sees `newText == text` and no-ops — so self-edits never get pushed
back down and clobber the editor's cursor/selection. Genuinely external changes (initial
load, watcher reload, chat-agent undo-via-watcher) never pre-set that field, so the push
still fires correctly. Recommendation: don't model this as a separate boolean flag (e.g. an
`isApplyingRemoteEdit` mirroring Windows' existing `isUpdatingEditor`) — the
value-equality guard is more precise and already exists for an unrelated reason.

### macOS (`macos/Markdown/Markdown/`)

- `MarkdownWebView.swift`: add `var onDocumentEdit: (String) -> Void` (same shape as
  existing `onOutlineAvailabilityChange`), threaded through `makeCoordinator`/
  `updateNSView`/`updateUIView` into `WebPreviewCoordinator`. New case in
  `WKScriptMessageHandlerWithReply.userContentController` for `"documentEdit"`: set
  `text = newText`, call `onDocumentEdit(newText)`, reply with `nil, nil`. No changes
  needed to `pushDocument()`/`setDocumentText()`/`didFinish`.
- `ContentView.swift`: keep the `TextEditor` behind the existing toggle, relabel it
  "Source" (was "Edit") rather than removing it. Add
  `onDocumentEdit: { workspace.text = $0 }` to the `MarkdownWebView(...)` call. No other
  structural change.
- Undo: Tiptap's own history extension would become the "typing undo" (Cmd+Z while
  focused in the WebView) — architecturally identical slot to today's implicit AppKit
  undo, no new `UndoManager` code. Stays deliberately separate from git-backed vault undo
  (`ChatViewModel.undo`), same as today. **Critical requirement**: because of the
  echo-suppression design, every inbound `setDocument` push the WebView receives after
  this ships would be, by construction, genuinely external (never a self-edit echo) — so
  the Vue-side document-change handler must treat every such push as "load a new
  document" and **explicitly reset Tiptap's undo history**, not just replace content
  (Tiptap's `setContent` alone does not clear `prosemirror-history` state) — otherwise
  Cmd+Z after a chat-agent revert could resurrect pre-revert content on the next autosave
  tick.

### Windows (`win/MarkdownWin/MarkdownWin/`)

- `MarkdownWebView.xaml.cs`: new `public event EventHandler<string>? DocumentEdited;`, new
  case in `OnWebMessageReceived` for `"documentEdit"`: set `text = newText`, invoke
  `DocumentEdited`, reply ack. No changes needed to `SetDocumentText`/`PushDocumentAsync`/
  `OnNavigationCompleted`.
- `MainWindow.xaml`/`.xaml.cs`: keep `EditorOverlay`, relabel `EditToggle` to "Source".
  Subscribe `Preview.DocumentEdited += (_, newText) => workspace.Text = newText;` alongside
  existing subscriptions. Leave `OnEditorTextChanged`/`isUpdatingEditor` untouched — that
  flag guards a different loop (between the two *native* controls) than the WebView's own
  `text`-field guard; don't fold them into one mechanism.
- Same undo-history-reset requirement as macOS would apply to the Vue-side
  document-change handler (platform-agnostic, would live in shared `vue-project/` code).

### Watcher/conflict interaction

`absorbExternalChanges`/`AbsorbExternalChanges` key off `hasUnsavedChanges`/
`HasUnsavedChanges`, which flip inside `workspace.text`'s/`.Text`'s setter regardless of
which UI surface called it — would behave identically to today once the WebView edit path
also calls that setter. The one real gap is the debounce race covered above (undebounced
first-keystroke signal would close it).

## Proposed phased delivery order

1. **Spike** (Vue-only, no native changes): stand up Tiptap + schema + parse/serialize
   behind a dev flag; build the round-trip fixture corpus and TS test; confirm fidelity is
   trustworthy before investing in native wiring. Hard gate — if fidelity isn't solid here,
   stop and reassess before phase 2+.
2. **Bridge protocol**: add `documentEdit` (+ first-keystroke undebounced signal) to
   `nativeBridge.ts`; add `flushPendingEdit()`; wire echo-suppression contract into a
   `useWysiwygDocument()`-style composable, including the undo-history-reset-on-external-
   load requirement.
3. **Editor component**: `WysiwygEditor.vue` with node views (tables, task items, code
   blocks, images), keyboard shortcuts/input rules, wired into `App.vue` alongside the kept
   `MarkdownPreview.vue` Reading view; reimplement outline extraction per above.
4. **macOS integration**: wire `documentEdit`/echo-suppression into `MarkdownWebView.swift`
   /`ContentView.swift`; run the manual test matrix below against a real vault.
5. **Windows integration**: mirror into `MarkdownWebView.xaml.cs`/`MainWindow.xaml(.cs)`;
   same manual test matrix — budget extra time since Windows' vault/autosave path is
   already flagged in `CLAUDE.md` as unverified end-to-end against a real vault/API key.
6. **Polish**: paste-sanitization verification (link protocol allowlist, image src
   scheme), "paste as markdown source" nicety, table controls UI, footnote UX.

## Testing / verification (once implemented)

- `cd rust && cargo test` after the new golden-fixture round-trip assertions land in
  `markdown_core`.
- `cd vue-project && bun test` (new vitest suite) for parse/serialize round-trip + outline
  slug-parity tests.
- Manual matrix (both platforms, against a real vault): type → 800ms+ pause → confirm one
  git commit appears (`autogit_log`) with no visible cursor jump; rapid burst typing →
  confirm only final state commits; external edit to the open file mid-typing → conflict
  banner still surfaces (not silently overwritten); chat-agent edits/undoes the open note →
  WebView reloads correctly and Cmd+Z doesn't resurrect pre-change content; fast file
  switch immediately after typing → no keystrokes lost (validates `flushPendingEdit`);
  standalone single-file (non-vault) mode still autosaves via direct file write; "Source"
  fallback view stays consistent with the WYSIWYG view in both directions.

## Key files this would touch

- `vue-project/src/editor/markdown/footnoteExtension.ts`,
  `vue-project/src/editor/markdown/headingIdExtension.ts` (new — the two custom
  `@tiptap/markdown`-pattern extensions; no hand-written parser/serializer module needed
  otherwise, see [tiptap-research.md](tiptap-research.md))
- `vue-project/src/editor/WysiwygEditor.vue` + node view components (new)
- `vue-project/src/composables/slugify.ts` (new, extracted), `useDocumentOutline.ts`
  (updated import), `useEditorOutline.ts` (new)
- `vue-project/src/bridge/nativeBridge.ts` (new `documentEdit` method)
- `vue-project/src/App.vue` (wire WYSIWYG editor alongside kept Reading view)
- `macos/Markdown/Markdown/MarkdownWebView.swift`, `ContentView.swift`
- `win/MarkdownWin/MarkdownWin/MarkdownWebView.xaml.cs`, `MainWindow.xaml`/`.xaml.cs`
- `rust/markdown_core/src/render.rs` (new round-trip golden-fixture tests)
- `rust/markdown_vault/src/outline.rs` (parity target, unchanged but referenced by tests)
- `fixtures/markdown-roundtrip/*.md` (new, proposed location — confirm before creating)
