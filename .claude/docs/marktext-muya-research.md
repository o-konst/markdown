# Research: MarkText's Muya editor engine (prior art)

**Status: external research, not this repo's code.** This document reports findings from
reading `github.com/marktext/marktext`'s source (cloned read-only, not vendored or
committed anywhere in this repo) to stress-test the design in
[live-preview-editing-research.md](live-preview-editing-research.md) before building
anything. MarkText is the flagship open-source Typora-style editor; its editor engine is
extracted as a standalone package, `packages/muya` (published as `@muyajs/core`). Unlike
Tiptap/ProseMirror (this design's choice) or jotty's approach (see
[jotty-editor-research.md](jotty-editor-research.md)), Muya is a **from-scratch
contenteditable-based engine** — not built on ProseMirror, CodeMirror, or Tiptap. Findings
below reflect the cloned commit as of 2026-08-25 (a fully TypeScript-rewritten Muya —
`@muyajs/core` v0.2.0 — materially more sophisticated than the legacy JS version the
package's own top-level README describes; some paths named in that README, e.g.
`packages/core/test/spec/conformance.md`, are stale — the real path is
`packages/muya/test/spec/conformance.md`). Re-verify specifics before relying on them.

## Why this was researched

Same motivation as the jotty research: stress-test `live-preview-editing-research.md`'s
proposed Tiptap + hand-written `markdown-it`→`prosemirror-markdown` parser/serializer
design, and its round-trip-fidelity concern in particular, against real, mature prior art.
Muya is the most relevant reference available for "true WYSIWYG, no visible markdown
syntax" editing specifically (as opposed to jotty's more generic rich-text-editor-that-
happens-to-export-markdown shape).

## Findings

### 1. Core architecture

A real class-per-block-type tree, not HTML-string diffing. Base hierarchy: `TreeNode` →
`Parent` (container blocks, `children: LinkedList<TreeNode>`, owns a live `domNode`,
`block/base/parent.ts:12`) and `Content`/`Format` (leaf text-content blocks with
cursor/selection + `fast-diff`-based text ops, `block/base/content.ts`,
`block/base/format.ts`). `block/commonMark/atxHeading/index.ts:11-49` is a representative
block: `tagName = h${level}`, a `static create(muya, state)` factory registered via
`ScrollPage.loadBlock`, and `getState()` reconstructing its own state slice.
`block/gfm/table/index.ts:20-70` shows a container block (`Table extends Parent`)
composed of nested `TableInner`/`TableRow`/`TableBodyCell` blocks, each independently
stateful. Blocks render into real contenteditable DOM nodes; edits happen via native
typing, and `Content`'s diff of old/new text produces both a live DOM patch and an
`ot-json1` op recorded into the `JSONState` (`diffToTextOp`). The reverse direction (undo/
redo, external `setContent`/API writes) goes through `ScrollPage.updateState`, a full
rebuild from state. Inline content (bold/links/images/footnote refs) is **not** structured
nodes — it's snabbdom vnodes computed at render time by re-lexing the block's raw markdown
text (`inlineRenderer/renderer/*`).

### 2. Markdown → internal model

Not HTML-mediated — a materially different, better-founded strategy than jotty's
remark→HTML→Tiptap-HTML-parser path. `utils/marked/lexBlock.ts:16-46` uses `marked`'s
**token-level `Lexer.blockTokens()`** (a fresh `Marked` instance per call, extensions for
math/footnote/frontmatter registered via `m.use()`) — never `marked`'s HTML renderer.
`state/markdownToState.ts` (`MarkdownToState.generate`) walks these block tokens directly
into `TState[]` block objects, using a `CONTAINER_TOKEN_TYPES` stack (`blockquote`/`list`/
`list_item`/`footnote`) with synthetic `block-end` markers to build nesting.

### 3. Internal model → markdown

