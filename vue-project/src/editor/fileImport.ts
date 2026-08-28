import type { Editor } from '@tiptap/core'
import type { EditorView } from '@tiptap/pm/view'

import { importAsset as bridgeImportAsset, type ImportedAsset } from '../bridge/nativeBridge'

/**
 * Drag-and-drop / paste file import (see `.claude/plans/drag-drop-attachments-plan.md`).
 *
 * No native (Swift/C#) drop-handling code is involved: WKWebView/WebView2 both deliver a
 * drop over their own content as an ordinary DOM `drop` event, which ProseMirror's
 * `editorProps.handleDrop` intercepts before the outer native window's own whole-window
 * drop handler (which still only opens folders/Markdown files as documents) ever sees it.
 */

/** Matches `markdown_vault::store::MAX_ASSET_BYTES` — reject oversized files before ever
 * base64-encoding them and round-tripping through the bridge. */
export const MAX_IMPORT_BYTES = 25 * 1024 * 1024

export interface ImportDependencies {
  importAsset: (filename: string, contentBase64: string) => Promise<ImportedAsset>
}

const defaultDependencies: ImportDependencies = { importAsset: bridgeImportAsset }

/**
 * Pure content builder: an image node for an image MIME type (rendered inline via the
 * WebView's vault-asset fallback — see the plan), otherwise a link-marked text run reading
 * the original file name (opened externally by the host on click, not navigated in-page).
 */
export function buildInsertionContent(mime: string, path: string, filename: string) {
  if (mime.startsWith('image/')) {
    return { type: 'image', attrs: { src: path, alt: filename } }
  }
  return {
    type: 'text',
    text: filename,
    marks: [{ type: 'link', attrs: { href: path } }],
  }
}

function toBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  const chunkSize = 0x8000 // avoids a call-stack blowout from spreading a huge array at once
  let binary = ''
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize))
  }
  return btoa(binary)
}

/**
 * Imports one dropped/pasted `File` into the vault and inserts the resulting content at
 * `pos`. Failure (oversize, or the bridge call itself rejecting) is logged and otherwise
 * silent for v1 — no toast/error UI yet, a documented limitation, not an oversight.
 */
export async function importFileAt(
  editor: Editor,
  file: File,
  pos: number,
  deps: ImportDependencies = defaultDependencies,
): Promise<void> {
  if (file.size > MAX_IMPORT_BYTES) {
    console.error(
      `"${file.name}" is ${file.size} bytes, over the ${MAX_IMPORT_BYTES}-byte import limit — not imported.`,
    )
    return
  }

  let asset: ImportedAsset
  try {
    const contentBase64 = toBase64(await file.arrayBuffer())
    asset = await deps.importAsset(file.name, contentBase64)
  } catch (err) {
    console.error(`Failed to import "${file.name}":`, err)
    return
  }

  // Display the name the file actually landed under (sanitized by `import_asset`, see
  // `sanitize_filename` in store.rs), not the original `file.name` — otherwise the link/alt
  // text disagrees with the path it points at.
  const displayName = asset.path.split('/').pop() ?? file.name

  editor
    .chain()
    .focus()
    .insertContentAt(pos, buildInsertionContent(asset.mime, asset.path, displayName))
    .run()
}

function filesFrom(dataTransfer: DataTransfer | null | undefined): File[] {
  return dataTransfer?.files?.length ? Array.from(dataTransfer.files) : []
}

/**
 * Builds the `editorProps.handleDrop`/`handlePaste` pair for a Tiptap `Editor`. `getEditor`
 * is a lazy accessor rather than a direct `Editor` reference because `editorProps` must be
 * supplied to the `Editor` constructor before the `Editor` instance it belongs to exists —
 * the accessor is only ever invoked from an event handler, by which point construction has
 * finished. Only the first dropped/pasted file is handled, matching this codebase's existing
 * `providers.first`/`items[0]` convention for the native whole-window drop handlers.
 */
export function createFileImportHandlers(
  getEditor: () => Editor,
  deps: ImportDependencies = defaultDependencies,
) {
  function handleDrop(view: EditorView, event: DragEvent, _slice: unknown, moved: boolean): boolean {
    if (moved) return false // an internal drag-reorder, not an external file drop
    const [file] = filesFrom(event.dataTransfer)
    if (!file) return false

    event.preventDefault()
    const coords = view.posAtCoords({ left: event.clientX, top: event.clientY })
    void importFileAt(getEditor(), file, coords?.pos ?? view.state.selection.from, deps)
    return true
  }

  function handlePaste(view: EditorView, event: ClipboardEvent): boolean {
    const [file] = filesFrom(event.clipboardData)
    if (!file) return false

    event.preventDefault()
    void importFileAt(getEditor(), file, view.state.selection.from, deps)
    return true
  }

  return { handleDrop, handlePaste }
}
