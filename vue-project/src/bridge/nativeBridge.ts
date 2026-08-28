/**
 * Bridge to the native host (Swift) and, through it, to the Rust `markdown_core` library.
 *
 * Messages travel over a `WKScriptMessageHandlerWithReply`, so `postMessage` resolves
 * with the host's answer. When the app runs in a plain browser (`vite dev`) the bridge
 * reports itself as unavailable and callers fall back to a local preview.
 */

const HANDLER_NAME = 'markdownBridge'

/** How wide the rendered document is allowed to run. */
export const CONTENT_WIDTHS = ['full', 'page'] as const
export type ContentWidth = (typeof CONTENT_WIDTHS)[number]

/** Rendering options owned by the host's settings window. */
export interface WebPreferences {
  outlineVisible: boolean
  contentWidth: ContentWidth
  fontSize: number
}

export const DEFAULT_PREFERENCES: WebPreferences = {
  outlineVisible: true,
  contentWidth: 'full',
  fontSize: 16,
}

const MIN_FONT_SIZE = 11
const MAX_FONT_SIZE = 24

/**
 * Picks the recognised options out of a host payload, ignoring anything unexpected, so a
 * host on a different version cannot put the UI into a nonsense state.
 */
export function normalizePreferences(raw: unknown): Partial<WebPreferences> {
  if (typeof raw !== 'object' || raw === null) return {}
  const source = raw as Record<string, unknown>
  const preferences: Partial<WebPreferences> = {}

  if (typeof source.outlineVisible === 'boolean') {
    preferences.outlineVisible = source.outlineVisible
  }
  if (CONTENT_WIDTHS.includes(source.contentWidth as ContentWidth)) {
    preferences.contentWidth = source.contentWidth as ContentWidth
  }
  if (typeof source.fontSize === 'number' && Number.isFinite(source.fontSize)) {
    preferences.fontSize = Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, source.fontSize))
  }
  return preferences
}

/** Host information returned by the `connect` handshake. */
export interface HostInfo {
  /** Version of the Rust core library. */
  coreVersion: string
  /** Number of web UI files compiled into the Rust library. */
  assetCount: number
  /** Document text at the time of connecting. */
  text: string
  /**
   * Rendering options as of the handshake. Absent on hosts without a settings window
   * (including the Windows app), where {@link DEFAULT_PREFERENCES} applies.
   */
  preferences?: unknown
}

/** Marks the formatting toolbar can toggle — the ones this schema actually has. */
export type ActiveMark = 'bold' | 'italic' | 'strike' | 'code'

/** Mutually-exclusive block types the formatting toolbar can toggle. */
export type ActiveBlock = 'blockquote' | 'bulletList' | 'orderedList' | 'taskList' | 'codeBlock'

/**
 * Snapshot of the editor's current selection/mode, for a native formatting toolbar to
 * render active/disabled button state from — see the "Native SwiftUI formatting toolbar"
 * phase of `.claude/plans/live-preview-editing-plan.md`.
 */
export interface EditorToolbarState {
  mode: 'reading' | 'edit'
  /** `mode === 'edit'`. Native additionally factors in its own Source-view toggle, which
   * this side has no visibility into. */
  isEditable: boolean
  activeMarks: ActiveMark[]
  headingLevel: number | null
  activeBlock: ActiveBlock | null
  linkActive: boolean
  canUndo: boolean
  canRedo: boolean
}

type HostRequest =
  | { method: 'connect' }
  | { method: 'render'; markdown: string }
  | { method: 'outlineState'; available: boolean }
  | { method: 'documentEdit'; text: string }
  | { method: 'editorStateChanged'; state: EditorToolbarState }
  | { method: 'importAsset'; filename: string; contentBase64: string }

/** Reply to an `importAsset` request — where the file landed, and its detected MIME type. */
export interface ImportedAsset {
  path: string
  mime: string
}

/**
 * Methods the host calls on the web UI. Each is installed by its own subscriber, so all
 * are optional and callers must use `?.()`.
 */
export interface MarkdownHost {
  setDocument?(text: string): void
  setPreferences?(preferences: unknown): void
  /**
   * Native → JS, the opposite direction of `documentEdit`: asks the WYSIWYG editor to
   * report its current text immediately, cancelling any pending debounce, and resolves
   * with what it flushed. Native calls this (via `callAsyncJavaScript`, same pattern as
   * `setDocument`'s push) before switching the open file — a debounced edit that hasn't
   * reported yet would otherwise be lost, since native reads `text` synchronously at that
   * point. Installed by `useWysiwygDocument`, not a multi-subscriber event like
   * `setDocument`/`setPreferences` — there's exactly one owner.
   */
  flushPendingEdit?(): Promise<string>
  /**
   * Native → JS: runs a formatting command (`toggleBold`, `setHeading`, `setMode`, etc. —
   * see `editor/formatCommands.ts`) against the live WYSIWYG editor and returns whether it
   * succeeded. Installed by `useWysiwygDocument`, single-owner like `flushPendingEdit`.
   * Synchronous (Tiptap's `chain().run()` already is) — `callAsyncJavaScript` on the native
   * side can await a synchronous return just as well as a promise.
   */
  runEditorCommand?(command: string, payload?: unknown): boolean
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, { postMessage(body: unknown): Promise<unknown> }>
    }
    /** Shared object the host pushes updates through. */
    __markdownHost?: MarkdownHost
  }
}

