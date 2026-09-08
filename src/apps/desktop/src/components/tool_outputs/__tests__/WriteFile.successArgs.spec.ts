import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import WriteFile from '../WriteFile.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('WriteFile.vue — success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(WriteFile, {
      props: {
        content: '<success>true</success><file_write>/proj/out.txt</file_write>',
        parameters: '{"path":"/proj/out.txt"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })
})
