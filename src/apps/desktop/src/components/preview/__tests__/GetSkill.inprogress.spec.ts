import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import GetSkill from '../GetSkill.vue'

describe('GetSkill.vue — in-progress', () => {
  it('shows skill_name from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(GetSkill, {
      props: {
        content: '',
        parameters: '<skill_name>my-skill</skill_name>',
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('my-skill')
    expect(html).not.toContain('unknown')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(GetSkill, {
      props: {
        content: '',
        parameters: '<skill_name>my-skill</skill_name>',
      } as never,
    })
    expect(running.find('[data-testid="get-skill-running"]').exists()).toBe(true)
    const done = mount(GetSkill, {
      props: {
        content: '<get_skill><skill_name>my-skill</skill_name><loaded>true</loaded></get_skill>',
        parameters: '<skill_name>my-skill</skill_name>',
      } as never,
    })
    expect(done.find('[data-testid="get-skill-running"]').exists()).toBe(false)
  })
})
