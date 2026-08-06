import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ProfilesSection from '../components/nalar/ProfilesSection.vue'
import type { ProfileRow } from '../components/nalar/ProfilesSection.vue'
import type { SubAgent } from '../api'

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

const baseSubAgent: SubAgent = {
  name: 'coder',
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  system_prompt: 'You are a senior backend engineer.',
}

describe('ProfilesSection', () => {
  // ─── Basic rendering ────────────────────────────────────────────────
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

  // ─── Profile row events ────────────────────────────────────────────
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

  // ─── Sub-agent meta line ──────────────────────────────────────────
  it('shows "inherits top-level" when the profile has no sub-agents', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    expect(wrapper.text()).toContain('inherits top-level')
  })

  it('shows the sub-agent count and "overrides" when the profile has sub-agents', () => {
    const wrapper = mount(ProfilesSection, {
      props: {
        modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent, { ...baseSubAgent, name: 'reviewer' }] }],
        activeProfile: null,
      },
    })
    expect(wrapper.text()).toContain('2 sub-agents')
    expect(wrapper.text()).toContain('overrides top-level')
  })

  it('uses singular "sub-agent" when there is exactly one', () => {
    const wrapper = mount(ProfilesSection, {
      props: {
        modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }],
        activeProfile: null,
      },
    })
    expect(wrapper.text()).toContain('1 sub-agent')
    expect(wrapper.text()).not.toContain('1 sub-agents')
  })

  // ─── Expand / collapse ────────────────────────────────────────────
  it('does not render the sub-agents list by default (collapsed)', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    expect(wrapper.find('[data-testid="sub-agents-list-work"]').exists()).toBe(false)
  })

  it('expands the sub-agents list when the chevron is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    await wrapper.find('[data-testid="expand-btn-work"]').trigger('click')
    expect(wrapper.find('[data-testid="sub-agents-list-work"]').exists()).toBe(true)
    expect(wrapper.find(`[data-testid="profile-sub-agent-work-coder"]`).exists()).toBe(true)
  })

  it('toggles the sub-agents list when the chevron is clicked twice', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    const btn = wrapper.find('[data-testid="expand-btn-work"]')
    await btn.trigger('click')
    expect(wrapper.find('[data-testid="sub-agents-list-work"]').exists()).toBe(true)
    await btn.trigger('click')
    expect(wrapper.find('[data-testid="sub-agents-list-work"]').exists()).toBe(false)
  })

  it('shows a "no sub-agents" hint when the profile has none and is expanded', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="expand-btn-work"]').trigger('click')
    const list = wrapper.find('[data-testid="sub-agents-list-work"]')
    expect(list.exists()).toBe(true)
    expect(list.text()).toContain('No sub-agents')
  })

  // ─── Sub-agent row events ─────────────────────────────────────────
  it('emits addSubAgent with the profile name when the + Add sub-agent button is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="expand-btn-work"]').trigger('click')
    await wrapper.find('[data-testid="add-sub-agent-btn-work"]').trigger('click')
    expect(wrapper.emitted('addSubAgent')?.[0]).toEqual(['work'])
  })

  it('emits editSubAgent with profile name + sub-agent when Edit is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    await wrapper.find('[data-testid="expand-btn-work"]').trigger('click')
    await wrapper.find('[data-testid="edit-sub-agent-btn-work-coder"]').trigger('click')
    expect(wrapper.emitted('editSubAgent')?.[0]).toEqual(['work', baseSubAgent])
  })

  it('emits deleteSubAgent with profile name + sub-agent name when ⌫ is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    await wrapper.find('[data-testid="expand-btn-work"]').trigger('click')
    await wrapper.find('[data-testid="delete-sub-agent-btn-work-coder"]').trigger('click')
    expect(wrapper.emitted('deleteSubAgent')?.[0]).toEqual(['work', 'coder'])
  })

  // ─── Clear active profile ───────────────────────────────────────────
  // Plan 2026-08-06-reset-active-profile: when a profile is marked
  // active, the header shows a "Reset" button next to the pill. Clicking
  // it emits `clearActive` so the parent (NalarSettings) can save
  // `active_profile: null` to config.json. After the save, the cascade
  // in `workflow.zig::resolveProfileField` falls through to the top-level
  // config and every chat session / task uses the bare defaults.
  it('shows a Reset button next to the active pill when an active profile is set', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: 'work' },
    })
    const resetBtn = wrapper.find('[data-testid="reset-active-btn"]')
    expect(resetBtn.exists()).toBe(true)
    expect(resetBtn.text().toLowerCase()).toContain('reset')
  })

  it('does NOT show a Reset button when no active profile is set', () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    expect(wrapper.find('[data-testid="reset-active-btn"]').exists()).toBe(false)
  })

  it('emits clearActive when the Reset button is clicked', async () => {
    const wrapper = mount(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: 'work' },
    })
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')
    expect(wrapper.emitted('clearActive')).toBeTruthy()
  })

  it('keeps the Set active button hidden on the active row even when Reset is visible', () => {
    const wrapper = mount(ProfilesSection, {
      props: {
        modelValue: [baseProfile, { ...baseProfile, name: 'home' }],
        activeProfile: 'work',
      },
    })
    // The 'work' row is active → no Set active button on it
    const setActiveBtns = wrapper.findAll('[data-testid="set-active-btn"]')
    expect(setActiveBtns.length).toBe(1) // only 'home' has one
    // Reset is visible in the header
    expect(wrapper.find('[data-testid="reset-active-btn"]').exists()).toBe(true)
  })
})
