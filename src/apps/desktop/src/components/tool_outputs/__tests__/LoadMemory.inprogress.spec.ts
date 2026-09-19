import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import LoadMemory from '../LoadMemory.vue'

const makeWrapper = (props: { content: unknown; parameters?: string }) =>
  mount(LoadMemory, { props: props as never })

describe('LoadMemory.vue — in-progress placeholder', () => {
  it('shows running badge and suppresses the empty hint when content empty', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '{"query":"dark mode","limit":10}',
    })
    const html = wrapper.html()
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="load-memory-running"]').exists()).toBe(true)
    // An empty envelope is "not started", not "no results".
    expect(wrapper.find('[data-testid="load-memory-empty"]').exists()).toBe(false)
  })

  it('renders entries when completed (no running badge)', () => {
    const wrapper = makeWrapper({
      content: {
        query: 'dark mode',
        limit: 10,
        offset: 0,
        with_content: false,
        count: 1,
        total_count: 1,
        results: [{ id: 'mem_1', tags: 'preferences', snippet: 'prefers [match]dark[/match] mode' }],
      },
      parameters: '{"query":"dark mode","limit":10}',
      expanded: true,
    } as never)
    const html = wrapper.html()
    expect(html).toContain('mem_1')
    expect(html.toLowerCase()).not.toContain('running')
    expect(wrapper.find('[data-testid="load-memory-running"]').exists()).toBe(false)
  })
})
