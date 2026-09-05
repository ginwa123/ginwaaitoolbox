import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ReadFile from '../ReadFile.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
  mount(ReadFile, { props: props as never })

describe('ReadFile.vue — in-progress placeholder', () => {
  it('shows path from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<path>/proj/foo.txt</path>',
    })
    const html = wrapper.html()
    expect(html).toContain('/proj/foo.txt')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: '<read_file><path>/from/content.txt</path><content>hello</content><success>true</success></read_file>',
      parameters: '<path>/from/params.txt</path>',
    })
    const html = wrapper.html()
    expect(html).toContain('/from/content.txt')
    expect(html).not.toContain('/from/params.txt')
    expect(html.toLowerCase()).not.toContain('running')
  })
})
