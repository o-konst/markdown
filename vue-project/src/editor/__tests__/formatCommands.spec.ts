// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest'

import { runFormatCommand } from '../formatCommands'
import { useWysiwygDocument, type WysiwygDocument } from '../useWysiwygDocument'

// Real `Editor` instances throughout (via `useWysiwygDocument`, same as
// `useWysiwygDocument.spec.ts`) rather than mocks — a mock could pass while the actual
// Tiptap command name is wrong, which is exactly the kind of mistake worth catching here.

describe('runFormatCommand', () => {
  let doc: WysiwygDocument | undefined
  const noopSetMode = vi.fn()

  afterEach(() => {
    doc?.dispose()
    doc = undefined
    noopSetMode.mockClear()
  })

  it('toggles bold/italic/strike/code marks', () => {
    doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })
    doc.editor.commands.selectAll()

    expect(runFormatCommand(doc.editor, 'toggleBold', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('bold')).toBe(true)
    expect(runFormatCommand(doc.editor, 'toggleItalic', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('italic')).toBe(true)
    expect(runFormatCommand(doc.editor, 'toggleStrike', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('strike')).toBe(true)

    // Code and bold/italic/strike are mutually exclusive marks in most schemas' input
    // rules, but as *commands* nothing stops both being active at once — just confirm the
    // command itself works, not schema-level exclusivity (not this module's concern).
    expect(runFormatCommand(doc.editor, 'toggleCode', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('code')).toBe(true)
  })

  it('sets a heading level, and clears it back to a paragraph', () => {
    doc = useWysiwygDocument({ initialText: 'A line', reportEdit: vi.fn() })
    doc.editor.commands.setTextSelection(1)

    expect(runFormatCommand(doc.editor, 'setHeading', { level: 2 }, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('heading', { level: 2 })).toBe(true)

    expect(runFormatCommand(doc.editor, 'setHeading', { level: null }, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('paragraph')).toBe(true)
  })

  it('rejects an out-of-range heading level rather than doing something undefined', () => {
    doc = useWysiwygDocument({ initialText: 'A line', reportEdit: vi.fn() })
    expect(runFormatCommand(doc.editor, 'setHeading', { level: 9 }, noopSetMode)).toBe(false)
  })

  it('toggles blockquote, bullet/ordered/task lists, and code blocks', () => {
    doc = useWysiwygDocument({ initialText: 'A line', reportEdit: vi.fn() })

    expect(runFormatCommand(doc.editor, 'toggleBlockquote', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('blockquote')).toBe(true)
    expect(runFormatCommand(doc.editor, 'toggleBlockquote', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('blockquote')).toBe(false)

    expect(runFormatCommand(doc.editor, 'toggleBulletList', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('bulletList')).toBe(true)

    expect(runFormatCommand(doc.editor, 'toggleOrderedList', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('orderedList')).toBe(true)
    expect(doc.editor.isActive('bulletList')).toBe(false)

    expect(runFormatCommand(doc.editor, 'toggleTaskList', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('taskList')).toBe(true)

    expect(runFormatCommand(doc.editor, 'toggleCodeBlock', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('codeBlock')).toBe(true)
  })

  it('inserts a horizontal rule', () => {
    doc = useWysiwygDocument({ initialText: 'A line', reportEdit: vi.fn() })
    expect(runFormatCommand(doc.editor, 'setHorizontalRule', undefined, noopSetMode)).toBe(true)
    expect(doc.editor.getMarkdown()).toContain('---')
  })

  it('applies and removes a link', () => {
    doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })
    doc.editor.commands.selectAll()

    expect(runFormatCommand(doc.editor, 'toggleLink', { href: 'https://example.com' }, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('link')).toBe(true)

    expect(runFormatCommand(doc.editor, 'toggleLink', null, noopSetMode)).toBe(true)
    expect(doc.editor.isActive('link')).toBe(false)
  })

  it('rejects a link with a blank href instead of applying an empty link', () => {
    doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })
    doc.editor.commands.selectAll()
    expect(runFormatCommand(doc.editor, 'toggleLink', { href: '   ' }, noopSetMode)).toBe(true)
    // Falls through to the unset branch rather than creating a link to a blank URL.
    expect(doc.editor.isActive('link')).toBe(false)
  })

  it('inserts an image from a URL', () => {
    doc = useWysiwygDocument({ initialText: '', reportEdit: vi.fn() })
    expect(
      runFormatCommand(doc.editor, 'setImage', { src: 'https://example.com/a.png', alt: 'A' }, noopSetMode),
    ).toBe(true)
    expect(doc.editor.getMarkdown()).toContain('https://example.com/a.png')
  })

  it('rejects an image command with no src', () => {
    doc = useWysiwygDocument({ initialText: '', reportEdit: vi.fn() })
    expect(runFormatCommand(doc.editor, 'setImage', {}, noopSetMode)).toBe(false)
  })

  it('inserts a footnote reference and definition together, only once per label', () => {
    doc = useWysiwygDocument({ initialText: 'A claim.', reportEdit: vi.fn() })
    doc.editor.commands.setTextSelection(doc.editor.state.doc.content.size - 1)

    expect(runFormatCommand(doc.editor, 'insertFootnote', { label: 'note' }, noopSetMode)).toBe(true)
    const afterFirst = doc.editor.getMarkdown()
    expect(afterFirst).toContain('[^note]')
    expect(afterFirst).toContain('[^note]:')

    // A second reference to the SAME label must not duplicate the definition.
    expect(runFormatCommand(doc.editor, 'insertFootnote', { label: 'note' }, noopSetMode)).toBe(true)
    const definitionCount = (doc.editor.getMarkdown().match(/\[\^note\]:/g) ?? []).length
    expect(definitionCount).toBe(1)
  })

  it('rejects a footnote command with no label', () => {
    doc = useWysiwygDocument({ initialText: 'A claim.', reportEdit: vi.fn() })
    expect(runFormatCommand(doc.editor, 'insertFootnote', {}, noopSetMode)).toBe(false)
  })

  it('routes setMode to the callback instead of the editor, and reports success', () => {
    doc = useWysiwygDocument({ initialText: '', reportEdit: vi.fn() })
    expect(runFormatCommand(doc.editor, 'setMode', { mode: 'reading' }, noopSetMode)).toBe(true)
    expect(noopSetMode).toHaveBeenCalledWith('reading')
  })

  it('rejects an invalid setMode payload without calling the callback', () => {
    doc = useWysiwygDocument({ initialText: '', reportEdit: vi.fn() })
    expect(runFormatCommand(doc.editor, 'setMode', { mode: 'nonsense' }, noopSetMode)).toBe(false)
    expect(noopSetMode).not.toHaveBeenCalled()
  })

  it('rejects an unknown command instead of throwing', () => {
    doc = useWysiwygDocument({ initialText: '', reportEdit: vi.fn() })
    expect(runFormatCommand(doc.editor, 'notARealCommand', undefined, noopSetMode)).toBe(false)
  })
})
