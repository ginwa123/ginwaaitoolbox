import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import EditSkill from '../EditSkill.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('EditSkill.vue — clean success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(EditSkill, {
      props: {
        content: '<edit_skill><edited>true</edited><name>my-skill</name></edit_skill>',
        parameters: '{"name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })
})
