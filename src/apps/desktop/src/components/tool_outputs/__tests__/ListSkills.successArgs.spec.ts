import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ListSkills from '../ListSkills.vue'

describe('ListSkills.vue — success with args shows Arguments when expanded', () => {
  it('expanded body shows Arguments', () => {
    const wrapper = mount(ListSkills, {
      props: {
        content: '<list_skills><global_skills></global_skills><local_skills></local_skills></list_skills>',
        parameters: '{"filter":"all"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).toContain('Arguments')
  })
})
