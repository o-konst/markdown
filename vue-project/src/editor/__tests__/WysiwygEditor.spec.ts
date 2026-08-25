// @vitest-environment happy-dom
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'

import WysiwygEditor from '../WysiwygEditor.vue'

/**
 * A real mounted-component check, not just the schema-level Phase 0 fixtures — per
 * `.claude/docs/live-preview-editing-research.md`'s "Node views" section, task-item
 * checkboxes and highlighted code blocks are claimed to work with zero custom code
 * beyond registering the extensions. Verifying that claim end-to-end (real DOM, real
 * click), not re-asserting it a third time.
 */
describe('WysiwygEditor (mounted)', () => {
  let wrapper: ReturnType<typeof mount> | undefined

  afterEach(() => {
    wrapper?.unmount()
    wrapper = undefined
  })

  it('renders a real, clickable checkbox for a task item and toggles it', async () => {
    wrapper = mount(WysiwygEditor, {
      props: { initialText: '- [ ] Unchecked\n- [x] Checked\n' },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()

    const checkboxes = wrapper.element.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')
    expect(checkboxes).toHaveLength(2)
    expect(checkboxes[0]?.checked).toBe(false)
    expect(checkboxes[1]?.checked).toBe(true)

    checkboxes[0]?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await wrapper.vm.$nextTick()

    expect(checkboxes[0]?.checked).toBe(true)
  })

  it('renders a code block with lowlight syntax highlighting applied', async () => {
    wrapper = mount(WysiwygEditor, {
      props: { initialText: '```js\nconst x = 1;\n```\n' },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()

    const codeBlock = wrapper.element.querySelector('pre code')
    expect(codeBlock).not.toBeNull()
    // lowlight/highlight.js wraps recognized tokens in `.hljs-*` spans; a plain
    // unhighlighted `<code>` would just contain a single text node with no such span.
    expect(codeBlock?.querySelector('[class*="hljs-"]')).not.toBeNull()
  })

  it('shows the table toolbar only while the cursor is inside a table', async () => {
    wrapper = mount(WysiwygEditor, {
      props: { initialText: 'Outside text.\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n' },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()

    // ProseMirror's default initial selection sits at the very start of the doc — the
    // "Outside text." paragraph here, not the table — so the toolbar starts hidden.
    expect(wrapper.find('[role="toolbar"]').exists()).toBe(false)

    // happy-dom has no real layout engine, so a simulated click can't hit-test its way to
    // a text position the way a real browser would (`posAtCoords` needs real geometry) —
    // move the selection directly instead, the headless-safe equivalent of "the user
    // clicked into the first cell".
    const editor = (wrapper.vm as unknown as { editor: import('@tiptap/vue-3').Editor }).editor
    let cellPos: number | undefined
    editor.state.doc.descendants((node, pos) => {
      if (cellPos === undefined && node.type.name === 'tableCell') cellPos = pos + 1
    })
    expect(cellPos).toBeDefined()
    editor.commands.setTextSelection(cellPos as number)
    await wrapper.vm.$nextTick()

    expect(wrapper.find('[role="toolbar"]').exists()).toBe(true)
  })

  it('copies the code block\'s text via the Clipboard API and shows a "copied" state', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })

    wrapper = mount(WysiwygEditor, {
      props: { initialText: '```js\nconst x = 1;\n```\n' },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()

    const button = wrapper.find<HTMLButtonElement>('.code-block-view__copy')
    expect(button.exists()).toBe(true)
    expect(button.attributes('aria-label')).toBe('Copy code')

    await button.trigger('click')
    await wrapper.vm.$nextTick()

    expect(writeText).toHaveBeenCalledWith('const x = 1;')
    expect(button.attributes('aria-label')).toBe('Copied')
  })

  it('falls back to execCommand when the Clipboard API rejects', async () => {
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: vi.fn().mockRejectedValue(new Error('denied')) },
      configurable: true,
    })
    const execCommand = vi.fn().mockReturnValue(true)
    document.execCommand = execCommand

    wrapper = mount(WysiwygEditor, {
      props: { initialText: '```js\nconst x = 1;\n```\n' },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()

    const button = wrapper.find<HTMLButtonElement>('.code-block-view__copy')
    await button.trigger('click')
    // The Clipboard API call rejects asynchronously before the execCommand fallback runs.
    await new Promise((resolve) => setTimeout(resolve, 0))
    await wrapper.vm.$nextTick()

    expect(execCommand).toHaveBeenCalledWith('copy')
    expect(button.attributes('aria-label')).toBe('Copied')
  })
})
