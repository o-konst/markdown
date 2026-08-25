import { computed, toValue, type MaybeRefOrGetter } from 'vue'

/** One heading in the document, with its descendants nested underneath. */
export interface OutlineNode {
  id: string
  text: string
  level: number
  children: OutlineNode[]
}

const HEADING_SELECTOR = 'h1, h2, h3, h4, h5, h6'

/** A document needs at least this many headings before an outline is worth showing. */
const MIN_HEADINGS = 2

/** Turns heading text into a URL fragment. */
function slugify(text: string): string {
  return text
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '')
}

interface Outline {
  /** The input fragment, with an `id` on every heading. */
  html: string
  nodes: OutlineNode[]
  /** Heading ids in document order, for the scroll spy. */
  ids: string[]
}

/**
 * Reads the outline out of a rendered fragment and gives every heading an anchor.
 *
 * The Rust renderer only emits heading ids for headings the author tagged with
 * `{#custom-id}`, so the rest are slugged here.
 */
function buildOutline(html: string): Outline {
  const empty: Outline = { html, nodes: [], ids: [] }
  if (!html) return empty

  const doc = new DOMParser().parseFromString(html, 'text/html')
  const headings = Array.from(doc.body.querySelectorAll<HTMLElement>(HEADING_SELECTOR))
  if (headings.length === 0) return empty

  const taken = new Set<string>()
  const nodes: OutlineNode[] = []
  const ids: string[] = []
  // Ancestors of the heading being visited, shallowest first.
  const ancestors: OutlineNode[] = []

  headings.forEach((heading, index) => {
    const text = heading.textContent?.trim() ?? ''
    // A heading that is only an image or emoji slugs to nothing.
    const base = heading.id || slugify(text) || `section-${index + 1}`

    let id = base
    for (let suffix = 2; taken.has(id); suffix += 1) {
      id = `${base}-${suffix}`
    }
    taken.add(id)
    heading.id = id
    ids.push(id)

    const node: OutlineNode = {
      id,
      text,
      level: Number(heading.tagName[1]),
      children: [],
    }

    // Documents skip levels (an h1 followed by an h3), so compare rather than count.
    while (ancestors.length > 0 && ancestors[ancestors.length - 1]!.level >= node.level) {
      ancestors.pop()
    }
    const parent = ancestors[ancestors.length - 1]
    ;(parent ? parent.children : nodes).push(node)
    ancestors.push(node)
  })

  return { html: doc.body.innerHTML, nodes, ids }
}

export function useDocumentOutline(html: MaybeRefOrGetter<string>) {
  const outline = computed(() => buildOutline(toValue(html)))

  return {
    html: computed(() => outline.value.html),
    nodes: computed(() => outline.value.nodes),
    ids: computed(() => outline.value.ids),
    hasOutline: computed(() => outline.value.ids.length >= MIN_HEADINGS),
  }
}
