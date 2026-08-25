<script setup lang="ts">
import type { Editor } from '@tiptap/core'
import { computed, onScopeDispose, shallowRef } from 'vue'

/**
 * A small, table-scoped toolbar — visible only while the cursor sits inside a table, not
 * always-on chrome cluttering the rest of the editor. Note on scope: the research doc
 * describes "hover-revealed" per-table affordances (drag handles at row/column edges),
 * which would need a custom Vue NodeView rendering controls inside each table instance.
 * This is the lighter-weight version instead — a single toolbar, gated on
 * `editor.isActive('table')` rather than per-edge mouse position — a deliberate,
 * documented scope reduction, not a silent substitution for the fuller design.
 */
const props = defineProps<{ editor: Editor }>()

const version = shallowRef(0)
const bump = () => {
  version.value += 1
}
props.editor.on('transaction', bump)
props.editor.on('selectionUpdate', bump)
onScopeDispose(() => {
  props.editor.off('transaction', bump)
  props.editor.off('selectionUpdate', bump)
})

const active = computed(() => {
  void version.value
  return props.editor.isActive('table')
})

function run(command: (chain: ReturnType<Editor['chain']>) => ReturnType<Editor['chain']>) {
  command(props.editor.chain().focus()).run()
}
</script>

<template>
  <div v-if="active" class="table-controls" role="toolbar" aria-label="Table">
    <button type="button" title="Add row above" @click="run((c) => c.addRowBefore())">+row ↑</button>
    <button type="button" title="Add row below" @click="run((c) => c.addRowAfter())">+row ↓</button>
    <button type="button" title="Delete row" @click="run((c) => c.deleteRow())">−row</button>
    <span class="table-controls__divider" />
    <button type="button" title="Add column left" @click="run((c) => c.addColumnBefore())">+col ←</button>
    <button type="button" title="Add column right" @click="run((c) => c.addColumnAfter())">+col →</button>
    <button type="button" title="Delete column" @click="run((c) => c.deleteColumn())">−col</button>
  </div>
</template>

<style scoped>
.table-controls {
  display: flex;
  align-items: center;
  gap: 0.25rem;
  padding: 0.25rem 0.4rem;
  margin-bottom: 0.4rem;
  border: 1px solid var(--color-border);
  border-radius: 6px;
  background: var(--color-background-soft);
  opacity: 0.55;
  transition: opacity 0.15s ease;
  width: fit-content;
}

.table-controls:hover {
  opacity: 1;
}

.table-controls button {
  font-size: 0.8em;
  padding: 0.2em 0.5em;
  border: 1px solid var(--color-border);
  border-radius: 4px;
  background: var(--color-background);
  cursor: pointer;
}

.table-controls__divider {
  width: 1px;
  align-self: stretch;
  background: var(--color-border);
  margin: 0 0.15rem;
}
</style>
