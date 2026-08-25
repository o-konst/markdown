import { getSchema } from '@tiptap/core'
import type { AnyExtension } from '@tiptap/core'
import { Node as PMNode } from '@tiptap/pm/model'
import type { Node as PMDoc } from '@tiptap/pm/model'
import StarterKit from '@tiptap/starter-kit'
import { Table, TableRow, TableHeader, TableCell } from '@tiptap/extension-table'
import { TaskList, TaskItem } from '@tiptap/extension-list'
import Image from '@tiptap/extension-image'
import { createLowlight, common } from 'lowlight'
import { Markdown, MarkdownManager } from '@tiptap/markdown'

import { HeadingWithId } from './markdown/headingIdExtension'
import { FootnoteReference, FootnoteDefinition } from './markdown/footnoteExtension'
import { CodeBlockWithFenceLength } from './markdown/codeBlockFenceExtension'

const lowlight = createLowlight(common)

/**
 * The schema described in `.claude/docs/live-preview-editing-research.md`'s
 * "Schema" section: doc/paragraph/text, heading (with `{#id}` support),
 * blockquote, lists (incl. task lists), code blocks (highlighted, no nested
 * CodeMirror), tables (with native column-alignment support — confirmed
 * built into `@tiptap/extension-table` directly, no custom `align` attr
 * needed), images, footnotes, and the standard bold/italic/strike/code/link
 * marks. No raw-HTML node type — see the Sanitization section of that doc.
 *
 * `underline` is disabled even though `@tiptap/starter-kit` includes it by
 * default, to keep the schema exactly matching the researched/planned mark
 * set until underline's own markdown round-trip behavior is reviewed.
 */
export function createExtensions(): AnyExtension[] {
  return [
    StarterKit.configure({
      heading: false,
      codeBlock: false,
      underline: false,
    }),
    HeadingWithId,
    CodeBlockWithFenceLength.configure({ lowlight }),
    Table.configure({ resizable: false }),
    TableRow,
    TableHeader,
    TableCell,
    TaskList,
    TaskItem.configure({ nested: true }),
    Image,
    FootnoteReference,
    FootnoteDefinition,
    Markdown,
  ]
}

let cachedManager: MarkdownManager | null = null

/** Lazily-built, process-wide `MarkdownManager` — construction is pure and stateless per call, so one instance is safe to share across parse/serialize calls. */
function manager(): MarkdownManager {
  if (!cachedManager) {
    cachedManager = new MarkdownManager({ extensions: createExtensions() })
  }
  return cachedManager
}

let cachedSchema: ReturnType<typeof getSchema> | null = null

function schema() {
  if (!cachedSchema) {
    cachedSchema = getSchema(createExtensions())
  }
  return cachedSchema
}

/** Parses markdown text into a real ProseMirror document (not just JSONContent), for round-trip comparison and future editor use. */
export function parseMarkdownToDoc(markdown: string): PMDoc {
  const json = manager().parse(markdown)
  return PMNode.fromJSON(schema(), json)
}

/** Serializes a ProseMirror document back to markdown text via `@tiptap/markdown`'s per-node-type direct serialization (no HTML intermediate). */
export function serializeDocToMarkdown(doc: PMDoc): string {
  return manager().serialize(doc.toJSON())
}
