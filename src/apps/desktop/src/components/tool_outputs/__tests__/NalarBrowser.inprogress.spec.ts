import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import NalarBrowser from '../NalarBrowser.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
  mount(NalarBrowser, { props: props as never })

describe('NalarBrowser.vue — in-progress placeholder', () => {
  it('resolves the action from XML parameters (production shape, not unknown)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<action>open_page</action><url>https://example.com</url>',
    })
    const html = wrapper.html()
    expect(html).toContain('open_page')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="nalar-browser-running"]').exists()).toBe(true)
  })

  it('keeps the JSON parameters fallback and prefers completed content', () => {
    const wrapper = makeWrapper({
      content: '<data><browser_id>b_1</browser_id><page_id>p_1</page_id><url>https://example.com</url><title>Example</title><status>200</status></data>',
      parameters: '{"action":"open_page","url":"https://example.com"}',
    })
    const html = wrapper.html()
    expect(html).toContain('open_page')
    expect(html).toContain('Example')
    expect(html.toLowerCase()).not.toContain('running')
    expect(wrapper.find('[data-testid="nalar-browser-running"]').exists()).toBe(false)
  })
})
