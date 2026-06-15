import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ProfilesSection from '../components/nalar/ProfilesSection.vue'
import type { ProfileRow } from '../components/nalar/ProfilesSection.vue'

const baseProfile: ProfileRow = {
  name: 'work',
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  sub_agents: [],
}

describe('ProfilesSection', () => {
  it('shows the active profile in the header pill', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: 'work' },
    })
    expect(wrapper.find('[data-testid="active-pill"]').text()).toContain('work')
  })

  it('shows the empty state when no profiles exist', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [], activeProfile: null },
    })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('emits setActive when "Set active" is clicked on a non-active row', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile }, { ...baseProfile, name: 'home' }], activeProfile: 'work' },
    })
    const buttons = wrapper.findAll('[data-testid="set-active-btn"]')
    expect(buttons.length).toBe(1)
    await buttons[0]!.trigger('click')
    expect(wrapper.emitted('setActive')?.[0]).toEqual(['home'])
  })

  it('emits edit when Edit is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseProfile])
  })

  it('emits delete when Delete is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['work'])
  })

  it('emits add when the + Add profile button is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [], activeProfile: null },
    })
    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.emitted('add')).toBeTruthy()
  })
})
