import type { Editor } from '@tiptap/core'
import { computed, onScopeDispose, shallowRef } from 'vue'
import type { ActiveBlock, ActiveMark, EditorToolbarState } from '../bridge/nativeBridge'

const MARKS: readonly ActiveMark[] = ['bold', 'italic', 'strike', 'code']
const BLOCKS: readonly ActiveBlock[] = ['blockquote', 'bulletList', 'orderedList', 'taskList', 'codeBlock']
const HEADING_LEVELS = [1, 2, 3, 4, 5, 6] as const

/**
 * Reactive `EditorToolbarState` for a native formatting toolbar, recomputed on every
 * editor transaction. Installs its own `'transaction'` listener rather than sharing
 * `useEditorOutline`'s — kept as a genuinely separate, independently-testable composable
 * (mirroring `useEditorOutline`'s own shape) rather than coupling the two; the extra
 * listener is a cheap, well-supported ProseMirror/Tiptap pattern (`useEditorOutline`
 * already does the same thing for its own concern), and this composable's caller
 * (`WysiwygEditor.vue`) is the one responsible for deduping actual bridge calls, not this
 * composable itself.
 *
 * `mode` is passed as a getter (not a plain value) so it can point at reactive state (a
 * prop, a ref) owned outside the editor — `App.vue`'s `mode` ref, in practice — and still
 * participate in this computed's reactivity.
 */
export function useEditorToolbarState(editor: Editor, mode: () => 'reading' | 'edit') {
  const version = shallowRef(0)
  const bump = () => {
    version.value += 1
  }
  editor.on('transaction', bump)
  onScopeDispose(() => editor.off('transaction', bump))

  return computed<EditorToolbarState>(() => {
    void version.value // establishes the reactive dependency `bump` drives
    const currentMode = mode()

    return {
      mode: currentMode,
      isEditable: currentMode === 'edit',
      activeMarks: MARKS.filter((mark) => editor.isActive(mark)),
      headingLevel: HEADING_LEVELS.find((level) => editor.isActive('heading', { level })) ?? null,
      activeBlock: BLOCKS.find((block) => editor.isActive(block)) ?? null,
      linkActive: editor.isActive('link'),
      canUndo: editor.can().undo(),
      canRedo: editor.can().redo(),
    }
  })
}
