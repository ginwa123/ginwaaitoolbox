import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import SaveMemory from '../SaveMemory.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
  mount(SaveMemory, { props: props as never })

describe('SaveMemory.vue — in-progress placeholder', () => {
  it('shows id from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<id>mem_aabbccdd11223344</id>',
    })
    const html = wrapper.html()
    expect(html).toContain('mem_aabbccdd11223344')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="save-memory-running"]').exists()).toBe(true)
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: '<save_memory><id>mem_from_content</id><created_at>2026-08-06 10:00:00</created_at></save_memory>',
      parameters: '<id>mem_from_params</id>',
    })
    const html = wrapper.html()
    expect(html).toContain('mem_from_content')
    expect(html).not.toContain('mem_from_params')
    expect(html.toLowerCase()).not.toContain('running')
  })
})
