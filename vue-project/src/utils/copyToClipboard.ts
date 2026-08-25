/**
 * Copies text to the clipboard, tolerating environments where the Async Clipboard API is
 * unavailable or throws. This app's embedded WebView uses a custom `markdown-app://`
 * scheme rather than `https:` — whether WebKit treats that as a secure context for
 * `navigator.clipboard` (real browsers require one) isn't verified from this environment,
 * so this defends both ways rather than assuming either: try the modern API first, and if
 * it's missing or rejects, fall back to the legacy `execCommand('copy')` path via a
 * temporary offscreen `<textarea>`, which has no secure-context requirement.
 */
export async function copyToClipboard(text: string): Promise<boolean> {
  if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // Fall through to the legacy path below.
    }
  }
  return copyViaExecCommand(text)
}

function copyViaExecCommand(text: string): boolean {
  if (typeof document === 'undefined') return false

  const textarea = document.createElement('textarea')
  textarea.value = text
  textarea.setAttribute('readonly', '')
  // Offscreen, not just invisible — a visible focus flash would be a UI glitch.
  textarea.style.position = 'fixed'
  textarea.style.top = '0'
  textarea.style.left = '-9999px'
  textarea.style.opacity = '0'
  document.body.appendChild(textarea)

  textarea.select()
  textarea.setSelectionRange(0, textarea.value.length)

  let succeeded = false
  try {
    succeeded = document.execCommand('copy')
  } catch {
    succeeded = false
  }

  document.body.removeChild(textarea)
  return succeeded
}
