import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import Search from '../Search.vue'

describe('Search.vue — in-progress', () => {
  it('shows pattern+path from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(Search, {
      props: {
        content: '',
        parameters: '<pattern>needle</pattern><path>/tmp/repo</path>',
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('needle')
    expect(html).toContain('/tmp/repo')
    expect(html).not.toContain('unknown')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(Search, {
      props: {
        content: '',
        parameters: '<pattern>needle</pattern><path>/tmp/repo</path>',
      } as never,
    })
    expect(running.find('[data-testid="search-running"]').exists()).toBe(true)
    const done = mount(Search, {
      props: {
        content: '<search pattern="needle" path="/tmp/repo"></search>',
        parameters: '<pattern>needle</pattern>',
      } as never,
    })
    expect(done.find('[data-testid="search-running"]').exists()).toBe(false)
  })
})
