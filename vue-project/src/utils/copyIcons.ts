/**
 * Inline SVG markup for the code-block copy button, shared between the WYSIWYG editor's
 * `CodeBlockView.vue` node view and Reading view's imperatively-stamped button in
 * `MarkdownPreview.vue` — one visual source of truth instead of duplicating the glyph, and
 * no icon library dependency for two icons.
 */
export const COPY_ICON_SVG =
  '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" ' +
  'stroke-width="1.4" aria-hidden="true"><rect x="5" y="5" width="9" height="9" rx="1.5"/>' +
  '<path d="M3.5 10.5h-1a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v1"/></svg>'

export const CHECK_ICON_SVG =
  '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" ' +
  'stroke-width="1.6" aria-hidden="true"><path d="M3 8.5l3 3 7-7" stroke-linecap="round" ' +
  'stroke-linejoin="round"/></svg>'
