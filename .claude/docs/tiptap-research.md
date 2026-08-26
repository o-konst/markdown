# Research: Tiptap (the chosen editor library), incl. its official markdown package

**Status: external research, not this repo's code.** This document reports findings from
reading `github.com/ueberdosis/tiptap`'s source (cloned read-only, not vendored or
committed anywhere in this repo) — the editor library
[live-preview-editing-research.md](live-preview-editing-research.md) already chose. This
research surfaced a first-party package, `@tiptap/markdown`, that materially changes that
design's parser/serializer recommendation (see Implications below — the main design doc
has been updated accordingly). Findings reflect the cloned commit as of 2026-08-25
(Tiptap v3.30.3); re-verify specifics before relying on them, since Tiptap ships frequent
releases.

## Why this was researched

The main design doc proposed hand-writing a markdown parse/serialize layer — a custom
`markdown-it` tokenizer feeding `prosemirror-markdown`'s `MarkdownParser`/
`MarkdownSerializer` classes directly — specifically because, at design time, the only
known markdown-for-Tiptap option was the *community* `tiptap-markdown` npm package, which
wasn't trusted as reliably maintained. Cloning Tiptap's own monorepo surfaced
`packages/markdown` (`@tiptap/markdown`), a **first-party** package published by the
`ueberdosis` org itself — a different thing entirely from the community package — worth
investigating before committing to a from-scratch layer.

## Findings

### 1. Conversion strategy — the central question

**Markdown → doc: direct tokenizer → node conversion, not HTML-mediated.**
`MarkdownManager.parse()` (`packages/markdown/src/MarkdownManager.ts:336-362`) runs
`marked`'s `Lexer` to get a token tree (`parseLexer.lex(markdown)`), then walks it in
`parseTokens`/`parseToken` (`:367-484`), dispatching each token to whichever registered
extension owns that `tokenName` via `handler.parseMarkdown(token, helpers)`. No HTML
string, no DOM, no `setContent(html)` anywhere in this path.

**doc → markdown: same story in reverse.** `serialize()` (`:305-313`) calls
`renderNodes`/`renderNodeToMarkdown` (`:1169-1258`), which look up the node's own
`renderMarkdown` handler by node type and ask it to produce a markdown string directly —
no `editor.getHTML()`, no turndown. Example, `Bold`:
`renderMarkdown: (node, h) => \`**${h.renderChildren(node)}**\`` (`extension-bold/src/
bold.tsx:107-109`).

**The one HTML-mediated escape hatch**: raw inline/block HTML *embedded inside the
markdown source* (e.g. a literal `<div>` in a note) is parsed via `generateJSON(html,
extensions)` (ProseMirror's DOMParser path, `MarkdownManager.ts:965-984`) and only when
`window.DOMParser` exists; on the server it falls back to literal text
(`:957-963,:1119-1136`). A narrow fallback for raw-HTML islands, not the primary
conversion mechanism.

**Tokenizer library**: `marked` (`^17.0.1`), used purely as a **lexer** (`Lexer.lex`,
`inlineTokens`, `blockTokens`) — its HTML-renderer is never invoked. Custom tokenizers
(e.g. the table tokenizer) register into the same `marked` lexer via `.use({extensions:
[...]})` (`MarkdownManager.ts:239-267`).

**Verdict**: squarely in the same camp as MarkText's Muya (direct token/node ↔ markdown,
no HTML round-trip) — see
[marktext-muya-research.md](marktext-muya-research.md) — not jotty's remark-rehype-
turndown camp, modulo the narrow embedded-raw-HTML fallback that no comparable design
avoids either.

### 2. Extension model

Extensions declare a `markdown`-shaped surface analogous to `parseHTML()`/`renderHTML()`,
read via `getExtensionField` in `registerExtension()` (`MarkdownManager.ts:126-193`):
`markdownTokenName` (which marked token type triggers this), `parseMarkdown(token,
helpers) → JSONContent`, `renderMarkdown(node, helpers, context) → string`, optional
`markdownTokenizer` (custom marked tokenizer), and `markdownOptions` (e.g.
`indentsContent`, `htmlReopen`).

