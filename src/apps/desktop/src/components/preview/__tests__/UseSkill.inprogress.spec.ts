import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import UseSkill from '../UseSkill.vue'

const loadedPayload = {
  skill_name: 'my-skill',
  content: '# my skill body',
  loaded: true,
  error: null,
  available_skills: null,
}

describe('UseSkill.vue — in-progress', () => {
  it('shows skill_name from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: null,
        parameters: JSON.stringify({ path: '/skills/my-skill/SKILL.MD', skill_name: 'my-skill' }),
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('my-skill')
    expect(html).not.toContain('unknown')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(UseSkill, {
      props: {
        content: null,
        parameters: JSON.stringify({ path: '/skills/my-skill/SKILL.MD', skill_name: 'my-skill' }),
      } as never,
    })
    expect(running.find('[data-testid="use-skill-running"]').exists()).toBe(true)
    const done = mount(UseSkill, {
      props: {
        content: loadedPayload,
        parameters: JSON.stringify({ path: '/skills/my-skill/SKILL.MD', skill_name: 'my-skill' }),
      } as never,
    })
    expect(done.find('[data-testid="use-skill-running"]').exists()).toBe(false)
  })

  it('shows loaded content and status from the JSON payload', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: loadedPayload,
        expanded: true,
        parameters: JSON.stringify({ path: '/skills/my-skill/SKILL.MD' }),
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('my-skill')
    expect(html).toContain('# my skill body')
    expect(html).toContain('✓')
  })

  it('shows the error from the JSON payload', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: {
          skill_name: '',
          content: '',
          loaded: false,
          error: 'Failed to open file "missing/SKILL.MD": FileNotFound',
          available_skills: null,
        },
        expanded: true,
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('Failed to open file')
    expect(html).toContain('✗')
  })
})
