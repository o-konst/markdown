// @vitest-environment happy-dom
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'

import MarkdownPreview from '../MarkdownPreview.vue'

/**
 * Reading view's copy button can't be tested at the schema/fixture level like the WYSIWYG
 * editor's — it's stamped imperatively onto `v-html` content after render (see
 * `.claude/plans/live-preview-editing-plan.md`'s "Copy-to-clipboard button on code
 * blocks" phase), so this needs a real mounted component and a real DOM.
 */
describe('MarkdownPreview copy button', () => {
  let wrapper: ReturnType<typeof mount> | undefined

  afterEach(() => {
    wrapper?.unmount()
    wrapper = undefined
  })

  it('stamps a copy button onto every rendered <pre> block', async () => {
    const html = '<p>Text</p><pre><code>const x = 1;</code></pre>'
    wrapper = mount(MarkdownPreview, {
      props: { html, isEmpty: false },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()

    const buttons = wrapper.element.querySelectorAll('.markdown-body__copy')
    expect(buttons).toHaveLength(1)
    expect(buttons[0]?.getAttribute('aria-label')).toBe('Copy code')
  })

  it("copies the pre block's own text (not the button's) and shows a copied state", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })

    const html = '<pre><code>const x = 1;</code></pre>'
    wrapper = mount(MarkdownPreview, {
      props: { html, isEmpty: false },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()

    const button = wrapper.element.querySelector<HTMLButtonElement>('.markdown-body__copy')
    expect(button).not.toBeNull()
    button?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await new Promise((resolve) => setTimeout(resolve, 0))
    await wrapper.vm.$nextTick()

    expect(writeText).toHaveBeenCalledWith('const x = 1;')
    expect(button?.getAttribute('aria-label')).toBe('Copied')
  })

  it('does not leak buttons across re-renders when html changes', async () => {
    const html1 = '<pre><code>one</code></pre>'
    wrapper = mount(MarkdownPreview, {
      props: { html: html1, isEmpty: false },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    expect(wrapper.element.querySelectorAll('.markdown-body__copy')).toHaveLength(1)

    // v-html replaces the whole innerHTML on change, so a fresh stamp pass should still
    // find exactly one button, not two (an old one plus a new one).
    const html2 = '<pre><code>one</code></pre><pre><code>two</code></pre>'
    await wrapper.setProps({ html: html2 })
    await wrapper.vm.$nextTick()

    expect(wrapper.element.querySelectorAll('.markdown-body__copy')).toHaveLength(2)
  })
})