- **Bold** (`extension-bold/src/bold.tsx:93-109`): `markdownTokenName: 'strong'`,
  `parseMarkdown` wraps children in a `bold` mark, `renderMarkdown` emits `**...**`, plus
  `markdownOptions.htmlReopen` for boundary-crossing marks.
- **Heading** (`extension-heading/src/heading.ts:86-106`): `parseMarkdown` reads marked's
  `token.depth`; `renderMarkdown` emits `'#'.repeat(level)`.
- **Table** (`extension-table/src/table/table.ts:320-418`): full custom
  `markdownTokenizer` (GFM-aware, handles pipe-escaping in code spans via
  `preprocessTablePipes`), `parseMarkdown` builds `tableRow`/`tableHeader`/`tableCell`
  nodes with per-column `align`, `renderMarkdown` delegates to `renderTableToMarkdown`.

This is the template to follow for any custom node this design still needs to add (see
§9/Implications).

### 3. GFM support

Confirmed directly in code: **strikethrough** (`extension-strike/src/strike.ts:80-89`,
`markdownTokenName: 'del'`). **Tables with alignment** (`table.ts:320-358` reads
`token.align` per column, sets `attrs.align` on each cell via
`normalizeTableCellAlign`) — Tiptap's own table extension already models column alignment
natively, closing a gap this design previously had to build itself. **Task lists**: in
this version (3.30.3), task list/item live **inside `extension-list`**
(`extension-list/src/task-list/{task-list,task-item}.ts`), not as separate
`extension-task-list`/`extension-task-item` packages — a real naming/packaging change
from the version jotty depended on (`^3.7.0`, separate packages), worth pinning the
correct package name at implementation time rather than assuming jotty's shape still
applies. `MarkdownManager.ts:495-612` additionally has bespoke logic to split mixed
bullet/task lists into separate `list`/`taskList` nodes when both extensions are
registered.

### 4. Footnotes

**Absent.** `grep -ril "footnote" packages/*/src packages/*/README.md` returned nothing
across all 62 packages. This design still has to solve footnotes itself — same
conclusion as jotty (absent) and Muya (present, but a different from-scratch engine).

### 5. Heading anchors / custom ids

**Not supported.** `heading.ts` has no id attribute at all (only `level`);
`@tiptap/markdown` has no `{#id}`-style syntax anywhere. `extension-table-of-contents`
computes anchors/slugs separately at runtime, not from markdown syntax. This design still
needs its own small extension for `{#custom-id}` parsing, same conclusion as before.

### 6. Test coverage

`packages/markdown/__tests__/` has 20 spec files, 5142 lines total, including a
dedicated **round-trip fixture harness**: `conversion.spec.ts` +
`conversion-files/*.ts` (bullet-list, ordered-list, task-list, mixed-list-types,
link-with/without-title, hard-break-marks, custom-atom/block/inline, nested-nodes, etc.)
— each fixture pairs `expectedInput` (markdown) with `expectedOutput` (JSON). Other specs
target specific fidelity edge cases: `overlapping-marks.spec.ts` (667 lines),
`ordered-list-lazy-continuation.spec.ts`, `task-list-nested-siblings.spec.ts`,
`unknown-html-tags.spec.ts`, `mixed-html.spec.ts`, `server-side-parsing.spec.ts` (the
no-DOMParser fallback). Real round-trip + edge-case testing, not just parse-only unit
tests — a meaningfully lower residual-risk starting point than hand-writing this layer
from scratch.

### 7. Maturity

