import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import RemoveFile from '../RemoveFile.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('RemoveFile.vue — success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(RemoveFile, {
      props: {
        content: '<path>/proj/del.txt</path><deleted>true</deleted>',
        parameters: '{"path":"/proj/del.txt"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })
})
