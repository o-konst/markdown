import { onBeforeUnmount, onMounted, readonly, ref } from 'vue'
import {
  connect,
  DEFAULT_PREFERENCES,
  isNativeHost,
  normalizePreferences,
  onDocumentChange,
  onPreferencesChange,
  render,
  renderFallback,
  type WebPreferences,
} from '@/bridge/nativeBridge'

export type BridgeStatus = 'connecting' | 'connected' | 'standalone' | 'error'

/** Shown by `vite dev`, where there is no document and no Rust renderer. */
const STANDALONE_SAMPLE = [
  '# Markdown preview',
  '',
  'Running outside the macOS app, so the Rust renderer is not available.',
  'Open the document in the Markdown app to see rendered output.',
].join('\n')

/**
 * Keeps the rendered preview in sync with the document owned by the native app.
 *
 * The Markdown itself is converted by the Rust core library; this composable only
 * shuttles text to the host and HTML back, discarding replies that arrive out of order.
 */
export function useMarkdownPreview() {
  const html = ref('')
  const source = ref('')
  const status = ref<BridgeStatus>('connecting')
  const coreVersion = ref('')
  const assetCount = ref(0)
  const error = ref<string | null>(null)
  /** Owned by the host's settings window; defaults apply to hosts that have none. */
  const preferences = ref<WebPreferences>({ ...DEFAULT_PREFERENCES })

  let latestRequest = 0
  /** True once the host has pushed a document, which outranks the handshake's copy. */
  let hasPushedDocument = false
  let disposeListener: (() => void) | null = null
  let disposePreferencesListener: (() => void) | null = null

  async function update(text: string) {
    source.value = text
    const request = ++latestRequest

    if (!isNativeHost()) {
      html.value = renderFallback(text)
      return
    }

    try {
      const rendered = await render(text)
      // A newer document arrived while we were waiting: drop this stale result.
      if (request !== latestRequest) return
      html.value = rendered
      error.value = null
    } catch (cause) {
      if (request !== latestRequest) return
      error.value = cause instanceof Error ? cause.message : String(cause)
      status.value = 'error'
      html.value = renderFallback(text)
    }
  }

  onMounted(async () => {
    disposeListener = onDocumentChange((text) => {
      hasPushedDocument = true
      void update(text)
    })
    disposePreferencesListener = onPreferencesChange((update) => {
      preferences.value = { ...preferences.value, ...update }
    })

    if (!isNativeHost()) {
      status.value = 'standalone'
      await update(STANDALONE_SAMPLE)
      return
    }

    try {
      const info = await connect()
      coreVersion.value = info.coreVersion
      assetCount.value = info.assetCount
      status.value = 'connected'
      preferences.value = { ...preferences.value, ...normalizePreferences(info.preferences) }
      // `info.text` is the document as of the handshake. If the host pushed a newer one
      // while `connect` was in flight, seeding from the handshake would undo it.
      if (!hasPushedDocument) {
        await update(info.text)
      }
    } catch (cause) {
      error.value = cause instanceof Error ? cause.message : String(cause)
      status.value = 'error'
    }
  })

  onBeforeUnmount(() => {
    disposeListener?.()
    disposeListener = null
    disposePreferencesListener?.()
    disposePreferencesListener = null
  })

  return {
    html: readonly(html),
    source: readonly(source),
    status: readonly(status),
    coreVersion: readonly(coreVersion),
    assetCount: readonly(assetCount),
    error: readonly(error),
    preferences: readonly(preferences),
    update,
  }
}
