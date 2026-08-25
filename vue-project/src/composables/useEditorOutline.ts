import type { Editor } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { computed, onScopeDispose, shallowRef } from 'vue'

import { slugify } from './slugify'
import type { OutlineNode } from './useDocumentOutline'

/** A document needs at least this many headings before an outline is worth showing. */
const MIN_HEADINGS = 2

interface EditorOutline {
  nodes: OutlineNode[]
  ids: string[]
}

/**
 * Builds the same outline shape as `useDocumentOutline`'s `buildOutline`, but from a live
 * ProseMirror doc instead of rendered HTML — this is the WYSIWYG-view counterpart, used
 * once the editor (not the sanitized-HTML Reading view) is the current source of the
 * document. Ports that function's ancestor-stack nesting and dedupe-suffix loop
 * unchanged; only the tree being walked differs (`doc.descendants` instead of
 * `querySelectorAll`). Pure and framework-free so it's directly testable against docs
 * produced by `parseMarkdownToDoc` without needing a live `Editor`/DOM — see
 * CLAUDE.md invariant #8 and this file's tests for the parity this must hold.
 */
export function buildOutlineFromDoc(doc: PMNode): EditorOutline {
  const taken = new Set<string>()
  const nodes: OutlineNode[] = []
  const ids: string[] = []
  // Ancestors of the heading being visited, shallowest first.
  const ancestors: OutlineNode[] = []
  let index = 0

  doc.descendants((node) => {
    if (node.type.name !== 'heading') return
    const headingIndex = index
    index += 1

    const text = node.textContent.trim()
    // `HeadingWithId` only sets `attrs.id` from an explicit `{#id}` suffix, never invents
    // one — same "explicit id, else slug, else position" fallback as `outline.rs`.
    const explicitId = typeof node.attrs.id === 'string' ? node.attrs.id : null
    const base = explicitId || slugify(text) || `section-${headingIndex + 1}`

    let id = base
    for (let suffix = 2; taken.has(id); suffix += 1) {
      id = `${base}-${suffix}`
    }
    taken.add(id)
    ids.push(id)

    const level = typeof node.attrs.level === 'number' ? node.attrs.level : 1
    const outlineNode: OutlineNode = { id, text, level, children: [] }

    // Documents skip levels (an h1 followed by an h3), so compare rather than count.
    while (ancestors.length > 0 && ancestors[ancestors.length - 1]!.level >= outlineNode.level) {
      ancestors.pop()
    }
    const parent = ancestors[ancestors.length - 1]
    ;(parent ? parent.children : nodes).push(outlineNode)
    ancestors.push(outlineNode)
  })

  return { nodes, ids }
}

/** Reactive wrapper around {@link buildOutlineFromDoc}, recomputed on every editor transaction. */
export function useEditorOutline(editor: Editor) {
  const version = shallowRef(0)
  const bump = () => {
    version.value += 1
  }
  editor.on('transaction', bump)
  onScopeDispose(() => editor.off('transaction', bump))

  const outline = computed(() => {
    void version.value // establishes the reactive dependency `bump` drives
    return buildOutlineFromDoc(editor.state.doc)
  })

  return {
    nodes: computed(() => outline.value.nodes),
    ids: computed(() => outline.value.ids),
    hasOutline: computed(() => outline.value.ids.length >= MIN_HEADINGS),
  }
}
