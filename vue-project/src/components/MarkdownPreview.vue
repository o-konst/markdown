<script setup lang="ts">
defineProps<{
  /** HTML fragment produced by the Rust backend. */
  html: string
  isEmpty: boolean
}>()
</script>

<template>
  <article v-if="isEmpty" class="empty">Nothing to preview yet.</article>
  <!-- Trusted content: produced by the Rust renderer from the user's own document. -->
  <article v-else class="markdown-body" v-html="html" />
</template>

<style scoped>
.markdown-body {
  line-height: 1.65;
  overflow-wrap: anywhere;
}

.empty {
  color: var(--color-text);
  opacity: 0.5;
  font-style: italic;
}

.markdown-body :deep(h1),
.markdown-body :deep(h2),
.markdown-body :deep(h3),
.markdown-body :deep(h4) {
  color: var(--color-heading);
  line-height: 1.25;
  margin: 1.6em 0 0.6em;
}

/* Keeps a heading off the top edge when the outline scrolls to it. */
.markdown-body :deep(:is(h1, h2, h3, h4, h5, h6)) {
  scroll-margin-top: 1rem;
}

.markdown-body :deep(h1) {
  font-size: 1.9em;
  margin-top: 0;
}

.markdown-body :deep(h2) {
  font-size: 1.45em;
  border-bottom: 1px solid var(--color-border);
  padding-bottom: 0.2em;
}

.markdown-body :deep(p),
.markdown-body :deep(ul),
.markdown-body :deep(ol),
.markdown-body :deep(blockquote),
.markdown-body :deep(table) {
  margin: 0 0 1em;
}

.markdown-body :deep(ul),
.markdown-body :deep(ol) {
  padding-left: 1.4em;
}

.markdown-body :deep(li) {
  margin: 0.25em 0;
}

.markdown-body :deep(blockquote) {
  border-left: 3px solid var(--color-border-hover);
  padding: 0.1em 0 0.1em 1em;
  color: var(--color-text);
  opacity: 0.85;
}

.markdown-body :deep(code) {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.9em;
  background: var(--color-background-mute);
  border-radius: 4px;
  padding: 0.15em 0.35em;
}

.markdown-body :deep(pre) {
  background: var(--color-background-mute);
  border-radius: 8px;
  padding: 0.9em 1em;
  overflow-x: auto;
  margin: 0 0 1em;
}

.markdown-body :deep(pre code) {
  background: none;
  padding: 0;
}

.markdown-body :deep(table) {
  border-collapse: collapse;
  width: 100%;
}

.markdown-body :deep(th),
.markdown-body :deep(td) {
  border: 1px solid var(--color-border);
  padding: 0.4em 0.7em;
  text-align: left;
}

.markdown-body :deep(th) {
  background: var(--color-background-soft);
}

.markdown-body :deep(img) {
  max-width: 100%;
}

.markdown-body :deep(hr) {
  border: none;
  border-top: 1px solid var(--color-border);
  margin: 2em 0;
}

.markdown-body :deep(.raw-source) {
  white-space: pre-wrap;
}

.markdown-body :deep(input[type='checkbox']) {
  margin-right: 0.4em;
}
</style>
