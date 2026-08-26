# Research: jotty's Tiptap markdown editor (prior art)

**Status: external research, not this repo's code.** This document reports findings from
reading `github.com/fccview/jotty`'s source (cloned read-only, not vendored or committed
anywhere in this repo) to stress-test the design in
[live-preview-editing-research.md](live-preview-editing-research.md) before building
anything. jotty is a real, shipped Next.js/React note-taking app built on Tiptap — the
closest public reference found for a Typora-style WYSIWYG markdown editor. Findings below
reflect jotty's code as of the commit cloned on 2026-08-25; re-verify before relying on
specifics.

## Why this was researched

`live-preview-editing-research.md` proposes: Tiptap + a hand-written `markdown-it`
tokenizer feeding `prosemirror-markdown`'s `MarkdownParser`/`MarkdownSerializer`
**classes** directly (not their default schema-basic instances) for markdown↔ProseMirror
conversion, plus custom node types for footnotes, task lists, and alignment-aware tables,
with a round-trip fidelity fixture-test suite as the primary risk mitigation. jotty is a
production app using the same base library (Tiptap) but — per its `package.json` — pulling
in `turndown`/`turndown-plugin-gfm` alongside `react-markdown`/`remark-*`/`rehype-*`,
suggesting a different, HTML-mediated conversion strategy worth understanding before
committing to the from-scratch approach.

## Findings

### 1. Markdown → editor document

`app/_utils/markdown-utils.tsx:453-797`, function `convertMarkdownToHtml`. A `unified()`
pipeline (`remarkParse` → `remarkGfm` → `remarkRehype({allowDangerousHtml:true})` →
`rehypeRaw` → a custom AST-visitor plugin → `rehypeStringify`) turns markdown into an HTML
**string**, then feeds it straight into Tiptap (`TipTapEditor.tsx:265-271`):

```ts
const htmlContent = convertMarkdownToHtml(markdownContent);
editor.commands.setContent(htmlContent, { emitUpdate: false });
```

There is no direct markdown-token→ProseMirror-node path; ProseMirror's own DOM-based HTML
parser (invoked by `setContent`) builds the doc, driven by each extension's `parseHTML()`.

### 2. Editor document → markdown

Confirmed: `createTurndownService` (`markdown-utils.tsx:66-440`) builds a `TurndownService`
with `turndown-plugin-gfm` plus ~15 custom `addRule` calls (tables, task items, callouts,
mermaid/drawio/excalidraw comments, file attachments, internal links, colored/highlighted
spans). `convertHtmlToMarkdownUnified` wraps it (`markdown-utils.tsx:812-818`); HTML comes
from `editor.getHTML()` (`TipTapEditor.tsx:144, 196`). The persisted note content is always
markdown — `useNoteEditor.tsx:120-126` computes `derivedMarkdownContent` via that function
and that's what `handleSave` writes to disk; HTML only exists transiently in editor state.

### 3. Why two markdown libraries?

Not a clean split — remark/rehype is used in both places: inside `convertMarkdownToHtml`
for editor ingestion, and again (independently) wrapped by `react-markdown` inside
`UnifiedMarkdownRenderer.tsx:564-570` (`<ReactMarkdown remarkPlugins={[remarkGfm]}
rehypePlugins={[rehypeSlug, rehypeRaw]} components={...}>`). Turndown is the one library
confined to a single purpose: HTML→markdown on save/mode-switch.

`UnifiedMarkdownRenderer` **is** a genuinely separate read-only reading-view renderer — it
renders React components directly (with overrides for tables, callouts, mermaid, drawio,
internal links, code blocks) rather than producing an HTML string for a WYSIWYG doc, and
it's the only place `rehype-slug` is used (auto heading-id slugging only). This validates
keeping editing and reading-view rendering as separate code paths — jotty gets there via
two independent remark/rehype consumers, not one shared parser feeding two backends.

### 4. Editor modes

Three real modes, switched via `toggleMode()` (`TipTapEditor.tsx:179-217`, also bound to
Cmd+Shift+Alt+M), driven by `user.disableRichEditor`/`user.notesDefaultEditor`:

