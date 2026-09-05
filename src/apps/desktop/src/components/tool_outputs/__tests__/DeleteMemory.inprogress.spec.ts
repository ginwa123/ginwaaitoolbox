import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import DeleteMemory from '../DeleteMemory.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
  mount(DeleteMemory, { props: props as never })

describe('DeleteMemory.vue — in-progress placeholder', () => {
  it('shows id from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<id>mem_to_delete</id>',
    })
    const html = wrapper.html()
    expect(html).toContain('mem_to_delete')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="delete-memory-running"]').exists()).toBe(true)
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: '<delete_memory><id>mem_from_content</id><deleted>true</deleted></delete_memory>',
      parameters: '<id>mem_from_params</id>',
    })
    const html = wrapper.html()
    expect(html).toContain('mem_from_content')
    expect(html).not.toContain('mem_from_params')
    expect(html.toLowerCase()).not.toContain('running')
  })
})
