import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight'

/**
 * `@tiptap/extension-code-block` (and `-code-block-lowlight`, which inherits
 * its markdown hooks unchanged) always renders a fixed ``` fence regardless
 * of content — confirmed directly in `@tiptap/extension-code-block`'s
 * `renderMarkdown` (node_modules/@tiptap/extension-code-block/dist/index.js).
 * Content containing a run of 3+ backticks would prematurely terminate that
 * fixed fence on the next parse, corrupting the document. Recompute the
 * fence length from the longest backtick run in the content instead (one
 * longer than the longest run, minimum 3) — the same rule MarkText's Muya
 * and `prosemirror-markdown`'s own code-block serializer both use (see
 * `.claude/docs/marktext-muya-research.md` §7 and the Serialize pipeline
 * note in `.claude/docs/live-preview-editing-research.md`).
 */
export const CodeBlockWithFenceLength = CodeBlockLowlight.extend({
  renderMarkdown: (node, h) => {
    const language = node.attrs?.language || ''
    const content = node.content ? h.renderChildren(node.content) : ''
    if (!content) return `\`\`\`${language}\n\n\`\`\``
    const runs = content.match(/`+/g) ?? []
    const longestRun = runs.reduce((max, run) => Math.max(max, run.length), 0)
    const fence = '`'.repeat(Math.max(3, longestRun + 1))
    return [`${fence}${language}`, content, fence].join('\n')
  },
})