- `VisualEditor.tsx` — thin wrapper around Tiptap's `<EditorContent>`, drag/drop handling.
- Markdown-source mode inside `TipTapEditor` (`MarkdownEditor`, wrapping
  `SyntaxHighlightedEditor.tsx`) — a raw textarea (`react-simple-code-editor` + Prism
  markdown grammar) with an optional live preview toggle (`UnifiedMarkdownRenderer`).
- `MinimalModeEditor.tsx` — a fully separate, Tiptap-free plain-text fallback (enabled via
  `user.disableRichEditor === "enable"`), also wrapping `SyntaxHighlightedEditor` +
  `UnifiedMarkdownRenderer`, with formatting shortcuts as regex textarea manipulation in
  `app/_utils/markdown-editor-utils.ts` (`insertBold`, `wrapOrInsert`, etc.) rather than
  editor commands.

Live "type markdown syntax to get formatting" input rules exist but aren't custom-written
— they come free from `@tiptap/starter-kit`'s bundled extensions (Bold/Italic/Heading/
Blockquote/CodeBlock/Lists each ship their own input rules). `editorConfig.ts:72-79` just
disables the pieces jotty replaces (`codeBlock`, `underline`, `link`, `listItem`,
`bulletList`, `hardBreak`) and keeps the rest of StarterKit's defaults.

### 5. Round-trip fidelity

No round-trip test suite and no fixture-based markdown tests exist anywhere in `tests/`
(44 test files, all about checklists/auth/server actions/APIs). `howto/MARKDOWN.md`
documents supported syntax but is silent on lossiness or edge cases — no acknowledgment of
reformatting/normalization risk. Real gap relative to the fixture-testing strategy in
`live-preview-editing-research.md` — this is a cautionary data point *for* that plan, not
evidence such testing is unnecessary.

### 6. Tables, task lists, footnotes, heading ids

- **Tables**: customized. `Table`/`TableRow`/`TableHeader`/`TableCell` extended with
  tighter `content` schemas (`editorConfig.ts:181-194`); the turndown `table` rule
  (`markdown-utils.tsx:146-206`) manually pads/aligns pipe-table columns, or falls back to
  raw beautified HTML for "complex" cells (nested lists/tables/multiple paragraphs,
  `hasComplexTableContent`, `markdown-utils.tsx:41-64`) or when `tableSyntax === "html"`.
  **No column-alignment (`:---:`) handling found anywhere.**
- **Task lists**: standard `@tiptap/extension-task-list`/`task-item`, `TaskItem` extended
  for a custom `data-checked` attribute parse (`editorConfig.ts:199-215`); the remark/
  rehype visitor (`markdown-utils.tsx:546-620`) does nontrivial DOM surgery converting GFM
  task-list HTML into Tiptap's expected `data-type="taskItem"` shape.
- **Footnotes**: absent entirely — no dependency, no code, no mention in `howto/
  MARKDOWN.md`. Confirmed via dependency list and grep.
- **Heading ids**: auto-slug only, via `rehype-slug`, and only in the read-only
  `UnifiedMarkdownRenderer` path — the editor's own `convertMarkdownToHtml` pipeline
  doesn't even include `rehype-slug`. No custom `{#id}` anchor syntax exists.

### 7. Autosave / debounce

Two distinct timers, easy to conflate: (a) `TipTapEditor.tsx:99-109`'s
`debouncedOnChange` is a `setTimeout(...,0)` — not a real debounce, just a macrotask
deferral to avoid setState-during-render; every keystroke still propagates near-
immediately. (b) The actual autosave lives in `useNoteEditor.tsx:300-331`: a
`setTimeout(..., user.notesAutoSaveInterval || 5000)` gated on `hasUnsavedChanges`. Because
the effect's dependency array doesn't include the content itself, the timer arms once when
the note becomes dirty and fires at a fixed delay after that — it does **not** reset on
every subsequent keystroke the way a classic debounce would.

### 8. Image handling

`useImageResize.ts` (136 lines) is a hand-rolled resize solution, not a ProseMirror resize
plugin: reads the clicked `<img>`'s `style`/`width`/`height` into React state, and on
drag/preview writes both the DOM element's `style` directly *and* a ProseMirror
transaction (`state.tr.setNodeMarkup`, `useImageResize.ts:87-107`) to keep the node attrs
in sync, driven by a custom `CompactImageResizeOverlay` component. `useFileUpload.ts` posts
to a server action (`uploadFile`, size-capped by `appSettings.maximumFileSize`) and on
success gets back a `url`, inserted via `editor.setImage({src: url})` — no base64 inlining;
images/attachments are stored server-side and referenced by URL for both paste
(`editorHandlers.ts:142-191`) and drop (`TipTapEditor.tsx:294-349`).

