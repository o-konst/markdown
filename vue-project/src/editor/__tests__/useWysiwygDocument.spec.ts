// @vitest-environment happy-dom
import { undoDepth } from '@tiptap/pm/history'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { useWysiwygDocument, type WysiwygDocument } from '../useWysiwygDocument'

// Constructing a real `Editor` needs a DOM (ProseMirror's `EditorView` manipulates real
// nodes even when never attached to the page) — hence the happy-dom environment override
// above, scoped to just this file so the Phase-0 round-trip suite stays on the faster
// plain `node` environment (see vitest.config.ts).

describe('useWysiwygDocument', () => {
  let doc: WysiwygDocument | undefined

  afterEach(() => {
    doc?.dispose()
    doc = undefined
    vi.useRealTimers()
  })

  describe('outbound edit reporting', () => {
    beforeEach(() => {
      vi.useFakeTimers()
    })

    it('reports the first keystroke of a burst immediately, undebounced', () => {
      const reportEdit = vi.fn().mockResolvedValue(undefined)
      doc = useWysiwygDocument({ initialText: 'Hello', reportEdit, editDebounceMs: 200 })

      doc.editor.commands.insertContent(' world')

      expect(reportEdit).toHaveBeenCalledTimes(1)
      expect(reportEdit).toHaveBeenLastCalledWith(doc.editor.getMarkdown())
    })

    it('debounces subsequent edits within the same burst', () => {
      const reportEdit = vi.fn().mockResolvedValue(undefined)
      doc = useWysiwygDocument({ initialText: 'Hello', reportEdit, editDebounceMs: 200 })

      doc.editor.commands.insertContent(' wo')
      expect(reportEdit).toHaveBeenCalledTimes(1) // first keystroke, undebounced

      doc.editor.commands.insertContent('rld')
      expect(reportEdit).toHaveBeenCalledTimes(1) // still within the burst, debounced

      vi.advanceTimersByTime(200)
      expect(reportEdit).toHaveBeenCalledTimes(2) // debounce settles, steady-state report
      expect(reportEdit).toHaveBeenLastCalledWith(doc.editor.getMarkdown())
    })

    it('starts a new undebounced report once a burst has settled', () => {
      const reportEdit = vi.fn().mockResolvedValue(undefined)
      doc = useWysiwygDocument({ initialText: 'Hello', reportEdit, editDebounceMs: 200 })

      doc.editor.commands.insertContent(' world')
      vi.advanceTimersByTime(200)
      expect(reportEdit).toHaveBeenCalledTimes(2)

      doc.editor.commands.insertContent('!')
      expect(reportEdit).toHaveBeenCalledTimes(3) // new burst -> immediate report again
    })

    it('flushPendingEdit cancels the pending debounce and reports immediately', async () => {
      const reportEdit = vi.fn().mockResolvedValue(undefined)
      doc = useWysiwygDocument({ initialText: 'Hello', reportEdit, editDebounceMs: 200 })

      doc.editor.commands.insertContent(' world')
      expect(reportEdit).toHaveBeenCalledTimes(1)

      const flushed = await doc.flushPendingEdit()
      expect(flushed).toBe(doc.editor.getMarkdown())
      expect(reportEdit).toHaveBeenCalledTimes(2)

      // The debounced report that would otherwise have fired must not double-report.
      vi.advanceTimersByTime(200)
      expect(reportEdit).toHaveBeenCalledTimes(2)
    })
  })

  describe('inbound external pushes', () => {
    afterEach(() => {
      // `onDocumentChange` patches this global; make sure a failed test can't leak a
      // stale listener into the next one.
      delete window.__markdownHost
    })

    it('ignores a pushed document identical to what the editor would itself serialize', () => {
      doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })
      const current = doc.editor.getMarkdown()

      const stateBefore = doc.editor.state
      window.__markdownHost?.setDocument?.(current)

      expect(doc.editor.state).toBe(stateBefore) // no transaction was applied at all
    })

    it('applies a genuinely different pushed document and resets undo history', () => {
      doc = useWysiwygDocument({ initialText: 'Hello world', reportEdit: vi.fn() })

      // Build up real undo history before the external push arrives.
      doc.editor.commands.insertContent(' — edited locally')
      expect(undoDepth(doc.editor.state)).toBeGreaterThan(0)

      window.__markdownHost?.setDocument?.('Replaced entirely from outside.')

      expect(doc.editor.getMarkdown()).toBe('Replaced entirely from outside.')
      expect(undoDepth(doc.editor.state)).toBe(0)
    })

    it('cancels a pending debounced report when an external push arrives mid-burst', () => {
      vi.useFakeTimers()
      const reportEdit = vi.fn().mockResolvedValue(undefined)
      doc = useWysiwygDocument({ initialText: 'Hello', reportEdit, editDebounceMs: 200 })

      doc.editor.commands.insertContent(' world')
      expect(reportEdit).toHaveBeenCalledTimes(1)

      window.__markdownHost?.setDocument?.('Replaced entirely from outside.')
      vi.advanceTimersByTime(200)

      // Only the undebounced first-keystroke report fired; the debounced follow-up for
      // the since-discarded local edit must not fire after an external replace.
      expect(reportEdit).toHaveBeenCalledTimes(1)
    })
  })
})
