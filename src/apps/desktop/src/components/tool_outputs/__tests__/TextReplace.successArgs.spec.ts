import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import TextReplace from '../TextReplace.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('TextReplace.vue — success without diff but with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(TextReplace, {
      props: {
        content: '<text_replace><success>true</success><path>/proj/a.txt</path></text_replace>',
        parameters: '{"path":"/proj/a.txt"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })
})