Confirmed, and the single biggest architectural lesson here: the primary write path
(`getMarkdown()`) is **block→markdown directly, bypassing HTML/turndown entirely**.
`state/stateToMarkdown.ts`'s `ExportMarkdown` class has one dedicated private serializer
per block type (`_serializeAtxHeading`, `_serializeTable`, `_serializeFootnote`,
`_serializeCodeBlock` with fence-length recomputation, etc.), each block knowing exactly
how to emit its own markdown syntax including list-marker/indentation bookkeeping across
sibling state. `turndown` + `joplin-turndown-plugin-gfm` (`utils/turndownService/`) is
used **only** by `state/htmlToMarkdown.ts`, called solely from `clipboard/paste.ts:669` —
i.e. turndown is exclusively an external-paste (browser/Word HTML clipboard) importer, not
part of save/export. State never round-trips through HTML on the way out.

### 4. Round-trip fidelity / conformance testing

Real and rigorous — the most directly useful finding for this design's testing plan.
`packages/muya/test/spec/`: `commonmark.spec.ts`, `gfm.spec.ts`, `roundTrip.spec.ts`,
`runner.ts`, `expected-failures.json`, `conformance.md` (99 lines). The conformance runner
renders via `renderToStaticHTML(..., {sanitize:false})` to test parser compliance in
isolation from DOMPurify, normalizes HTML (attribute sort, self-closing form, whitespace)
before comparing to spec-example HTML, and locks a baseline via `expected-failures.json`
— **a regression can only improve compliance, never regress**: any newly-passing example
must be removed from the file, and any non-listed example must keep passing. Headline
numbers: **CommonMark 0.31: 572/652 (87.7%)**, **GFM 0.29: 580/672 (86.3%)**, broken down
per-section (e.g. Tabs 9.1%, Emphasis 100%, Entity refs 29.4%). Separately,
`roundTrip.spec.ts` runs real fixture-based round trips (`MarkdownToState` →
`StateToMarkdown`, fixtures ported from the old marktext test suite), normalizing only
line endings/trailing newline, explicitly preserving trailing-space hard-breaks. This
"lock a known-failures baseline, only allow it to shrink" pattern is directly reusable for
this design's own round-trip fixture suite — a concrete refinement worth adopting (see
Implications below).

### 5. Footnotes

Modeled as a real block type — the reference implementation jotty entirely lacked.
`block/extra/footnote/index.ts:10-77`: `Footnote extends Parent` (`tagName: 'figure'`,
`meta.identifier`), holding child paragraph blocks; renders a `[^id]:`-style label span
and a clickable "↩︎" backlink that scrolls to `#noteref-{id}`. Inline references render
via `inlineRenderer/renderer/footnoteIdentifier.ts`. Interactive UI is
`ui/footnoteTool/index.ts` (a popover keyed by identifier, showing a truncated preview).
Serialization (`stateToMarkdown.ts:442-458`) emits `[^id]: ` prefixed onto the first child
line, continuation content indented 4 spaces — correctly handling the CommonMark
footnote-definition indentation rule. Export-to-HTML footnotes go through a dedicated
post-processor, `state/transformFootnotes.ts`, run *before* DOMPurify (sanitization would
otherwise strip the marker attribute the transform needs).

### 6. Tables

