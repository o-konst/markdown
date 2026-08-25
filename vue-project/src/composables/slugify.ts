/**
 * Turns heading text into a URL fragment.
 *
 * Mirrors `rust/markdown_vault/src/outline.rs`'s `slugify` byte-for-byte — see CLAUDE.md
 * invariant #8. Both {@link ../composables/useDocumentOutline} (Reading view, walks
 * rendered HTML) and {@link ../composables/useEditorOutline} (WYSIWYG view, walks the
 * live Tiptap doc) share this one implementation so search-result anchors and preview
 * anchors never disagree. If this changes, port the change to the Rust side too and
 * re-check both test suites.
 */
export function slugify(text: string): string {
  return text
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '')
}
