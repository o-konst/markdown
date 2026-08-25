import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

import { parseMarkdownToDoc, serializeDocToMarkdown } from '../../schema'

// fixtures/markdown-roundtrip/*.md lives at the repo root, sibling to rust/ and
// vue-project/ — see .claude/plans/live-preview-editing-plan.md's "Open items to
// confirm" list (location confirmed there before this was written).
const FIXTURES_DIR = join(dirname(fileURLToPath(import.meta.url)), '../../../../../fixtures/markdown-roundtrip')

const fixtureFiles = readdirSync(FIXTURES_DIR).filter((name) => name.endsWith('.md'))

describe('markdown round-trip fidelity', () => {
  it('found the fixture corpus', () => {
    expect(fixtureFiles.length).toBeGreaterThan(0)
  })

  for (const file of fixtureFiles) {
    it(`${file}: parse -> serialize -> parse produces a structurally identical doc`, () => {
      const original = readFileSync(join(FIXTURES_DIR, file), 'utf-8')

      const doc1 = parseMarkdownToDoc(original)
      const md2 = serializeDocToMarkdown(doc1)
      const doc2 = parseMarkdownToDoc(md2)

      expect(doc1.eq(doc2)).toBe(true)
    })

    it(`${file}: first-pass serialization matches its snapshot`, () => {
      const original = readFileSync(join(FIXTURES_DIR, file), 'utf-8')
      const doc1 = parseMarkdownToDoc(original)
      const md1 = serializeDocToMarkdown(doc1)
      expect(md1).toMatchSnapshot()
    })
  }
})
