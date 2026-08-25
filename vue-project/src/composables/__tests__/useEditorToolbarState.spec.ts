// @vitest-environment happy-dom
import { effectScope, ref } from 'vue'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { useEditorToolbarState } from '../useEditorToolbarState'
import { useWysiwygDocument, type WysiwygDocument } from '../../editor/useWysiwygDocument'

// Real `Editor` instances (via `useWysiwygDocument`), same style as
// `useEditorOutline.spec.ts` and `formatCommands.spec.ts` — this composable's whole job is
// translating real `editor.isActive(...)`/`editor.can()` calls into a plain object, so a
// mocked editor would test nothing.

describe('useEditorToolbarState', () => {
  let doc: WysiwygDocument | undefined
  let scope: ReturnType<typeof effectScope> | undefined

  afterEach(() => {
    scope?.stop()
    scope = undefined
    doc?.dispose()
    doc = undefined
  })

  function setup(initialText: string, mode: () => 'reading' | 'edit' = () => 'edit') {
    doc = useWysiwygDocument({ initialText, reportEdit: vi.fn() })
    scope = effectScope()
    const state = scope.run(() => useEditorToolbarState(doc!.editor, mode))!
    return state
  }

  it('reports isEditable from the mode getter, not a hardcoded assumption', () => {
    const reading = setup('Hello', () => 'reading')
    expect(reading.value.mode).toBe('reading')
    expect(reading.value.isEditable).toBe(false)
  })

  it('reports isEditable true in edit mode', () => {
    const state = setup('Hello', () => 'edit')
    expect(state.value.isEditable).toBe(true)
  })

  it('reports active marks at the current selection', () => {
    const state = setup('Hello world')
    doc!.editor.commands.selectAll()
    doc!.editor.commands.toggleBold()
    expect(state.value.activeMarks).toContain('bold')
    expect(state.value.activeMarks).not.toContain('italic')
  })

  it('reports the active heading level, or null for a plain paragraph', () => {
    const state = setup('A line')
    expect(state.value.headingLevel).toBeNull()

    doc!.editor.commands.setTextSelection(1)
    doc!.editor.commands.toggleHeading({ level: 3 })
    expect(state.value.headingLevel).toBe(3)
  })

  it('reports the active block type, mutually exclusive with heading/paragraph', () => {
    const state = setup('A line')
    expect(state.value.activeBlock).toBeNull()

    doc!.editor.commands.toggleBulletList()
    expect(state.value.activeBlock).toBe('bulletList')
  })

  it('reports linkActive when the cursor is inside a link', () => {
    const state = setup('Hello world')
    doc!.editor.commands.selectAll()
    doc!.editor.commands.setLink({ href: 'https://example.com' })
    expect(state.value.linkActive).toBe(true)
  })

  it('reports canUndo true only after there is something to undo', () => {
    const state = setup('Hello')
    expect(state.value.canUndo).toBe(false)
    doc!.editor.commands.insertContent(' world')
    expect(state.value.canUndo).toBe(true)
  })

  it('recomputes when an external mode change is the only thing that changed', () => {
    doc = useWysiwygDocument({ initialText: 'Hello', reportEdit: vi.fn() })
    // A real `ref`, not a plain variable: Vue's `computed` only re-runs its getter when a
    // genuinely reactive dependency it read changes — closing over a plain `let` would
    // track nothing, silently pass the first assertion, then fail (or worse, pass for the
    // wrong reason) on the second. This mirrors how `WysiwygEditor.vue` actually calls
    // this composable: `() => props.mode`, where `props` is Vue-reactive.
    const modeRef = ref<'reading' | 'edit'>('reading')
    scope = effectScope()
    const state = scope.run(() => useEditorToolbarState(doc!.editor, () => modeRef.value))!

    expect(state.value.isEditable).toBe(false)
    modeRef.value = 'edit'
    // No editor transaction happened — only the external `mode` getter's own reactive
    // source changed. If this composable only reacted to `editor.on('transaction', ...)`
    // it would (wrongly) keep reporting the stale value.
    expect(state.value.isEditable).toBe(true)
  })
})
