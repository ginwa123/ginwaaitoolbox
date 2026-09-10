import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import UseSkill from '../UseSkill.vue'

describe('UseSkill.vue — in-progress', () => {
  it('shows skill_name from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(UseSkill, {
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
    const running = mount(UseSkill, {
      props: {
        content: '',
        parameters: '<skill_name>my-skill</skill_name>',
      } as never,
    })
    expect(running.find('[data-testid="use-skill-running"]').exists()).toBe(true)
    const done = mount(UseSkill, {
      props: {
        content: '<use_skill><skill_name>my-skill</skill_name><loaded>true</loaded></use_skill>',
        parameters: '<skill_name>my-skill</skill_name>',
      } as never,
    })
    expect(done.find('[data-testid="use-skill-running"]').exists()).toBe(false)
  })
})
