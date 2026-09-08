import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import AddSkill from '../AddSkill.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('AddSkill.vue — clean success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(AddSkill, {
      props: {
        content: '<add_skill><created>true</created><name>my-skill</name></add_skill>',
        parameters: '{"name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })
})
