import { Editor } from '@tiptap/core'
import { EditorState } from '@tiptap/pm/state'

import { onDocumentChange as bridgeOnDocumentChange, reportEdit as bridgeReportEdit } from '../bridge/nativeBridge'
import { createExtensions } from './schema'

/** Debounce for steady-state edit reporting — independent of native's own 800ms autosave/disk-write debounce (see the Bridge section of `.claude/docs/live-preview-editing-research.md`). */
const EDIT_DEBOUNCE_MS = 200

export interface WysiwygDocumentOptions {
  /**
   * Where to mount the editor's DOM. Defaults to a detached `<div>` (created but never
   * appended to the page) when omitted — **not** to Tiptap's own `element: null` mode,
   * which skips `createView()` entirely and leaves the editor with zero ProseMirror
   * plugins attached (no history, no input rules, no keymaps — confirmed by reading
   * `@tiptap/core`'s `mount()`/constructor source directly). A detached element still
   * runs `createView()`, so every plugin behaves normally; it's just invisible until (or
   * unless) something appends it to the DOM. Pass a real, page-attached element (e.g.
   * from a component's template ref) to make the editor visible.
   */
  element?: HTMLElement
  initialText?: string
  editDebounceMs?: number
  /** Overridable for tests; defaults to the real bridge in {@link ../bridge/nativeBridge}. */
  reportEdit?: (text: string) => Promise<void>
  onDocumentChange?: (listener: (text: string) => void) => () => void
}

export interface WysiwygDocument {
  editor: Editor
  /** Forces immediate serialization + report, cancelling any pending debounce. Native must await this before switching the open file, or trailing keystrokes can be lost. */
  flushPendingEdit: () => Promise<string>
  /** Detaches the bridge subscription and destroys the editor. Call from the owning component's `onBeforeUnmount` — not wired to Vue lifecycle here so this composable stays usable outside a component (e.g. in tests). */
  dispose: () => void
}

/**
 * Owns a Tiptap editor over the Phase-0 schema and keeps it in sync with the native host
 * over the bridge, in both directions:
 *
 * - **Outbound**: every edit is reported via {@link bridgeReportEdit}, un-debounced on the
 *   first keystroke of a burst (so native's unsaved-changes flag flips immediately — see
 *   the "Race condition" note in the research doc) and debounced thereafter.
 * - **Inbound**: subscribes to {@link bridgeOnDocumentChange} and applies a pushed
 *   document only when it's genuinely external — i.e. the incoming text actually differs
 *   from what this editor would itself serialize right now. Every push this composable
 *   ever receives is, by construction (once native's own echo-suppression guard from
 *   Phase 3/4 lands), already guaranteed external; this is a second, independent guard,
 *   not redundant with it. Applying an external push also resets undo/redo history —
 *   `setContent` alone does not clear it — so Cmd+Z can never walk back into content from
 *   before a chat-agent revert or watcher reload.
 */
export function useWysiwygDocument(options: WysiwygDocumentOptions = {}): WysiwygDocument {
  const debounceMs = options.editDebounceMs ?? EDIT_DEBOUNCE_MS
  const reportEdit = options.reportEdit ?? bridgeReportEdit
  const subscribeToDocumentChange = options.onDocumentChange ?? bridgeOnDocumentChange

  const editor = new Editor({
    element: options.element ?? document.createElement('div'),
    extensions: createExtensions(),
    content: options.initialText ?? '',
    contentType: 'markdown',
    onUpdate: () => scheduleReport(),
  })

  let debounceTimer: ReturnType<typeof setTimeout> | undefined
  let burstInFlight = false

  function clearPendingDebounce() {
    if (debounceTimer !== undefined) {
      clearTimeout(debounceTimer)
      debounceTimer = undefined
    }
    burstInFlight = false
  }

  function scheduleReport() {
    if (!burstInFlight) {
      // First keystroke of a burst: report immediately, undebounced.
      burstInFlight = true
      void reportEdit(editor.getMarkdown())
    }
    if (debounceTimer !== undefined) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      burstInFlight = false
      debounceTimer = undefined
      void reportEdit(editor.getMarkdown())
    }, debounceMs)
  }

  async function flushPendingEdit(): Promise<string> {
    clearPendingDebounce()
    const text = editor.getMarkdown()
    await reportEdit(text)
    return text
  }

  function applyExternalText(text: string) {
    const current = editor.getMarkdown()
    if (text === current) return

    clearPendingDebounce()
    editor.commands.setContent(text, { contentType: 'markdown', emitUpdate: false })
    resetHistory(editor)
  }

  const unsubscribe = subscribeToDocumentChange(applyExternalText)

  function dispose() {
    unsubscribe()
    clearPendingDebounce()
    editor.destroy()
  }

  return { editor, flushPendingEdit, dispose }
}

/**
 * Clears ProseMirror's undo/redo stacks by rebuilding the editor's `EditorState` via
 * `EditorState.create` (which re-`init`s every plugin, including `prosemirror-history`,
 * from scratch) instead of `state.apply(tr)` (which carries plugin state, including
 * history, forward). `prosemirror-history` exposes no direct "clear" API — this is the
 * standard ProseMirror-ecosystem technique for resetting it. Preserves the current
 * document and plugin set; only the undo/redo stacks are discarded.
 */
function resetHistory(editor: Editor): void {
  const { state } = editor.view
  const freshState = EditorState.create({
    schema: state.schema,
    doc: state.doc,
    plugins: state.plugins,
  })
  editor.view.updateState(freshState)
}
