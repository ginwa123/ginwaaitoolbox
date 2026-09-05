import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import SearchHistory from '../SearchHistory.vue'

describe('SearchHistory.vue — in-progress', () => {
  it('shows mode/query from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(SearchHistory, {
      props: {
        content: '',
        parameters: '<mode>text</mode><query>login bug</query>',
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('login bug')
    expect(html).toContain('text search')
    expect(html).not.toContain('search_history ·')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(SearchHistory, {
      props: {
        content: '',
        parameters: '<mode>text</mode><query>login bug</query>',
      } as never,
    })
    expect(running.find('[data-testid="search-history-running"]').exists()).toBe(true)
    const done = mount(SearchHistory, {
      props: {
        content: '<search_history mode="text"><query>login bug</query><count>0</count></search_history>',
        parameters: '<mode>text</mode><query>login bug</query>',
      } as never,
    })
    expect(done.find('[data-testid="search-history-running"]').exists()).toBe(false)
  })
})
