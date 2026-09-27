import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ListSkills from '../ListSkills.vue'

function mountListSkills(content: unknown) {
  return mount(ListSkills, { props: { content, expanded: true } as never })
}

describe('ListSkills.vue — tags', () => {
  it('renders each "||"-joined tag as its own chip', () => {
    const wrapper = mountListSkills({
      global_skills: [{ name: 'auth', description: 'handles auth', path: '', tags: 'api||auth' }],
      local_skills: [],
    })
    const chips = wrapper.findAll('[data-testid="list-skill-tags"] span')
    expect(chips.map((c) => c.text())).toEqual(['api', 'auth'])
  })

  it('renders no chip row for a skill with empty tags', () => {
    // Most skills carry no `tags:` line, so the wire sends '' — which
    // must not render as one empty chip.
    const wrapper = mountListSkills({
      global_skills: [{ name: 'plain', description: 'no tags', path: '', tags: '' }],
      local_skills: [],
    })
    expect(wrapper.find('[data-testid="list-skill-tags"]').exists()).toBe(false)
  })

  it('renders a local skill with no file and no tags without a path line', () => {
    const wrapper = mountListSkills({
      global_skills: [],
      local_skills: [{ name: 'fresh', description: 'agent-created', path: '' }],
    })
    expect(wrapper.text()).toContain('fresh')
    expect(wrapper.text()).not.toContain('Path')
    expect(wrapper.find('[data-testid="list-skill-tags"]').exists()).toBe(false)
  })
})
