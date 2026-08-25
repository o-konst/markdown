import { Node, mergeAttributes } from '@tiptap/core'
import type { MarkdownToken } from '@tiptap/core'

/**
 * Footnotes (`[^label]` references, `[^label]: ...` definitions) have no
 * built-in support in `@tiptap/markdown` or anywhere else researched except
 * MarkText's Muya (`.claude/docs/marktext-muya-research.md` §5), whose
 * 4-space continuation-indent serialization rule this follows.
 *
 * Two nodes: an inline atom reference and a top-level block definition, each
 * registering its own `markdownTokenizer` into the shared `marked` lexer
 * `@tiptap/markdown` drives, following `@tiptap/extension-table`'s pattern
 * (a custom tokenizer + `parseMarkdown`/`renderMarkdown`).
 */

const REFERENCE_RE = /^\[\^([^\]\s]+)\](?!:)/
const DEFINITION_START_RE = /^\[\^([^\]\s]+)\]:/m
const DEFINITION_FIRST_LINE_RE = /^\[\^([^\]\s]+)\]:[ \t]?(.*)$/

export const FootnoteReference = Node.create({
  name: 'footnoteReference',
  group: 'inline',
  inline: true,
  atom: true,

  addAttributes() {
    return {
      label: { default: null },
    }
  },

  parseHTML() {
    return [{ tag: 'span[data-footnote-reference]' }]
  },

  renderHTML({ node, HTMLAttributes }) {
    return [
      'sup',
      mergeAttributes(HTMLAttributes, {
        'data-footnote-reference': '',
        'data-label': node.attrs.label,
      }),
      `[^${node.attrs.label}]`,
    ]
  },

  markdownTokenizer: {
    name: 'footnoteReference',
    level: 'inline',
    start(src: string) {
      const match = REFERENCE_RE.exec(src)
      return match ? match.index : -1
    },
    tokenize(src: string) {
      const match = REFERENCE_RE.exec(src)
      if (!match) return undefined
      return {
        type: 'footnoteReference',
        raw: match[0],
        label: match[1],
      } as MarkdownToken
    },
  },

  parseMarkdown: (token, helpers) => {
    return helpers.createNode('footnoteReference', { label: token.label })
  },

  renderMarkdown: (node) => {
    return `[^${node.attrs?.label}]`
  },
})

export const FootnoteDefinition = Node.create({
  name: 'footnoteDefinition',
  group: 'block',
  content: 'block+',
  isolating: true,

  addAttributes() {
    return {
      label: { default: null },
    }
  },

  parseHTML() {
    return [{ tag: 'div[data-footnote-definition]' }]
  },

  renderHTML({ node, HTMLAttributes }) {
    return [
      'div',
      mergeAttributes(HTMLAttributes, {
        'data-footnote-definition': '',
        'data-label': node.attrs.label,
      }),
      0,
    ]
  },

  markdownTokenizer: {
    name: 'footnoteDefinition',
    level: 'block',
    start(src: string) {
      const match = DEFINITION_START_RE.exec(src)
      return match ? match.index : -1
    },
    tokenize(src: string, _tokens: MarkdownToken[], helper: { blockTokens: (s: string) => MarkdownToken[] }) {
      const lines = src.split('\n')
      const firstLine = lines[0] ?? ''
      const match = DEFINITION_FIRST_LINE_RE.exec(firstLine)
      if (!match) return undefined

      const label = match[1]
      const bodyLines: string[] = [match[2] ?? '']
      let consumed = 1

      for (let i = 1; i < lines.length; i += 1) {
        const line = lines[i] ?? ''
        if (line.trim() === '') {
          const next = lines[i + 1]
          // A blank line only continues the definition if what follows is
          // itself indented — otherwise it terminates the definition, same
          // as a blank line ending any other CommonMark container.
          if (next !== undefined && /^ {4}/.test(next)) {
            bodyLines.push('')
            consumed += 1
            continue
          }
          break
        }
        if (/^ {4}/.test(line)) {
          bodyLines.push(line.slice(4))
          consumed += 1
          continue
        }
        break
      }

      const raw = lines.slice(0, consumed).join('\n') + (consumed < lines.length ? '\n' : '')
      const bodyText = bodyLines.join('\n').replace(/\n+$/, '')
      const blockTokens = helper.blockTokens(bodyText)

      return {
        type: 'footnoteDefinition',
        raw,
        label,
        tokens: blockTokens,
      } as MarkdownToken
    },
  },

  parseMarkdown: (token, helpers) => {
    return helpers.createNode(
      'footnoteDefinition',
      { label: token.label },
      helpers.parseBlockChildren?.(token.tokens || []) ?? [],
    )
  },

  renderMarkdown: (node, h) => {
    const label = node.attrs?.label
    if (!label) return ''
    const body = node.content ? h.renderChildren(node.content, '\n\n') : ''
    const lines = body.split('\n')
    const first = lines[0] ?? ''
    const rest = lines.slice(1).map((line) => (line.length ? `    ${line}` : ''))
    return [`[^${label}]: ${first}`, ...rest].join('\n')
  },
})