## Implications for this repo's design

- **Reconsider vs. confirm**: jotty's shipped alternative (markdown→HTML→Tiptap-HTML-parse,
  and getHTML→turndown→markdown) avoids writing a from-scratch token-to-node mapper, at
  the cost of two lossy conversion boundaries instead of one, and — per §5 — no fidelity
  tests to catch drift. The `markdown-it` → `prosemirror-markdown` classes approach in
  `live-preview-editing-research.md` is architecturally tighter and better matches this
  repo's invariant #8-style "keep it exact" philosophy; jotty's approach is pragmatic and
  fast-to-ship but structurally leakier. **Recommendation: keep the direct approach.**
- **Validates** custom node types for footnotes/task-lists/tables — jotty's
  `CalloutExtension`/`DetailsExtension` prove the "custom node + parseHTML/renderHTML"
  pattern works in production, though jotty's serializer side is a turndown `addRule`, not
  a `prosemirror-markdown` node spec — the node-type idea transfers without the
  turndown-based serialization.
- **Validates** keeping a separate reading-view renderer from the editing surface.
- **New risk flagged in this repo's design, now with evidence**: jotty ships zero
  automated round-trip tests despite ~15 custom turndown rules and a nontrivial AST
  visitor — exactly the risk category `live-preview-editing-research.md` already calls out
  as its biggest risk; a cautionary data point in favor of that plan's fixture tests.
- **Table alignment**: jotty appears not to handle `:---:` at all — the explicit `align`
  attr proposed in this repo's design is a genuine improvement, not redundant work.
- **Footnotes and `{#id}` heading anchors**: both entirely unimplemented in jotty — no
  counter-evidence either way; this repo's design is in uncharted territory here relative
  to any reference implementation, so treat the `markdown-it-footnote` token-shape flag
  and the custom heading-id ruler as higher-risk, validated only by this repo's own
  fixture tests, not by prior art.
- **Autosave pattern**: jotty's fixed-delay-since-dirty timer (doesn't reset per keystroke)
  is a different, more lossy tradeoff than this repo's existing native autosave (800ms,
  reset-per-keystroke, confirmed in `live-preview-editing-research.md`'s bridge-design
  research) — no change needed there, just noting they're genuinely different patterns and
  this repo's is the more conservative one for avoiding lost keystrokes.
- **Image handling**: confirms treating image resize as a v2/stretch goal is reasonable —
  it's real, non-trivial custom work in jotty too, not a checkbox any library provides for
  free. jotty's upload-to-URL flow is a usable template if this repo later wants "paste
  image → local vault file" (a new `markdown_vault` tool plus a paste/drop handler calling
  it, mirroring `useFileUpload.ts`'s shape) — currently out of scope, per the parent doc.

## Key files read (jotty's repo, not this one)

- `app/_utils/markdown-utils.tsx` — the whole conversion core (both directions)
- `app/_components/FeatureComponents/Notes/Parts/TipTap/TipTapEditor.tsx` — wiring, mode
  toggle, debounce
- `app/_hooks/useNoteEditor.tsx` — save/autosave, always-markdown persistence
- `app/_components/FeatureComponents/Notes/Parts/UnifiedMarkdownRenderer.tsx` — separate
  reading-view renderer
- `app/_components/FeatureComponents/Notes/Parts/TipTap/EditorUtils/editorConfig.ts` —
  extension list/config
- `app/_components/FeatureComponents/Notes/Parts/TipTap/MinimalModeEditor.tsx`,
  `SyntaxHighlightedEditor.tsx` — raw-source fallback mode
- `app/_components/FeatureComponents/Notes/Parts/TipTap/CustomExtensions/
  CalloutExtension.tsx` — custom Node example
- `app/_components/FeatureComponents/Notes/Parts/TipTap/EditorHooks/useImageResize.ts`,
  `useFileUpload.ts`
- `howto/MARKDOWN.md` — supported-syntax doc (no lossiness disclosure)
- `tests/` — confirmed no markdown round-trip fixtures exist
