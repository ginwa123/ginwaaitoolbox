import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import SubAgentsSection from '../components/nalar/SubAgentsSection.vue'
import type { SubAgent } from '../api'

const baseAgent: SubAgent = {
  name: 'coder',
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  system_prompt: 'short prompt',
}

describe('SubAgentsSection', () => {
  it('shows the section explainer', () => {
    const wrapper = mount(SubAgentsSection, { props: { modelValue: [] } })
    expect(wrapper.text()).toContain('spawn_sub_agent')
  })

  it('shows the empty state when no sub-agents exist', () => {
    const wrapper = mount(SubAgentsSection, { props: { modelValue: [] } })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('renders the 2-line prompt preview by default', () => {
    const long = 'word '.repeat(50).trim()
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [{ ...baseAgent, system_prompt: long }] },
    })
    const preview = wrapper.find('[data-testid="prompt-preview"]')
    expect(preview.classes()).toContain('line-clamp-2')
  })

  it('expands the prompt when "Show more" is clicked', async () => {
    const long = 'word '.repeat(50).trim()
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [{ ...baseAgent, system_prompt: long }] },
    })
    await wrapper.find('[data-testid="expand-prompt"]').trigger('click')
    const preview = wrapper.find('[data-testid="prompt-preview"]')
    expect(preview.classes()).not.toContain('line-clamp-2')
  })

  it('emits edit when Edit is clicked', async () => {
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [baseAgent] },
    })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseAgent])
  })

  it('emits delete when ⌫ is clicked', async () => {
    const wrapper = mount(SubAgentsSection, {
      props: { modelValue: [baseAgent] },
    })
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['coder'])
  })
})
