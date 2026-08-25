<script setup lang="ts">
import type { OutlineNode } from '@/composables/useDocumentOutline'

defineProps<{
  nodes: OutlineNode[]
  activeId: string | null
}>()

const emit = defineEmits<{ select: [id: string] }>()
</script>

<template>
  <ul class="outline-list">
    <li v-for="node in nodes" :key="node.id">
      <a
        :href="`#${node.id}`"
        :class="{ active: node.id === activeId }"
        :aria-current="node.id === activeId ? 'location' : undefined"
        :title="node.text"
        @click.prevent="emit('select', node.id)"
        >{{ node.text }}</a
      >
      <!-- Recurses by filename: an SFC can refer to itself. -->
      <OutlineList
        v-if="node.children.length > 0"
        :nodes="node.children"
        :active-id="activeId"
        @select="emit('select', $event)"
      />
    </li>
  </ul>
</template>

<style scoped>
.outline-list {
  list-style: none;
  padding: 0;
}

/* Each nested level steps in a little further. */
.outline-list .outline-list {
  padding-left: 0.7rem;
}

a {
  display: block;
  padding: 0.16rem 0.4rem;
  border-radius: 4px;
  color: var(--color-text);
  font-size: 0.85rem;
  line-height: 1.45;
  text-decoration: none;
  /* Long headings truncate rather than widening the pane. */
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

a:hover {
  background: var(--color-background-mute);
  color: var(--color-heading);
  text-decoration: none;
}

a.active {
  background: var(--color-background-mute);
  color: var(--color-heading);
  font-weight: 600;
}
</style>
