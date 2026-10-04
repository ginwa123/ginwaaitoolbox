import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import RemoveSkill from '../RemoveSkill.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

const removed = { skill_name: 'my-skill', removed: true }

describe('RemoveSkill.vue — clean success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(RemoveSkill, {
      props: {
        content: removed,
        parameters: '{"skill_name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })

  it('names the removed skill — there is no path to show', () => {
    const wrapper = mount(RemoveSkill, {
      props: {
        content: removed,
        parameters: '{"skill_name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.find('[data-testid="remove-skill-name"]').text()).toContain('my-skill')
    expect(wrapper.text()).not.toContain('Path:')
    expect(wrapper.text()).not.toContain('SKILL.MD')
  })

  it('is not expandable when a clean success carries neither a name nor args', () => {
    const wrapper = mount(RemoveSkill, {
      props: { content: { removed: true } } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(false)
  })

  it('shows the error and does not claim a removal on a refusal', () => {
    const wrapper = mount(RemoveSkill, {
      props: {
        content: { skill_name: 'ghost', removed: false, error: 'no such skill' },
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).toContain('no such skill')
    expect(wrapper.find('[data-testid="remove-skill-name"]').exists()).toBe(false)
  })

  it('renders off a payload that still carries the retired path', () => {
    const wrapper = mount(RemoveSkill, {
      props: {
        content: { ...removed, path: '/skills/my-skill/SKILL.MD' },
        parameters: '{"skill_name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).not.toContain('/skills/my-skill/SKILL.MD')
    expect(wrapper.find('[data-testid="remove-skill-name"]').exists()).toBe(true)
  })
})