Custom-editable via `ui/tableChessboard`, `tableColumnToolbar`, `tableDragBar`,
`tableRowColumMenu`. **Alignment is correctly modeled and round-tripped** — the gap jotty
appeared to have: each header cell carries `meta.align: 'none'|'left'|'center'|'right'`
(`block/gfm/table/cell.ts:54-60`, writing both `domNode.dataset.align` and `meta.align`),
and `stateToMarkdown.ts:471-534` reads `th.meta.align` from the first row to emit the
correct `:---`/`:---:`/`---:` delimiter row, with per-column width padding via
`stringWidth` (visual-width aware, correct for CJK/wide chars — a detail this design's
plan doesn't currently mention and could adopt). A dedicated test
(`block/gfm/table/__tests__/alignColumn.spec.ts`) exercises the alignment toolbar
end-to-end (state + DOM dataset + serialized delimiter).

### 7. Code blocks

Prism highlighting happens **inside the same contenteditable block**, not a separate
embedded editor instance. `block/commonMark/codeBlock/index.ts:56-88`: language is lazily
loaded (async dynamic import of the Prism grammar) on `set lang`, then
`lastContentInDescendant()?.update()` re-renders tokens as the user types — live
highlight-as-you-type with no second editor engine involved. Line-numbers gutter is a
separately-managed DOM wrapper moved out of the scrollable code node specifically to
avoid clipping (documented inline). A real gotcha documented in the code: indented-vs-
fenced code blocks are different `meta.type`s converted via an explicit diff+OT-edit-op
dance when a language is set on an indented block.

### 8. Images

`ui/imageResizeBar/index.ts` computes an integer pixel width from drag deltas, then calls
`Format.updateImage(imageInfo, 'width', value)` (`block/base/format.ts:405-444`).
Critically, `updateImage` does **not** touch a structured attrs object or DOM style — it
rewrites the block's own markdown-source text, splicing a literal `<img src="..."
width="..." />` HTML tag string in place of the original `![alt](src)` range, then
re-renders from that text. This is simpler and more robust than jotty's approach (which
separately mutates DOM style attrs *and* a ProseMirror transaction) precisely because in
Muya the leaf block's "model" *is* its markdown text — editing the text is the single
source of truth for both persistence and re-render. No dedicated local-file-import path
was found in the resize bar itself (images referenced by URL/data-URI/relative path).

### 9. Sanitization

DOMPurify (`utils/dompurify.ts`) runs at **three distinct points**, a stronger posture
than a single sanitize-on-render backstop: (a) live inline raw-HTML rendering
(`inlineRenderer/renderer/htmlTag.ts:78-84`) — per-attribute allow-list check via
`isValidAttribute(tag, attr, value)` while building vnodes (never `innerHTML`), with
tag-level demotion to `<span>` for anything rejected (e.g. `<embed>`); (b) raw HTML
**block** preview (`block/commonMark/html/htmlPreview.ts:60-77`) — sanitize gates a real
`innerHTML` assignment, additionally toggleable off entirely via
`muya.options.disableHtml`; (c) HTML export path (`state/markdownToHtml.ts`) — sanitize
runs after `transformFootnotes`. `utils/url.ts:3-13` `sanitizeHyperlink` reuses
`isValidAttribute('a','href',...)` to validate link URLs. No un-sanitized raw-HTML path
was found — CommonMark's raw-HTML allowances are consistently routed through one of these
three DOMPurify call sites.

### 10. Biggest architectural lesson: build-your-own vs. Tiptap

No explicit "why not ProseMirror" rationale doc exists in the repo (`docs/ROADMAP.md` is a
plain feature/dev log, not a design-rationale doc) — Muya likely predates
Tiptap/mature ProseMirror-for-markdown tooling, though that's inference, not stated
in-repo.

**Case for Muya's approach**: markdown text is the literal source of truth per leaf
block, so save/export never needs a lossy AST→string re-serialization step for the common
case — bold/italic/links/images are just substrings the user already typed, so fidelity
is trivially perfect for anything the block-level parser round-trips (verified at 87%+
CommonMark/GFM conformance with regression-locked tests). Full control over exact
list-marker/indentation/fence-length choices that would otherwise require fighting
`prosemirror-markdown`'s serializer defaults.

**Case against, favoring this design's Tiptap choice**: Muya had to hand-build everything
ProseMirror gives for free — its own selection/cursor model (`src/selection/`), its own
undo/history stack wired to OT ops (`src/history/`), its own clipboard/paste pipeline, its
own inline lexer distinct from block parsing (`src/inlineRenderer/`), and per-block
DOM-sync/diffing logic (`fast-diff` + manual OT op construction) that ProseMirror's
`Transform`/`Step` machinery already solves generically. The per-block-type
hand-written-serializer approach (627 lines in `stateToMarkdown.ts` alone) is exactly the
kind of "custom node type + serializer" work this design already plans for table/
footnote/task-list nodes — Muya just extends that pattern to *every* block and inline
type, which is plausibly why an 87% conformance ceiling exists after ~7 years of
development (Tabs section only 9%, several CommonMark edge cases still unresolved in
`expected-failures.json`).

## Implications for this repo's design

- **Strongest concrete lesson, and a design refinement to adopt**: serialize
  state→markdown with **per-node-type methods directly** (as `live-preview-editing-
  research.md` already proposes via `prosemirror-markdown`'s `MarkdownSerializer`),
  **never** via a serialize-to-HTML-then-turndown detour. Muya proves this is not just
  theoretically tighter but load-bearing in practice — it's the reason Muya's fidelity is
  as good as it is, and the reason jotty's (HTML-mediated) approach is structurally
  leakier. Worth stating as an explicit non-negotiable in the design, not just an
  implementation detail.
- **Adopt Muya's conformance-testing pattern**: a locked `expected-failures.json`-style
  baseline (known gaps enumerated and allowed to only shrink, never grow) is a stronger
  version of this design's proposed round-trip fixture suite — consider running the
  design's fixtures against real CommonMark/GFM spec examples in addition to hand-picked
  ones, with the same "can only improve" regression discipline.
- **Table alignment**: further confirms (independent of jotty's absence of it) that this
  design's explicit `align` attr is the right call — and Muya's `stringWidth`
  visual-width-aware column padding (for CJK/wide characters) is a detail worth folding
  into the table serializer design, not currently mentioned there.
- **Footnotes**: a real, working reference implementation now exists to model against
  (unlike after the jotty research, which found none) — the 4-space continuation-indent
  serialization rule and the "run footnote transform before sanitization" ordering are
  both directly applicable if similar footnote UI/serialization is built.
- **Images**: Muya's "markdown text is the single source of truth, splice the raw
  `<img>`/attrs string in place" approach is simpler than jotty's dual DOM-style +
  ProseMirror-transaction mutation, but doesn't map cleanly onto a ProseMirror-based
  design (where the node's `width`/`height` *should* live as structured attrs, not spliced
  text) — no change needed to this design's plan, just noting the two architectures solve
  this differently for good reason (Muya's leaf block *is* text; a ProseMirror node is
  structured data).
- **Validates the Tiptap/ProseMirror choice overall**: Muya's scope of hand-built
  infrastructure (selection, undo/OT history, clipboard, inline lexer, DOM diffing) is
  substantial, and its 87% conformance ceiling after ~7 years is a caution against
  underestimating a from-scratch engine's true cost. Building on Tiptap/ProseMirror
  remains the right tradeoff for this project's scale — Muya's lessons are about
  **serialization discipline and testing rigor**, not a case for abandoning Tiptap.

## Key files read (MarkText's repo, not this one)

- `packages/muya/src/block/base/{parent,content,format}.ts` — core block-tree base
  classes
- `packages/muya/src/block/commonMark/atxHeading/index.ts`,
  `packages/muya/src/block/gfm/table/{index,cell}.ts` — representative block
  implementations
- `packages/muya/src/utils/marked/lexBlock.ts`,
  `packages/muya/src/state/markdownToState.ts` — markdown → internal model
- `packages/muya/src/state/stateToMarkdown.ts` — internal model → markdown (the
  per-block-type direct serializer)
- `packages/muya/src/state/htmlToMarkdown.ts`, `packages/muya/src/clipboard/paste.ts` —
  turndown's actual (paste-only) scope
- `packages/muya/test/spec/{conformance.md,commonmark.spec.ts,gfm.spec.ts,
  roundTrip.spec.ts,runner.ts,expected-failures.json}` — conformance/round-trip test
  harness
- `packages/muya/src/block/extra/footnote/index.ts`,
  `packages/muya/src/state/transformFootnotes.ts` — footnote block + export transform
- `packages/muya/src/ui/imageResizeBar/index.ts`,
  `packages/muya/src/block/base/format.ts` (`updateImage`) — image resize
- `packages/muya/src/utils/dompurify.ts`, `packages/muya/src/utils/url.ts` — sanitization
