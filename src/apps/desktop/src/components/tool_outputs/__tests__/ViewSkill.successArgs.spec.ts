import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ViewSkill from '../ViewSkill.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('ViewSkill.vue — clean success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(ViewSkill, {
      props: {
        content: '<view_skill><found>true</found><skill_name>my-skill</skill_name></view_skill>',
        parameters: '{"skill_name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })
})
