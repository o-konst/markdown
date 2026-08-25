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

type HostRequest =
  | { method: 'connect' }
  | { method: 'render'; markdown: string }
  | { method: 'outlineState'; available: boolean }
  | { method: 'documentEdit'; text: string }

/**
 * Methods the host calls on the web UI. Each is installed by its own subscriber, so all
 * are optional and callers must use `?.()`.
 */
export interface MarkdownHost {
  setDocument?(text: string): void
  setPreferences?(preferences: unknown): void
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
 * Browser-only preview used when the Rust backend is not reachable.
 * Deliberately dumb: real rendering is the Rust library's job.
 */
export function renderFallback(markdown: string): string {
  const escaped = markdown.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  return `<pre class="raw-source">${escaped}</pre>`
}
