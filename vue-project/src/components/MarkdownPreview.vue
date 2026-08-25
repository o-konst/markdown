<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import { copyToClipboard } from '../utils/copyToClipboard'
import { CHECK_ICON_SVG, COPY_ICON_SVG } from '../utils/copyIcons'

const props = defineProps<{
  /** HTML fragment produced by the Rust backend. */
  html: string
  isEmpty: boolean
}>()

const body = ref<HTMLElement | null>(null)

/**
 * `v-html` content can't have a real Vue-managed button inside it — same imperative-DOM
 * approach `useDocumentOutline.ts` uses for heading ids, applied here instead of there
 * because a copy button needs a live click handler, not just a string attribute a
 * `DOMParser`+serialize round-trip could bake in. `v-html` fully replaces the container's
 * innerHTML on every change, so stale buttons from a previous render are already gone by
 * the time this runs again — no manual cleanup needed before re-stamping.
 */
watch(
  () => props.html,
  () => {
    void nextTick(() => {
      const root = body.value
      if (!root) return
      root.querySelectorAll<HTMLElement>('pre').forEach(stampCopyButton)
    })
  },
  { immediate: true, flush: 'post' },
)

function stampCopyButton(pre: HTMLElement) {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'markdown-body__copy'
  button.setAttribute('aria-label', 'Copy code')
  button.innerHTML = COPY_ICON_SVG

  let resetTimer: ReturnType<typeof setTimeout> | undefined
  button.addEventListener('click', () => {
    void copyToClipboard(pre.textContent ?? '').then((ok) => {
      if (!ok) return
      button.innerHTML = CHECK_ICON_SVG
      button.setAttribute('aria-label', 'Copied')
      button.classList.add('markdown-body__copy--copied')
      if (resetTimer) clearTimeout(resetTimer)
      resetTimer = setTimeout(() => {
        button.innerHTML = COPY_ICON_SVG
        button.setAttribute('aria-label', 'Copy code')
        button.classList.remove('markdown-body__copy--copied')
      }, 1500)
    })
  })

  pre.appendChild(button)
}
</script>

<template>
  <article v-if="isEmpty" class="empty">Nothing to preview yet.</article>
  <!-- Trusted content: produced by the Rust renderer from the user's own document. -->
  <article v-else ref="body" class="markdown-body" v-html="html" />
</template>

<style scoped>
.markdown-body {
  line-height: 1.5;
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

.markdown-body :deep(:is(h1, h2, h3, h4, h5, h6)) {
  /* `base.css` resets `font-weight: normal` on every element, which would otherwise flatten
     headings to the same weight as body text. */
  font-weight: 600;
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

.markdown-body :deep(strong) {
  /* Same `base.css` reset — without this, `**bold**` renders visually identical to plain
     text, since the browser's default `strong { font-weight: bolder }` never applies. */
  font-weight: 700;
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
  position: relative;
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

.markdown-body :deep(.markdown-body__copy) {
  position: absolute;
  top: 0.5em;
  right: 0.5em;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  padding: 0;
  border: 1px solid var(--color-border);
  border-radius: 6px;
  background: var(--color-background);
  color: var(--color-text);
  opacity: 0;
  cursor: pointer;
  transition: opacity 0.12s ease;
}

.markdown-body :deep(pre:hover .markdown-body__copy),
.markdown-body :deep(.markdown-body__copy:focus-visible) {
  opacity: 1;
}

.markdown-body :deep(.markdown-body__copy--copied) {
  opacity: 1;
  color: #2da44e;
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
  /* `em` sizing alone is unreliable here: WebKit's native checkbox often doesn't visually
     honor `width`/`height` on the control even though the layout box does resize — a
     known cross-browser quirk. `transform: scale()` resizes the actually-rendered pixels
     regardless, so it's the primary mechanism; `width`/`height` stays too, since it's
     still what the surrounding layout uses to reserve space next to the label text. */
  width: 1.1em;
  height: 1.1em;
  transform: scale(1.3);
  transform-origin: center;
  margin-right: 0.4em;
  /* Nudges the box to align with the first line of text rather than sitting low, which
     becomes more noticeable the larger `em` scales it. */
  vertical-align: -0.15em;
}
</style>
