import { Editor } from '@tiptap/vue-3'
import { history } from '@tiptap/pm/history'

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
  /**
   * Applies a full-document replacement — same guarded, history-resetting path the
   * bridge's `onDocumentChange` pushes go through. Exposed publicly so the owning
   * component can also feed it the initial handshake-delivered document (which arrives
   * via `connect()`'s reply, not `onDocumentChange` — see `useMarkdownPreview`), through
   * the same safe, idempotent function rather than a separate one-off "seed" path.
   */
  applyExternalText: (text: string) => void
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

  // Exposes `flushPendingEdit` on the same global native pushes arrive through, so native
  // can call it directly (`window.__markdownHost?.flushPendingEdit?.()` over
  // `callAsyncJavaScript`) before switching the open file — see the `MarkdownHost`
  // interface doc comment in `nativeBridge.ts`. Single-owner, unlike `setDocument`'s
  // multi-subscriber chain, so a plain assign/restore is enough.
  const host = (window.__markdownHost ??= {})
  const previousFlush = host.flushPendingEdit
  host.flushPendingEdit = flushPendingEdit

  function dispose() {
    unsubscribe()
    if (host.flushPendingEdit === flushPendingEdit) host.flushPendingEdit = previousFlush
    clearPendingDebounce()
    editor.destroy()
  }

  return { editor, flushPendingEdit, applyExternalText, dispose }
}

/**
 * Clears ProseMirror's undo/redo stacks by unregistering the `prosemirror-history`
 * plugin and registering a fresh instance — `state.reconfigure()` (which
 * `editor.unregisterPlugin`/`registerPlugin` both use) `init()`s any plugin that wasn't
 * in the previous plugin list, giving the new instance empty done/undone stacks, while
 * every other plugin's state carries forward unchanged. `prosemirror-history` exposes no
 * direct "clear" API — this is the standard ProseMirror-ecosystem technique.
 *
 * Deliberately goes through `editor.unregisterPlugin`/`registerPlugin` rather than
 * calling `editor.view.updateState()` directly: `@tiptap/vue-3`'s `Editor` subclass
 * tracks state in a separate Vue `customRef` (`reactiveState`) that only that subclass's
 * overridden `registerPlugin`/`unregisterPlugin` (and its own transaction pipeline) know
 * to update — a raw `view.updateState()` call bypasses it, leaving `editor.state` (the
 * getter callers actually read) stale even though the real view state changed. Confirmed
 * by a failing test before this fix: `undoDepth(editor.state)` still read the pre-reset
 * depth despite the view itself having been reset correctly underneath it.
 *
 * `history` is registered with `prosemirror-history`'s own defaults (`depth: 100,
 * newGroupDelay: 500`), matching what `@tiptap/extensions`' `UndoRedo` extension (part of
 * `StarterKit`, unconfigured in this schema) itself uses.
 */
function resetHistory(editor: Editor): void {
  editor.unregisterPlugin('history')
  editor.registerPlugin(history())
}
