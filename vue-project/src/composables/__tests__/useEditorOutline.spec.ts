import { describe, expect, it } from 'vitest'

import { parseMarkdownToDoc } from '../../editor/schema'
import { buildOutlineFromDoc } from '../useEditorOutline'

/**
 * Mirrors `rust/markdown_vault/src/outline.rs`'s test module case-for-case (same inputs,
 * same expected ids) — CLAUDE.md invariant #8 requires the two sides to agree, so these
 * are ported rather than independently authored. Rust's own line-number/fenced-code-block
 * cases aren't ported: `line` isn't part of `OutlineNode`, and there's no equivalent of "a
 * heading inside a fenced code block" in a parsed doc — a code block's content is never
 * parsed back into heading nodes in the first place, so that failure mode can't occur
 * here. That's a real, structural difference between the two implementations, not a
 * quietly-accepted divergence: flagging it rather than pretending an equivalent test
 * exists.
 */
describe('buildOutlineFromDoc / rust outline.rs parity', () => {
  it('numbers duplicate headings', () => {
    const doc = parseMarkdownToDoc('## Overview\n\n## Overview\n\n## Overview\n')
    expect(buildOutlineFromDoc(doc).ids).toEqual(['overview', 'overview-2', 'overview-3'])
  })

  it('honours an author-supplied anchor and strips it from the heading text', () => {
    const doc = parseMarkdownToDoc('## Custom Anchor {#my-anchor}\n')
    const outline = buildOutlineFromDoc(doc)
    expect(outline.ids).toEqual(['my-anchor'])
    expect(outline.nodes[0]?.text).toBe('Custom Anchor')
  })

  it('falls back to its position when a heading has no slug (emoji-only text)', () => {
    const doc = parseMarkdownToDoc('# 🎉\n')
    expect(buildOutlineFromDoc(doc).ids).toEqual(['section-1'])
  })

  it('nests headings by comparing levels, tolerating skipped levels', () => {
    const doc = parseMarkdownToDoc('# One\n\n### Three\n\n## Two\n')
    const outline = buildOutlineFromDoc(doc)
    // "One" (h1) is the only top-level node: "Three" (h3, skips h2) nests under it since
    // no shallower-or-equal heading appears first, and "Two" (h2) *also* nests under
    // "One" — popping the ancestor *stack* down past "Three" (3 >= 2) doesn't remove
    // "Three" from "One"'s already-recorded `children`, it only stops comparing against
    // it for what nests next. Same behavior as `useDocumentOutline.ts`'s DOM version and
    // `outline.rs`, both of which nest this way too (see the reference-document case
    // below, which relies on the identical "sibling headings both end up under the same
    // ancestor" behavior for its two "Overview" headings).
    expect(outline.nodes).toHaveLength(1)
    expect(outline.nodes[0]?.id).toBe('one')
    expect(outline.nodes[0]?.children.map((n) => n.id)).toEqual(['three', 'two'])
  })

  it('matches the reference document from outline.rs (matches_the_previews_outline_for_the_reference_document)', () => {
    const markdown =
      '# Getting Started\n\n## Overview\n\n### Deep detail\n\n#### Deeper still\n\n' +
      '##### Five\n\n###### Six\n\n## Overview\n\n## Custom Anchor {#my-anchor}\n\n' +
      '# 🎉\n\n### Skipped level under h1\n'

    const doc = parseMarkdownToDoc(markdown)
    expect(buildOutlineFromDoc(doc).ids).toEqual([
      'getting-started',
      'overview',
      'deep-detail',
      'deeper-still',
      'five',
      'six',
      'overview-2',
      'my-anchor',
      'section-9',
      'skipped-level-under-h1',
    ])
  })
})
