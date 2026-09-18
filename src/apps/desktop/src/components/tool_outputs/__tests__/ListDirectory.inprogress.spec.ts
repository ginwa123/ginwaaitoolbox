import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ListDirectory from '../ListDirectory.vue'

const makeWrapper = (props: { content: unknown; parameters?: string }) =>
  mount(ListDirectory, { props: props as never })

describe('ListDirectory.vue — in-progress placeholder', () => {
  it('shows path from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<path>/proj</path>',
    })
    const html = wrapper.html()
    expect(html).toContain('/proj')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="list-directory-running"]').exists()).toBe(true)
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: {
        path: '/from/content',
        count: 1,
        entries: [{ name: 'a.txt', path: '/from/content/a.txt', is_directory: false, is_symlink: false }],
      },
      parameters: '<path>/from/params</path>',
    })
    const html = wrapper.html()
    expect(html).toContain('/from/content')
    expect(html).not.toContain('/from/params')
    expect(html.toLowerCase()).not.toContain('running')
    expect(wrapper.find('[data-testid="list-directory-running"]').exists()).toBe(false)
  })
})
