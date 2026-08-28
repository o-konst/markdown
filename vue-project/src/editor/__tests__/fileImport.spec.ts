// @vitest-environment happy-dom
import type { EditorView } from '@tiptap/pm/view'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { useWysiwygDocument, type WysiwygDocument } from '../useWysiwygDocument'
import { buildInsertionContent, createFileImportHandlers, importFileAt, MAX_IMPORT_BYTES } from '../fileImport'

function fakeFile(name: string, content: string, type: string): File {
  return new File([content], name, { type })
}

describe('buildInsertionContent', () => {
  it('builds an image node for an image MIME type', () => {
    expect(buildInsertionContent('image/png', 'assets/photo.png', 'photo.png')).toEqual({
      type: 'image',
      attrs: { src: 'assets/photo.png', alt: 'photo.png' },
    })
  })

  it('builds a link-marked text run for a non-image MIME type', () => {
    expect(buildInsertionContent('application/pdf', 'assets/report.pdf', 'report.pdf')).toEqual({
      type: 'text',
      text: 'report.pdf',
      marks: [{ type: 'link', attrs: { href: 'assets/report.pdf' } }],
    })
  })
})

describe('importFileAt', () => {
  let doc: WysiwygDocument | undefined

  afterEach(() => {
    doc?.dispose()
    doc = undefined
  })

  it('imports a dropped image and inserts it at the given position', async () => {
    doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })
    const importAsset = vi.fn().mockResolvedValue({ path: 'assets/photo.png', mime: 'image/png' })

    await importFileAt(doc.editor, fakeFile('photo.png', 'bytes', 'image/png'), 0, { importAsset })

    expect(importAsset).toHaveBeenCalledWith('photo.png', expect.any(String))
    let sawImage = false
    doc.editor.state.doc.descendants((node) => {
      if (node.type.name === 'image') {
        sawImage = true
        expect(node.attrs.src).toBe('assets/photo.png')
      }
    })
    expect(sawImage).toBe(true)
  })

  it('imports a dropped non-image file as a link', async () => {
    doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })
    const importAsset = vi.fn().mockResolvedValue({ path: 'assets/report.pdf', mime: 'application/pdf' })

    await importFileAt(doc.editor, fakeFile('report.pdf', 'bytes', 'application/pdf'), 0, { importAsset })

    expect(doc.editor.getMarkdown()).toContain('[report.pdf](assets/report.pdf)')
  })

  it('displays the sanitized name the bridge returned, not the original file name', async () => {
    doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })
    const importAsset = vi.fn().mockResolvedValue({ path: 'assets/my_photo_(3).png', mime: 'image/png' })

    await importFileAt(doc.editor, fakeFile('my photo (3).png', 'bytes', 'image/png'), 0, { importAsset })

    let alt: string | undefined
    doc.editor.state.doc.descendants((node) => {
      if (node.type.name === 'image') alt = node.attrs.alt
    })
    expect(alt).toBe('my_photo_(3).png')
  })

  it('rejects an oversized file without calling the bridge', async () => {
    doc = useWysiwygDocument({ initialText: 'Hello', reportEdit: vi.fn() })
    const importAsset = vi.fn()
    const big = new File([new Uint8Array(MAX_IMPORT_BYTES + 1)], 'big.bin')

    await importFileAt(doc.editor, big, 0, { importAsset })

    expect(importAsset).not.toHaveBeenCalled()
    expect(doc.editor.getMarkdown()).toBe('Hello')
  })

  it('leaves the document unchanged when the bridge import fails', async () => {
    doc = useWysiwygDocument({ initialText: 'Hello', reportEdit: vi.fn() })
    const importAsset = vi.fn().mockRejectedValue(new Error('native import failed'))

    await importFileAt(doc.editor, fakeFile('photo.png', 'bytes', 'image/png'), 0, { importAsset })

    expect(doc.editor.getMarkdown()).toBe('Hello')
  })
})

describe('createFileImportHandlers', () => {
  let doc: WysiwygDocument | undefined

  afterEach(() => {
    doc?.dispose()
    doc = undefined
  })

  function fakeView(): EditorView {
    return {
      posAtCoords: () => ({ pos: 0, inside: -1 }),
      state: { selection: { from: 0 } },
    } as unknown as EditorView
  }

  it('handleDrop defers to ProseMirror default when the drop is an internal move', () => {
    const importAsset = vi.fn()
    const { handleDrop } = createFileImportHandlers(() => doc!.editor, { importAsset })
    const event = { dataTransfer: { files: [fakeFile('a.png', 'x', 'image/png')] }, preventDefault: vi.fn() }

    const handled = handleDrop(fakeView(), event as unknown as DragEvent, undefined, /* moved */ true)

    expect(handled).toBe(false)
    expect(event.preventDefault).not.toHaveBeenCalled()
    expect(importAsset).not.toHaveBeenCalled()
  })

  it('handleDrop ignores a drop carrying no files', () => {
    const importAsset = vi.fn()
    const { handleDrop } = createFileImportHandlers(() => doc!.editor, { importAsset })
    const event = { dataTransfer: { files: [] }, preventDefault: vi.fn() }

    const handled = handleDrop(fakeView(), event as unknown as DragEvent, undefined, false)

    expect(handled).toBe(false)
    expect(importAsset).not.toHaveBeenCalled()
  })

  it('handleDrop consumes a real file drop and imports it', async () => {
    doc = useWysiwygDocument({ initialText: '', reportEdit: vi.fn() })
    const importAsset = vi.fn().mockResolvedValue({ path: 'assets/photo.png', mime: 'image/png' })
    const { handleDrop } = createFileImportHandlers(() => doc!.editor, { importAsset })
    const event = {
      dataTransfer: { files: [fakeFile('photo.png', 'bytes', 'image/png')] },
      preventDefault: vi.fn(),
      clientX: 0,
      clientY: 0,
    }

    const handled = handleDrop(fakeView(), event as unknown as DragEvent, undefined, false)
    expect(handled).toBe(true)
    expect(event.preventDefault).toHaveBeenCalled()

    await vi.waitFor(() => expect(importAsset).toHaveBeenCalledWith('photo.png', expect.any(String)))
  })

  it('handlePaste consumes a pasted file and imports it', async () => {
    doc = useWysiwygDocument({ initialText: '', reportEdit: vi.fn() })
    const importAsset = vi.fn().mockResolvedValue({ path: 'assets/photo.png', mime: 'image/png' })
    const { handlePaste } = createFileImportHandlers(() => doc!.editor, { importAsset })
    const event = { clipboardData: { files: [fakeFile('photo.png', 'bytes', 'image/png')] }, preventDefault: vi.fn() }

    const handled = handlePaste(fakeView(), event as unknown as ClipboardEvent)
    expect(handled).toBe(true)

    await vi.waitFor(() => expect(importAsset).toHaveBeenCalled())
  })

  it('handlePaste ignores a paste carrying no files (ordinary text paste)', () => {
    const importAsset = vi.fn()
    const { handlePaste } = createFileImportHandlers(() => doc!.editor, { importAsset })
    const event = { clipboardData: { files: [] }, preventDefault: vi.fn() }

    const handled = handlePaste(fakeView(), event as unknown as ClipboardEvent)

    expect(handled).toBe(false)
    expect(importAsset).not.toHaveBeenCalled()
  })
})
