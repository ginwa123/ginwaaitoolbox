import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import TextReplace from '../TextReplace.vue'

const makeWrapper = (props: { content: unknown; parameters?: string }) =>
  mount(TextReplace, { props: props as never })

describe('TextReplace.vue — in-progress placeholder', () => {
  it('shows path from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '{"path":"/proj/a.txt"}',
    })
    const html = wrapper.html()
    expect(html).toContain('/proj/a.txt')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: { path: '/from/content.txt', before: 'x', after: 'y', error: null },
      parameters: '{"path":"/from/params.txt"}',
    })
    const html = wrapper.html()
    expect(html).toContain('/from/content.txt')
    expect(html).not.toContain('/from/params.txt')
    expect(html.toLowerCase()).not.toContain('running')
  })
})
