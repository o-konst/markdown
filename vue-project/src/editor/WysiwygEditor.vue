<script setup lang="ts">
import { EditorContent } from '@tiptap/vue-3'
import { nextTick, onBeforeUnmount, ref, watch } from 'vue'

import { useEditorOutline } from '../composables/useEditorOutline'
import TableControls from './TableControls.vue'
import { useWysiwygDocument } from './useWysiwygDocument'

/**
 * The Typora-style WYSIWYG editing surface (`.claude/docs/live-preview-editing-research.md`).
 * Constructed once per component instance over a detached `<div>` (see
 * `useWysiwygDocument`'s default) — `<EditorContent>` relocates that already-created DOM
 * into its own template slot on mount, so construction doesn't need to wait for a
 * template ref to exist first.
 */
const props = defineProps<{
  /** Current document text. Applied once immediately (seeding from the initial `connect()`
   * handshake, which arrives here rather than via the bridge's `onDocumentChange` push —
   * see `useWysiwygDocument`'s `applyExternalText` doc comment) and again on every
   * subsequent change, through the same guarded, history-resetting path bridge pushes use. */
  initialText: string
}>()

const doc = useWysiwygDocument({ initialText: props.initialText })
const outline = useEditorOutline(doc.editor)

const contentRoot = ref<HTMLElement | null>(null)

watch(
  () => props.initialText,
  (text) => doc.applyExternalText(text),
)

// Stamps outline ids onto the actual rendered heading DOM elements, mirroring
// `useDocumentOutline.ts`'s `buildOutline` (which mutates ids directly onto parsed HTML).
// Only explicit `{#id}` headings carry an id in the doc model itself — auto-slugged ones
// exist only in this computed outline, so the sidebar's anchor-scrolling needs them
// stamped on somewhere real.
watch(
  () => outline.ids.value,
  (ids) => {
    void nextTick(() => {
      const root = contentRoot.value
      if (!root) return
      const headings = root.querySelectorAll<HTMLElement>('h1, h2, h3, h4, h5, h6')
      headings.forEach((heading, index) => {
        const id = ids[index]
        if (id) heading.id = id
      })
    })
  },
  { immediate: true, flush: 'post' },
)

onBeforeUnmount(() => doc.dispose())

defineExpose({
  editor: doc.editor,
  nodes: outline.nodes,
  ids: outline.ids,
  hasOutline: outline.hasOutline,
  flushPendingEdit: doc.flushPendingEdit,
})
</script>

<template>
  <div ref="contentRoot" class="wysiwyg-editor">
    <TableControls :editor="doc.editor" />
    <EditorContent :editor="doc.editor" class="wysiwyg-editor__content" />
  </div>
</template>

<style scoped>
.wysiwyg-editor {
  line-height: 1.65;
  overflow-wrap: anywhere;
}

.wysiwyg-editor__content :deep(.ProseMirror) {
  outline: none;
}

.wysiwyg-editor__content :deep(:is(h1, h2, h3, h4, h5, h6)) {
  color: var(--color-heading);
  line-height: 1.25;
  margin: 1.6em 0 0.6em;
  scroll-margin-top: 1rem;
}

.wysiwyg-editor__content :deep(h1) {
  font-size: 1.9em;
  margin-top: 0;
}

.wysiwyg-editor__content :deep(h2) {
  font-size: 1.45em;
  border-bottom: 1px solid var(--color-border);
  padding-bottom: 0.2em;
}

.wysiwyg-editor__content :deep(p),
.wysiwyg-editor__content :deep(ul),
.wysiwyg-editor__content :deep(ol),
.wysiwyg-editor__content :deep(blockquote),
.wysiwyg-editor__content :deep(table) {
  margin: 0 0 1em;
}

.wysiwyg-editor__content :deep(ul),
.wysiwyg-editor__content :deep(ol) {
  padding-left: 1.4em;
}

.wysiwyg-editor__content :deep(li) {
  margin: 0.25em 0;
}

.wysiwyg-editor__content :deep(blockquote) {
  border-left: 3px solid var(--color-border-hover);
  padding: 0.1em 0 0.1em 1em;
  color: var(--color-text);
  opacity: 0.85;
}

.wysiwyg-editor__content :deep(code) {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.9em;
  background: var(--color-background-mute);
  border-radius: 4px;
  padding: 0.15em 0.35em;
}

.wysiwyg-editor__content :deep(pre) {
  background: var(--color-background-mute);
  border-radius: 8px;
  padding: 0.9em 1em;
  overflow-x: auto;
  margin: 0 0 1em;
}

.wysiwyg-editor__content :deep(pre code) {
  background: none;
  padding: 0;
}

.wysiwyg-editor__content :deep(table) {
  border-collapse: collapse;
  width: 100%;
}

.wysiwyg-editor__content :deep(th),
.wysiwyg-editor__content :deep(td) {
  border: 1px solid var(--color-border);
  padding: 0.4em 0.7em;
  text-align: left;
}

.wysiwyg-editor__content :deep(th) {
  background: var(--color-background-soft);
}

.wysiwyg-editor__content :deep(img) {
  max-width: 100%;
}

.wysiwyg-editor__content :deep(hr) {
  border: none;
  border-top: 1px solid var(--color-border);
  margin: 2em 0;
}

.wysiwyg-editor__content :deep(ul[data-type='taskList']) {
  list-style: none;
  padding-left: 0.4em;
}

.wysiwyg-editor__content :deep(ul[data-type='taskList'] li) {
  display: flex;
  align-items: flex-start;
  gap: 0.4em;
}
</style>
