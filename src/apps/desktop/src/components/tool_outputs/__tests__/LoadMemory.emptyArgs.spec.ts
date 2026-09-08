import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import LoadMemory from '../LoadMemory.vue'

const EMPTY_CONTENT = [
  `<load_memory query="no-such-memory" limit="10" offset="0" with_content="0">`,
  `  <count>0</count>`,
  `  <total_count>0</total_count>`,
  `  <results/>`,
  `</load_memory>`,
].join('\n')

describe('LoadMemory.vue — empty results with args shows Arguments when expanded', () => {
  it('expanded body shows Arguments on empty results', () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: EMPTY_CONTENT,
        parameters: '{"query":"no-such-memory"}',
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="load-memory-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })

  it('header click expands on empty results when args present', async () => {
    const wrapper = mount(LoadMemory, {
      props: {
        content: EMPTY_CONTENT,
        parameters: '{"query":"no-such-memory"}',
      },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('Arguments')
    wrapper.unmount()
  })
})
