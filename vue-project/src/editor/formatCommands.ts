import type { Editor } from '@tiptap/core'

/**
 * Native → JS command dispatch for the formatting toolbar (see the "Native SwiftUI
 * formatting toolbar" phase of `.claude/plans/live-preview-editing-plan.md`). Installed as
 * `window.__markdownHost.runEditorCommand` by `useWysiwygDocument`; this module is the
 * pure lookup table it delegates to, kept separate so it's testable without touching the
 * bridge/global-object plumbing.
 *
 * `setMode` is the one command that doesn't touch the editor at all — mode is Vue state
 * owned by `App.vue`, not part of this schema, so it goes through the `onSetMode` callback
 * instead of a Tiptap chain call.
 */

type Level = 1 | 2 | 3 | 4 | 5 | 6
const HEADING_LEVELS: readonly Level[] = [1, 2, 3, 4, 5, 6]

function isHeadingLevel(value: unknown): value is Level {
  return typeof value === 'number' && (HEADING_LEVELS as readonly number[]).includes(value)
}

/**
 * Inserts a footnote reference at the cursor and, if no definition with this label exists
 * yet, appends an empty definition for it at the end of the document. `footnoteExtension.ts`
 * defines the two node types but no insertion command of its own (an atom reference plus a
 * possibly-new block definition isn't a single-node concern) — this is that command,
 * living here instead, run as one chained transaction so it's atomic (and one undo step).
 */
function insertFootnote(editor: Editor, label: string): boolean {
  if (!label) return false

  let hasDefinition = false
  editor.state.doc.descendants((node) => {
    if (node.type.name === 'footnoteDefinition' && node.attrs.label === label) {
      hasDefinition = true
    }
  })

  const chain = editor.chain().focus().insertContent({ type: 'footnoteReference', attrs: { label } })

  if (!hasDefinition) {
    chain.insertContentAt(editor.state.doc.content.size, {
      type: 'footnoteDefinition',
      attrs: { label },
      content: [{ type: 'paragraph' }],
    })
  }

  return chain.run()
}

export function runFormatCommand(
  editor: Editor,
  command: string,
  payload: unknown,
  onSetMode: (mode: 'reading' | 'edit') => void,
): boolean {
  const p = (payload ?? {}) as Record<string, unknown>

  switch (command) {
    case 'toggleBold':
      return editor.chain().focus().toggleBold().run()
    case 'toggleItalic':
      return editor.chain().focus().toggleItalic().run()
    case 'toggleStrike':
      return editor.chain().focus().toggleStrike().run()
    case 'toggleCode':
      return editor.chain().focus().toggleCode().run()

    case 'setHeading': {
      if (p.level == null) return editor.chain().focus().setParagraph().run()
      if (!isHeadingLevel(p.level)) return false
      return editor.chain().focus().toggleHeading({ level: p.level }).run()
    }

    case 'toggleBlockquote':
      return editor.chain().focus().toggleBlockquote().run()
    case 'toggleBulletList':
      return editor.chain().focus().toggleBulletList().run()
    case 'toggleOrderedList':
      return editor.chain().focus().toggleOrderedList().run()
    case 'toggleTaskList':
      return editor.chain().focus().toggleTaskList().run()
    case 'toggleCodeBlock':
      return editor.chain().focus().toggleCodeBlock().run()
    case 'setHorizontalRule':
      return editor.chain().focus().setHorizontalRule().run()

    case 'toggleLink': {
      const href = typeof p.href === 'string' ? p.href.trim() : ''
      return href
        ? editor.chain().focus().extendMarkRange('link').toggleLink({ href }).run()
        : editor.chain().focus().extendMarkRange('link').unsetLink().run()
    }

    case 'setImage': {
      const src = typeof p.src === 'string' ? p.src.trim() : ''
      if (!src) return false
      const alt = typeof p.alt === 'string' ? p.alt : undefined
      return editor.chain().focus().setImage({ src, alt }).run()
    }

    case 'insertFootnote': {
      const label = typeof p.label === 'string' ? p.label.trim() : ''
      return insertFootnote(editor, label)
    }

    case 'setMode': {
      if (p.mode !== 'reading' && p.mode !== 'edit') return false
      onSetMode(p.mode)
      return true
    }

    default:
      return false
  }
}