function messageHandler() {
  return window.webkit?.messageHandlers?.[HANDLER_NAME]
}

/** True when running inside the native web view. */
export function isNativeHost(): boolean {
  return Boolean(messageHandler())
}

async function send<T>(request: HostRequest): Promise<T> {
  const handler = messageHandler()
  if (!handler) {
    throw new Error('Native bridge unavailable')
  }
  return (await handler.postMessage(request)) as T
}

/** Handshake: announces the web UI is mounted and asks for the current document. */
export function connect(): Promise<HostInfo> {
  return send<HostInfo>({ method: 'connect' })
}

/** Renders Markdown to HTML using the Rust backend. */
export function render(markdown: string): Promise<string> {
  return send<string>({ method: 'render', markdown })
}

/**
 * Subscribes to document updates pushed by the host.
 * Returns an unsubscribe function.
 */
export function onDocumentChange(listener: (text: string) => void): () => void {
  const host = (window.__markdownHost ??= {})
  const previous = host.setDocument
  const setDocument = (text: string) => {
    previous?.(text)
    listener(text)
  }
  host.setDocument = setDocument
  return () => {
    if (host.setDocument === setDocument) host.setDocument = previous
  }
}

/**
 * Subscribes to rendering options pushed by the host, whose settings window owns them.
 * Returns an unsubscribe function.
 */
export function onPreferencesChange(
  listener: (preferences: Partial<WebPreferences>) => void,
): () => void {
  const host = (window.__markdownHost ??= {})
  const previous = host.setPreferences
  const setPreferences = (raw: unknown) => {
    previous?.(raw)
    listener(normalizePreferences(raw))
  }
  host.setPreferences = setPreferences
  return () => {
    if (host.setPreferences === setPreferences) host.setPreferences = previous
  }
}

/**
 * Tells the host whether this document has an outline, so its settings window can enable or
 * disable the toggle. Hosts without outline support answer `Unknown bridge method`, which is
 * expected rather than an error worth surfacing.
 */
export async function reportOutlineState(available: boolean): Promise<void> {
  if (!isNativeHost()) return
  try {
    await send({ method: 'outlineState', available })
  } catch {
    // Host predates the outline; it has no toggle to keep in sync.
  }
}

/**
 * Reports an edit made in the WYSIWYG editor back to the host, so it flows through the
 * existing autosave/vault-write machinery (see the "Bridge" section of
 * `.claude/docs/live-preview-editing-research.md`). No reply payload — an ack, like
 * {@link reportOutlineState}. Hosts that predate WYSIWYG editing answer `Unknown bridge
 * method`, which is expected rather than an error worth surfacing.
 *
 * Deliberately undebounced here: this function is a dumb transport, same as every other
 * method in this file. Whatever calls it (see `useWysiwygDocument`) decides its own
 * timing — including firing it un-debounced on the first keystroke of a typing burst, so
 * the host's unsaved-changes flag flips before a slower, debounced steady-state report
 * would otherwise leave a race window open against a concurrent external write.
 */
export async function reportEdit(text: string): Promise<void> {
  if (!isNativeHost()) return
  try {
    await send({ method: 'documentEdit', text })
  } catch {
    // Host predates WYSIWYG editing; it has nothing to receive this into.
  }
}

/**
 * Reports the formatting toolbar's current state (active marks, heading level, mode,
 * undo/redo availability, ...) so a native toolbar can render pressed/disabled buttons.
 * No reply payload — an ack, like {@link reportOutlineState}/{@link reportEdit}. Hosts
 * that predate the formatting toolbar answer `Unknown bridge method`, expected rather
 * than an error worth surfacing.
 */
export async function reportEditorState(state: EditorToolbarState): Promise<void> {
  if (!isNativeHost()) return
  try {
    await send({ method: 'editorStateChanged', state })
  } catch {
    // Host predates the formatting toolbar; it has nothing to receive this into.
  }
}

/**
 * Copies a dropped/pasted file's content into the vault's `assets` folder (see
 * `markdown_vault`'s `import_asset` tool), returning the vault-relative path it landed at
 * and its detected MIME type. Unlike the ack-only `report*` calls above, the caller needs
 * this result (or its rejection) to decide what to insert into the document — so, like
 * {@link render}, this does not swallow errors or gate on {@link isNativeHost}.
 */
export function importAsset(filename: string, contentBase64: string): Promise<ImportedAsset> {
  return send<ImportedAsset>({ method: 'importAsset', filename, contentBase64 })
}

/**
 * Browser-only preview used when the Rust backend is not reachable.
 * Deliberately dumb: real rendering is the Rust library's job.
 */
export function renderFallback(markdown: string): string {
  const escaped = markdown.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  return `<pre class="raw-source">${escaped}</pre>`
}
