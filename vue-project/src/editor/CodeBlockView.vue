<script setup lang="ts">
import { NodeViewContent, NodeViewWrapper, nodeViewProps } from '@tiptap/vue-3'
import { onBeforeUnmount, ref } from 'vue'
import { copyToClipboard } from '../utils/copyToClipboard'
import { CHECK_ICON_SVG, COPY_ICON_SVG } from '../utils/copyIcons'

/**
 * Node view for fenced code blocks — adds a hover-revealed copy button in the top-right
 * corner (`.claude/plans/live-preview-editing-plan.md`'s "Copy-to-clipboard button on
 * code blocks" phase) around the same `<pre><code>` shape `CodeBlockLowlight` rendered
 * unadorned before. `NodeViewContent as="code"` becomes ProseMirror's `contentDOM` for
 * this node — `CodeBlockLowlight`'s existing decoration-based syntax-highlighting plugin
 * still applies its `.hljs-*` decorations to it exactly as before; nothing about how that
 * plugin finds/decorates the code text changes by wrapping it in this node view.
 */
const props = defineProps(nodeViewProps)

const justCopied = ref(false)
let resetTimer: ReturnType<typeof setTimeout> | undefined

async function onCopyClick() {
  const ok = await copyToClipboard(props.node.textContent)
  if (!ok) return

  justCopied.value = true
  if (resetTimer) clearTimeout(resetTimer)
  resetTimer = setTimeout(() => {
    justCopied.value = false
  }, 1500)
}

/**
 * The button sits inside the contenteditable region (it's chrome the node view adds
 * around ProseMirror's actual content, not part of `contentDOM` — but it's still a
 * descendant of the editable `<pre>`). Without this, `mousedown` on the button would move
 * ProseMirror's selection to wherever the click landed before the `click` handler ever
 * runs, which both looks wrong and can steal focus from the editor mid-click.
 */
function onCopyMouseDown(event: MouseEvent) {
  event.preventDefault()
  event.stopPropagation()
}

onBeforeUnmount(() => {
  if (resetTimer) clearTimeout(resetTimer)
})
</script>

<template>
  <NodeViewWrapper as="pre" class="code-block-view">
    <button
      type="button"
      class="code-block-view__copy"
      :class="{ 'code-block-view__copy--copied': justCopied }"
      :aria-label="justCopied ? 'Copied' : 'Copy code'"
      contenteditable="false"
      @mousedown="onCopyMouseDown"
      @click="onCopyClick"
      v-html="justCopied ? CHECK_ICON_SVG : COPY_ICON_SVG"
    />
    <NodeViewContent as="code" />
  </NodeViewWrapper>
</template>

<style scoped>
.code-block-view {
  position: relative;
}

.code-block-view__copy {
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

.code-block-view:hover .code-block-view__copy,
.code-block-view__copy:focus-visible {
  opacity: 1;
}

.code-block-view__copy--copied {
  opacity: 1;
  color: #2da44e;
}
</style>
