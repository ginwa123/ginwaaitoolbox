import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import RemoveFile from '../RemoveFile.vue'

const makeWrapper = (props: { content: unknown; parameters?: string }) =>
  mount(RemoveFile, { props: props as never })

describe('RemoveFile.vue — in-progress placeholder', () => {
  it('shows path from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '{"path":"/proj/del.txt"}',
    })
    const html = wrapper.html()
    expect(html).toContain('/proj/del.txt')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: { path: '/from/content.txt', deleted: true, error: null },
      parameters: '{"path":"/from/params.txt"}',
    })
    const html = wrapper.html()
    expect(html).toContain('/from/content.txt')
    expect(html).not.toContain('/from/params.txt')
    expect(html.toLowerCase()).not.toContain('running')
  })
})
