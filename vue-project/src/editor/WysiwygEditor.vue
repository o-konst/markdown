<script setup lang="ts">
/**
 * Phase-0 spike only (`.claude/plans/live-preview-editing-plan.md`): a minimal
 * dev-only harness to manually exercise the schema + `@tiptap/markdown` +
 * custom extensions in a real browser via `bun run dev`. Not wired into
 * `App.vue` or the native bridge — Phase 2 builds the real editor component
 * and integrates it into the actual app shell.
 */
import { ref, watch } from 'vue'
import { EditorContent, useEditor } from '@tiptap/vue-3'
import { createExtensions } from './schema'

const SAMPLE = `# WYSIWYG spike {#sample}

Type **bold**, *italic*, and \`code\` — the markup should disappear as you type it.

- [ ] Try a task list
- [x] Like this one

| Left | Center | Right |
| :--- | :---: | ---: |
| a | b | c |

A footnote reference.[^note]

[^note]: Defined here.
`

const markdown = ref(SAMPLE)

const editor = useEditor({
  extensions: createExtensions(),
  content: SAMPLE,
  contentType: 'markdown',
  onUpdate: ({ editor: current }) => {
    markdown.value = current.getMarkdown()
  },
})
</script>

<template>
  <div class="wysiwyg-spike">
    <EditorContent :editor="editor" class="wysiwyg-spike__editor" />
    <pre class="wysiwyg-spike__markdown">{{ markdown }}</pre>
  </div>
</template>

<style scoped>
.wysiwyg-spike {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
  height: 100vh;
  padding: 1rem;
  box-sizing: border-box;
}

.wysiwyg-spike__editor {
  overflow: auto;
  border: 1px solid #ccc;
  padding: 0.5rem;
}

.wysiwyg-spike__markdown {
  overflow: auto;
  border: 1px solid #ccc;
  padding: 0.5rem;
  margin: 0;
  white-space: pre-wrap;
}
</style>
