import Heading from '@tiptap/extension-heading'

/**
 * Splits a heading's raw markdown-inline source into its visible text and an
 * optional trailing `{#custom-id}` attribute.
 *
 * Mirrors `rust/markdown_vault/src/outline.rs`'s `split_heading_attributes`
 * byte-for-byte (same last-`{#`-then-must-end-in-`}` rule) so a heading's
 * explicit id parses identically on both sides — see invariant #8 in
 * CLAUDE.md and `.claude/docs/live-preview-editing-research.md`. If either
 * side changes, port the change to the other and re-check both test suites.
 */
export function splitHeadingAttributes(text: string): [string, string | null] {
  const open = text.lastIndexOf('{#')
  if (open === -1) return [text, null]
  if (!text.trimEnd().endsWith('}')) return [text, null]
  const close = text.lastIndexOf('}')
  const id = text.slice(open + 2, close).trim()
  return [text.slice(0, open).trim(), id]
}

/**
 * `{#custom-id}` heading anchors are not standard CommonMark/GFM and have no
 * reference implementation anywhere researched (jotty, MarkText/Muya, or
 * Tiptap's own `extension-table-of-contents` — all auto-slug only). This
 * extension is genuinely uncharted territory; keep it isolated so it's easy
 * to iterate on independently of the rest of the schema.
 */
export const HeadingWithId = Heading.extend({
  addAttributes() {
    return {
      ...this.parent?.(),
      id: {
        default: null,
        rendered: false,
      },
    }
  },

  parseMarkdown: (token, helpers) => {
    // `token.text` is the heading's raw inline source (before marked's own
    // inline tokenization) — strip a trailing `{#id}` from it ourselves and
    // re-tokenize the remainder, since by the time a token reaches us its
    // `.tokens` would otherwise still include the literal `{#id}` text.
    const raw = String(token.text ?? '')
    const [text, id] = splitHeadingAttributes(raw)
    const inlineTokens = helpers.tokenizeInline?.(text) ?? []
    return helpers.createNode(
      'heading',
      { level: token.depth || 1, id },
      helpers.parseInline(inlineTokens),
    )
  },

  renderMarkdown: (node, h) => {
    const level = node.attrs?.level ? Number.parseInt(String(node.attrs.level), 10) : 1
    const headingChars = '#'.repeat(level)
    const body = node.content ? h.renderChildren(node.content) : ''
    const id = node.attrs?.id
    return id ? `${headingChars} ${body} {#${id}}` : `${headingChars} ${body}`
  },
})
