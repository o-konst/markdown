# Research: Quill (an alternative editor library considered and rejected)

**Status: external research, not this repo's code.** This document reports findings from
reading `github.com/slab/quill`'s source (cloned read-only, not vendored or committed
anywhere in this repo) to stress-test whether
[live-preview-editing-research.md](live-preview-editing-research.md)'s choice of
Tiptap/ProseMirror should be reconsidered. **Verdict: no — this research confirms staying
with Tiptap.** Findings reflect the cloned commit as of 2026-08-25 (Quill 2.0.3,
BSD-3-Clause); re-verify specifics before relying on them.

## Why this was researched

Quill is architecturally different from every editor researched so far: it's built on its
own **Delta** format (a JSON operational-transform document representation — flat
`{insert, delete, retain}` ops with attribute maps) and a **Blot** DOM-abstraction system,
not ProseMirror. It has no historical reputation as a markdown-first editor (it's mostly
known for HTML/rich-text editing in web apps, e.g. early Slack's message composer). This
was a genuine "why not Quill, actually" check, not a foregone conclusion — read the actual
code before concluding either way.

## Findings

### 1. The Delta model

`quill-delta` is an external npm dependency, not vendored in this repo. Quill's own
document model (`core/editor.ts`, `this.delta: Delta`) is built by concatenating each
*line*'s Delta (`getDelta()`: `this.scroll.lines().reduce((delta, line) =>
delta.concat(line.delta()), new Delta())`). A Delta is fundamentally a **flat sequence of
`{insert, attributes}` ops** — styled runs of text/embeds, terminated by `\n` characters
carrying block-level attributes (e.g. `{insert:'\n', attributes:{header:1}}`). There is no
first-class nested-block tree in the wire format: list nesting is reconstructed
procedurally at HTML-render time from a flat `indent` attribute integer
(`editor.ts:326-361,439-448`, `convertListHTML` infers `<ol><li><ol>...` structure from
indent depth, not real containment). Real nesting only exists in the DOM/Blot layer for
structurally distinct containers (tables), not in the Delta itself for arbitrary recursive
markdown constructs like "table inside blockquote" or "code block inside list item." A
genuine impedance mismatch with markdown's recursive block grammar.

### 2. Markdown import/export — real or not?

Confirmed: `src/modules/syntax.ts` is Prism/highlight.js-based **code-block syntax
highlighting only** (`class Syntax extends Module`, `highlight()`/`highlightBlot()`) — it
tokenizes code-block text for coloring; it does not parse or emit markdown documents. No
other markdown hit anywhere in `src/`. No first-party markdown module exists. From
general knowledge (not verified against this repo — flagged as such): community packages
like `quill-delta-to-markdown`/`quill-markdown-shortcuts`/assorted gists exist, but with
low-to-moderate confidence in any being actively maintained or handling nested/table/
footnote structures correctly — a fragmented, unofficial ecosystem, not a maintained
conversion layer comparable to `@tiptap/markdown` (see
[tiptap-research.md](tiptap-research.md)).

### 3. Clipboard/paste HTML handling

Allowlist/matcher-based, not raw-HTML assignment — a real safety property. `clipboard.ts`
defines a `CLIPBOARD_CONFIG` table of `[selector, matcherFn]` pairs (`matchText`,
`matchBlot`, `matchAttributor`, `matchList`, `matchTable`, etc.). Paste flow:
`onCapturePaste` → `convertHTML` → `DOMParser().parseFromString(html,'text/html')` into a
**detached** Document → `normalizeHTML` (Word/Google-Docs quirk fixes only) →
`traverse()` walks the detached DOM post-order, running matchers per node to build a
`Delta`. Nothing assigns `innerHTML`/`outerHTML` from clipboard content into the live
editor DOM — insertion always goes through `quill.updateContents(delta)` → blot
`create()` calls. Structurally similar in spirit to ProseMirror's `parseDOM` allowlist
model, just less declaratively unified. The one escape hatch is `dangerouslyPasteHTML`
(name says it all) — an explicit opt-in API, not the default paste path.

### 4. Tables — two real, incompatible implementations

`formats/table.ts` + `modules/table.ts`: the **original** table is a literal Blot
hierarchy (`TableContainer`→`TableBody`→`TableRow`→`TableCell`), i.e. real nested
containers, HTML-table-shaped. `modules/tableEmbed.ts`: a **newer, different
architecture** — the whole table is a single embed op whose value is a `TableData` object
(`rows`, `columns`, `cells: Record<string, CellData>` keyed by `"row:col"` identity
strings), with cell content itself a nested Delta. These are genuinely incompatible
parallel systems (no bridging code found) — Quill shipped a second table implementation
rather than fixing the first, likely because blot-based tables interact badly with
contenteditable selection/undo. **Neither model has a column-alignment field anywhere**
— no GFM pipe-table alignment concept exists at all. Both are fundamentally
HTML-table-shaped, not markdown-syntax-shaped; alignment info would need to be invented/
defaulted on export, and `tableEmbed`'s "table-as-opaque-embed-with-nested-Delta" shape is
a real oddity to round-trip to plain markdown.

### 5. Task lists

Confirmed real GFM equivalent: `formats/list.ts` — `list` is a single format whose value
is one of `'ordered'|'bullet'|'checked'|'unchecked'`, stored as a `data-list` DOM
attribute; a click handler toggles `checked`↔`unchecked` directly. Not a separate blot —
an attribute value, the same shape GFM task lists need. The one area where Quill's model
maps cleanly onto markdown.

### 6. Footnotes

Confirmed absent — zero hits for "footnote" across `formats/` and `modules/`.

### 7. Code blocks

`modules/syntax.ts`: highlighting is **not** live-as-you-type by default — debounced via
`initTimer()` (default `interval: 1000`ms), triggered off scroll-optimize events, plus a
`forceNext` flag for immediate re-highlight on explicit language change. "Eventually
highlighted," not synchronous per-keystroke like MarkText's Muya (see
[marktext-muya-research.md](marktext-muya-research.md) §7). Requires `window.hljs`
present or throws — a hard runtime dependency, not bundled.

### 8. Blots vs. ProseMirror nodes

A Blot declares `static blotName`, `static tagName`, and optionally `static
formats(domNode)` for DOM→attribute-value reading; the inverse create/serialize path is
inherited from base classes rather than declared per-format. ProseMirror/Tiptap pairs
`parseDOM` and `toDOM` together on one node spec, and — critically — schema nodes are
recursively composable by construction (a node's `content` expression can nest any other
node), whereas Quill's Container/Block hierarchy uses ad hoc `allowedChildren`/
`requiredContainer` static pairs per blot that must be manually wired for every new
nestable construct. ProseMirror's model is more naturally suited to bolting on a markdown
round-trip layer, precisely because block nesting is already first-class in its schema —
Quill's is retrofit per-blot-pair, and the Delta's flat-run wire format still has to be
reconstituted into a real tree afterward regardless of Blot DOM correctness (the
table/tableEmbed split is itself evidence of this).

### 9. Real-world markdown-editor usage

Not aware (from general knowledge, not this repo) of a shipped, markdown-source-of-truth
note-taking or docs app built on Quill, parallel to jotty-on-Tiptap or MarkText-on-Muya.
Quill's actual track record is rich-text composers for web apps (early Slack message
composer, various CMS/comment editors) — HTML/Delta as the source of truth, not markdown
files. No good counterexample found; stating that plainly rather than guessing one.

### 10. Verdict

**Stay with Tiptap/ProseMirror.** Three independent, compounding reasons: (a) Delta's
wire format is a flat run-list, not a block-nested tree — markdown's actual grammar
(blockquote > table > list > code-block nesting) has to be reconstructed procedurally at
every conversion boundary rather than falling out of the schema, as the list-indent hack
and the table/tableEmbed split both demonstrate; (b) there is no first-party markdown
module at all (only Prism code-highlighting), versus Tiptap's `@tiptap/markdown` doing
direct token↔node conversion — Quill would require building the whole conversion layer
from scratch, with only a thin, unmaintained-looking community-package ecosystem to lean
on; (c) no track record of Quill being used for this exact job, unlike Tiptap/ProseMirror
which has both the first-party markdown package and real prior art (jotty) to learn from.
Quill's Blot/attribute model is a fine rich-text editor architecture, but it is not
markdown-shaped, and adapting it would mean re-deriving block nesting and writing a full
bidirectional markdown converter with no equivalent-quality reference implementation to
build on.

## Implications for this repo's design

No change to the design. This research is a confirmation, not a course-correction — filed
for completeness as the "path considered and rejected," parallel to how
[marktext-muya-research.md](marktext-muya-research.md) confirmed *not* building a
from-scratch engine. The one transferable detail worth remembering if Quill is ever
reconsidered for a *non*-markdown rich-text feature elsewhere in this project: its
clipboard matcher/allowlist model and `dangerouslyPasteHTML` naming convention are a
reasonable pattern for keeping paste-handling safe by construction, same spirit as this
design's own paste-sanitization section.

## Key files read (Quill's repo, not this one)

- `packages/quill/src/core/editor.ts` — Delta assembly, list-nesting reconstruction from
  flat `indent` attributes
- `packages/quill/src/modules/clipboard.ts`,
  `packages/quill/src/modules/normalizeExternalHTML/index.ts` — paste/HTML-to-Delta
  conversion
- `packages/quill/src/formats/table.ts`, `packages/quill/src/modules/table.ts`,
  `packages/quill/src/modules/tableEmbed.ts` — the two incompatible table
  implementations
- `packages/quill/src/formats/list.ts` — task-list (`checked`/`unchecked`) attribute
  values
- `packages/quill/src/modules/syntax.ts` — Prism/highlight.js code-block highlighting
  (debounced, not live-as-you-type)
- `packages/quill/src/formats/header.ts`, `packages/quill/src/formats/blockquote.ts` —
  representative Blot declarations
- `packages/quill/package.json`, `LICENSE` — BSD-3-Clause confirmation
