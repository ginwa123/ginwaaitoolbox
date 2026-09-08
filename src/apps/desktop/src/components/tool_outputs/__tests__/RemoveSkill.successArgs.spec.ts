import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import RemoveSkill from '../RemoveSkill.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('RemoveSkill.vue — clean success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(RemoveSkill, {
      props: {
        content: '<remove_skill><removed>true</removed><skill_name>my-skill</skill_name></remove_skill>',
        parameters: '{"skill_name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })
})
