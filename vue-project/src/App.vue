<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import DocumentOutline from './components/DocumentOutline.vue'
import MarkdownPreview from './components/MarkdownPreview.vue'
import { reportOutlineState } from '@/bridge/nativeBridge'
import { useActiveHeading } from '@/composables/useActiveHeading'
import { useDocumentOutline } from '@/composables/useDocumentOutline'
import { useMarkdownPreview } from '@/composables/useMarkdownPreview'

const { html, source, preferences } = useMarkdownPreview()
const { html: documentHtml, nodes, ids, hasOutline } = useDocumentOutline(html)

const scroller = ref<HTMLElement | null>(null)
const activeId = useActiveHeading(scroller, ids)

const showOutline = computed(() => preferences.value.outlineVisible && hasOutline.value)

// Lets the host disable its toggle for documents that have nothing to navigate.
watch(hasOutline, (available) => void reportOutlineState(available), { immediate: true })

function scrollToHeading(id: string) {
  scroller.value
    ?.querySelector(`#${CSS.escape(id)}`)
    ?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

// MARK: - Resizable divider

const WIDTH_STORAGE_KEY = 'markdown.outlineWidth'
const DEFAULT_WIDTH = 240
const MIN_WIDTH = 160
const MAX_WIDTH = 448

function clampWidth(width: number): number {
  return Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, width))
}

/** Storage is unavailable on some hosts and throws rather than returning null. */
function storedWidth(): number {
  try {
    const saved = Number(localStorage.getItem(WIDTH_STORAGE_KEY))
    return Number.isFinite(saved) && saved > 0 ? clampWidth(saved) : DEFAULT_WIDTH
  } catch {
    return DEFAULT_WIDTH
  }
}

const outlineWidth = ref(storedWidth())

function startResize(event: PointerEvent) {
  const splitter = event.currentTarget as HTMLElement
  const startX = event.clientX
  const startWidth = outlineWidth.value

  function move(moveEvent: PointerEvent) {
    outlineWidth.value = clampWidth(startWidth + moveEvent.clientX - startX)
  }

  function finish() {
    splitter.releasePointerCapture(event.pointerId)
    splitter.removeEventListener('pointermove', move)
    splitter.removeEventListener('pointerup', finish)
    splitter.removeEventListener('pointercancel', finish)
    try {
      localStorage.setItem(WIDTH_STORAGE_KEY, String(outlineWidth.value))
    } catch {
      // Width simply resets next launch.
    }
  }

  splitter.setPointerCapture(event.pointerId)
  splitter.addEventListener('pointermove', move)
  splitter.addEventListener('pointerup', finish)
  splitter.addEventListener('pointercancel', finish)
  event.preventDefault()
}
</script>

<template>
  <div class="app">
    <template v-if="showOutline">
      <DocumentOutline
        class="outline-pane"
        :style="{ width: `${outlineWidth}px` }"
        :nodes="nodes"
        :active-id="activeId"
        @select="scrollToHeading"
      />
      <div
        class="splitter"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the outline"
        @pointerdown="startResize"
      />
    </template>

    <div ref="scroller" class="content" :style="{ fontSize: `${preferences.fontSize}px` }">
      <MarkdownPreview
        :class="{ 'page-width': preferences.contentWidth === 'page' }"
        :html="documentHtml"
        :is-empty="source.trim().length === 0"
      />
    </div>
  </div>
</template>

<style scoped>
.app {
  display: flex;
  height: 100vh;
}

.outline-pane {
  flex: 0 0 auto;
  /* Affixed: the content scrolls, this pane does not move. */
  overflow-y: auto;
}

.splitter {
  position: relative;
  flex: 0 0 5px;
  cursor: col-resize;
  /* Wider than the line it draws, so it is comfortable to grab. */
  touch-action: none;
}

.splitter::before {
  content: '';
  position: absolute;
  inset-block: 0;
  left: 2px;
  width: 1px;
  background: var(--color-border);
}

.splitter:hover::before {
  background: var(--color-border-hover);
}

.content {
  flex: 1;
  /* Without this a wide table stretches the pane instead of scrolling inside it. */
  min-width: 0;
  overflow-y: auto;
  padding: 1.75rem 2rem;
}

/* Caps the measure for reading; `ch` keeps it proportional to the chosen font size. */
.page-width {
  max-width: 72ch;
  margin-inline: auto;
}
</style>
