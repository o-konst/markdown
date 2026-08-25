<script setup lang="ts">
import OutlineList from './OutlineList.vue'
import type { OutlineNode } from '@/composables/useDocumentOutline'

defineProps<{
  nodes: OutlineNode[]
  activeId: string | null
}>()

const emit = defineEmits<{ select: [id: string] }>()
</script>

<template>
  <nav class="outline" aria-label="Document outline">
    <p class="title">Contents</p>
    <OutlineList :nodes="nodes" :active-id="activeId" @select="emit('select', $event)" />
  </nav>
</template>

<style scoped>
.outline {
  padding: 1.5rem 0.6rem 1.5rem 1rem;
}

.title {
  padding-left: 0.4rem;
  margin-bottom: 0.5rem;
  font-size: 0.68rem;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--color-heading);
  opacity: 0.55;
}
</style>
