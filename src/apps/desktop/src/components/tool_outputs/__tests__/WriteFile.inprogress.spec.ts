import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import WriteFile from '../WriteFile.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
  mount(WriteFile, { props: props as never })

describe('WriteFile.vue — in-progress placeholder', () => {
  it('shows path from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<path>/proj/out.txt</path>',
    })
    const html = wrapper.html()
    expect(html).toContain('/proj/out.txt')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: '<success>true</success><file_write>/from/content.txt</file_write>',
      parameters: '<path>/from/params.txt</path>',
    })
    const html = wrapper.html()
    expect(html).toContain('/from/content.txt')
    expect(html).not.toContain('/from/params.txt')
    expect(html.toLowerCase()).not.toContain('running')
  })
})