Introduced in **3.7.0** ("Add comprehensive bidirectional markdown support... using
MarkedJS"), now at **3.30.3** — roughly 24 releases of incremental fixes (blank-line
preservation, malformed-tag handling, etc.), no breaking-change entries observed.
Actively maintained, not brand-new/experimental, but younger than Tiptap core itself. The
package's own README is boilerplate (no authored scope/limitations doc); maturity signal
comes from the changelog and test suite, not the README.

### 8. Licensing

All confirmed MIT via each package's own `package.json`: `@tiptap/core`, `@tiptap/pm`,
`@tiptap/markdown`, `extension-table`, `extension-image`, `extension-link`,
`extension-code-block`, `extension-code-block-lowlight`, `extension-list` (task list
lives here), `extension-collaboration`, `extension-collaboration-caret`, `ai-toolkit` —
every one says `"license": "MIT"`. `ai-toolkit`'s own description names it as the SDK for
a hosted **Server AI Toolkit service** — a paid backend, even though the client SDK
source is MIT; not relevant to this design, which doesn't plan to use it.
`extension-collaboration`/`-caret` have no paywall language in-repo — the extension code
works against any self-hosted Yjs provider for free; it's Tiptap's *hosted* Cloud/Collab
service that's paid, not the extension itself. Also not currently in scope for this
design.

### 9. Recommendation

**Adopt `@tiptap/markdown`, drop the hand-written `markdown-it`→`prosemirror-markdown`
layer.** It already does exactly what the main design set out to hand-build: direct
token↔node conversion (no HTML detour), per-extension declarative markdown hooks
mirroring `parseHTML`/`renderHTML`, GFM tables with alignment, strikethrough, task lists,
and a real round-trip test harness. It is first-party (ueberdosis), MIT, actively patched
over ~24 releases — this resolves the original uncertainty about the *community*
`tiptap-markdown` package; this is a different, first-party package.

Two real gaps remain, both of which the hand-written layer would have had to solve too:
**footnotes** (write a custom `marked` tokenizer + node extension with
`markdownTokenName`/`parseMarkdown`/`renderMarkdown`, following the Table extension's
pattern in `table.ts:365-418` as the template) and **heading anchors/custom ids** (`{#id}`
syntax — add via a small extension to `Heading`'s `parseMarkdown`/`renderMarkdown`, or
keep doing this at the app layer like `extension-table-of-contents` does, decoupled from
markdown syntax). Both slot into the extension registration mechanism
(`MarkdownManager.registerExtension`) without touching `@tiptap/markdown` internals — the
intended extension point, not a workaround.

Net effect: replace the planned custom parser/serializer with `@tiptap/markdown`, and
write only two small custom extensions (footnote tokenizer/node, heading-id parsing)
instead of an entire hand-rolled markdown layer. This is a strict simplification of the
main design doc, not a scope increase.

## Key files read (Tiptap's repo, not this one)

- `packages/markdown/src/MarkdownManager.ts` — the whole conversion core (both
  directions), extension registration, the raw-HTML fallback path
- `packages/markdown/src/Extension.ts`, `types.ts` — the `markdown` extension-field
  contract (`parseMarkdown`/`renderMarkdown`/`markdownTokenName`/`markdownTokenizer`)
- `packages/extension-bold/src/bold.tsx`, `packages/extension-heading/src/heading.ts` —
  minimal markdown-hook examples
- `packages/extension-table/src/table/table.ts` — the template for a custom
  tokenizer-backed node (what a footnote extension should follow)
- `packages/extension-strike/src/strike.ts`, `packages/extension-list/src/task-list/
  {task-list,task-item}.ts` — GFM strikethrough/task-list support and current package
  location
- `packages/markdown/__tests__/` (`conversion.spec.ts` + `conversion-files/*.ts`,
  `overlapping-marks.spec.ts`, `task-list-nested-siblings.spec.ts`, others) — the
  round-trip/fidelity test harness
- `packages/markdown/package.json`, and each referenced extension's `package.json` —
  license confirmation
