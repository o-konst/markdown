// @vitest-environment happy-dom
import { afterEach, describe, expect, it } from 'vitest'

import { useWysiwygDocument, type WysiwygDocument } from '../useWysiwygDocument'

/**
 * Verifies (rather than re-asserts unverified) the two paste-safety claims from
 * `.claude/docs/live-preview-editing-research.md`'s "Paste handling / sanitization"
 * section. `insertContent` with an HTML string goes through the same schema-based
 * `parseHTML`/DOM-parsing path a real paste event's HTML payload would (Tiptap's
 * clipboard handler converts pasted HTML to a ProseMirror slice via the same schema
 * parser) — a direct, legitimate way to test this without fabricating a full
 * `ClipboardEvent`/`DataTransfer` pipeline.
 */
describe('paste safety', () => {
  let doc: WysiwygDocument | undefined

  afterEach(() => {
    doc?.dispose()
    doc = undefined
  })

  it('rejects a javascript: link href pasted as HTML', () => {
    doc = useWysiwygDocument({ reportEdit: async () => {} })
    doc.editor.commands.insertContent('<p><a href="javascript:alert(1)">click</a></p>')

    let sawLinkMark = false
    doc.editor.state.doc.descendants((node) => {
      const link = node.marks.find((mark) => mark.type.name === 'link')
      if (link) {
        sawLinkMark = true
        expect(String(link.attrs.href)).not.toMatch(/^javascript:/i)
      }
    })
    // If no link mark exists at all, the href was rejected outright rather than merely
    // neutralized — also an acceptable, safe outcome.
    expect(doc.editor.getMarkdown()).not.toContain('javascript:')
    void sawLinkMark
  })

  it('rejects a vbscript: link href pasted as HTML', () => {
    doc = useWysiwygDocument({ reportEdit: async () => {} })
    doc.editor.commands.insertContent('<p><a href="vbscript:msgbox(1)">click</a></p>')

    doc.editor.state.doc.descendants((node) => {
      const link = node.marks.find((mark) => mark.type.name === 'link')
      if (link) expect(String(link.attrs.href)).not.toMatch(/^vbscript:/i)
    })
    expect(doc.editor.getMarkdown()).not.toContain('vbscript:')
  })

  it('still accepts an ordinary https: link href pasted as HTML', () => {
    // Guards against a trivial "reject everything" implementation passing the two tests
    // above for the wrong reason.
    doc = useWysiwygDocument({ reportEdit: async () => {} })
    doc.editor.commands.insertContent('<p><a href="https://example.com">click</a></p>')

    let href: unknown
    doc.editor.state.doc.descendants((node) => {
      const link = node.marks.find((mark) => mark.type.name === 'link')
      if (link) href = link.attrs.href
    })
    expect(href).toBe('https://example.com')
  })

  it('does NOT validate the scheme of a pasted image src (confirmed, not just assumed)', () => {
    // Per the research doc: `<img src>` doesn't execute script in browsers regardless of
    // scheme, so this is documented as low-risk-as-is, not a gap to close here. This test
    // pins that behavior down so a future change to `@tiptap/extension-image` (or to this
    // schema) that silently starts/stops validating it doesn't go unnoticed.
    doc = useWysiwygDocument({ reportEdit: async () => {} })
    doc.editor.commands.insertContent('<img src="javascript:alert(1)" alt="x">')

    let src: unknown
    doc.editor.state.doc.descendants((node) => {
      if (node.type.name === 'image') src = node.attrs.src
    })
    expect(src).toBe('javascript:alert(1)') // unvalidated — confirmed, tracked, not a regression
  })
})
