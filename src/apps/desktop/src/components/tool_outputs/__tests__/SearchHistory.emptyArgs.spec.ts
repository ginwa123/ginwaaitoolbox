import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import SearchHistory from '../SearchHistory.vue'

const EMPTY_TEXT = [
  `<search_history mode="text" offset="0" limit="20">`,
  `  <query>no-such-string</query>`,
  `  <count>0</count>`,
  `  <total_count>0</total_count>`,
  `  <results>`,
  `  </results>`,
  `</search_history>`,
].join('\n')

describe('SearchHistory.vue — empty results with args shows Arguments when expanded', () => {
  it('expanded body shows Arguments on empty results', () => {
    const wrapper = mount(SearchHistory, {
      props: {
        content: EMPTY_TEXT,
        parameters: '{"query":"no-such-string","mode":"text"}',
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="search-history-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })

  it('header click expands on empty results when args present', async () => {
    const wrapper = mount(SearchHistory, {
      props: {
        content: EMPTY_TEXT,
        parameters: '{"query":"no-such-string","mode":"text"}',
      },
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('Arguments')
  })
})
