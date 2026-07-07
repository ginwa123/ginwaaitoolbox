import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import CompactionSection from '../components/nalar/CompactionSection.vue'
import type { NalarProfile } from '../api'

/**
 * CompactionSection — per-profile compaction settings UI (Chunk 7).
 *
 * The component iterates `props.profiles` and renders one row per
 * entry. Each row exposes two overrides:
 *   - `max_capacity_tokens`        — context window (in tokens)
 *   - `compaction_threshold_percent` — compaction trigger (0-100)
 *
 * The v-model contract is `{ profiles: Record<string, NalarProfile> }`.
 * The component emits `update:profiles` on every field change with the
 * full profiles map (the parent is responsible for diffing + save).
 */

const baseProfile: NalarProfile = {
  model: 'MiniMax-M3',
  base_url: 'https://api.minimax.io/v1',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: 'test-key',
  max_capacity_tokens: null,
  compaction_threshold_percent: null,
}

function makeProfiles(entries: Record<string, Partial<NalarProfile>>): Record<string, NalarProfile> {
  const out: Record<string, NalarProfile> = {}
  for (const [name, override] of Object.entries(entries)) {
    out[name] = { ...baseProfile, ...override }
  }
  return out
}

/**
 * Pulls the latest emitted profiles map out of a mounted
 * CompactionSection wrapper. Returns the typed value or throws if no
 * emission happened (test bug — caller forgot to trigger an input).
 */
function getEmittedProfiles(wrapper: ReturnType<typeof mount>): Record<string, NalarProfile> {
  const emitted = wrapper.emitted('update:profiles');
  expect(emitted).toBeDefined();
  const latest = emitted?.[0]?.[0];
  expect(latest).toBeDefined();
  return latest as Record<string, NalarProfile>;
}

describe('CompactionSection (per-profile)', () => {
  it('renders the section root and intro paragraph', () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: {} }) },
    })
    expect(wrapper.find('[data-testid="compaction-section"]').exists()).toBe(true)
    expect(wrapper.text()).toMatch(/per profile/)
  })

  it('renders one row per profile with the profile name and model', () => {
    const wrapper = mount(CompactionSection, {
      props: {
        profiles: makeProfiles({
          dev: { model: 'MiniMax-M2.7' },
          prod: { model: 'MiniMax-M3' },
        }),
      },
    })
    expect(wrapper.find('[data-testid="profile-row-dev"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="profile-row-prod"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('dev')
    expect(wrapper.text()).toContain('prod')
    expect(wrapper.text()).toContain('MiniMax-M2.7')
    expect(wrapper.text()).toContain('MiniMax-M3')
  })

  it('shows the empty-state hint when no profiles are defined', () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: {} },
    })
    expect(wrapper.find('[data-testid="compaction-empty-state"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="profile-row-dev"]').exists()).toBe(false)
  })

  it('per-profile capacity input is disabled and shows placeholder when override is null', () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { max_capacity_tokens: null } }) },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="capacity-input-dev"]')
    expect(input.element.disabled).toBe(true)
    expect(input.element.value).toBe('')
    expect(input.element.placeholder).toBe('500000')
  })

  it('per-profile threshold slider is disabled when override is null', () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { compaction_threshold_percent: null } }) },
    })
    const slider = wrapper.find<HTMLInputElement>('[data-testid="threshold-slider-dev"]')
    expect(slider.element.disabled).toBe(true)
    // When null, the slider mirrors the backend default (80).
    expect(slider.element.value).toBe('80')
  })

  it('checking the capacity override checkbox seeds the field with a non-null value', async () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { max_capacity_tokens: null } }) },
    })
    const checkbox = wrapper.find<HTMLInputElement>('[data-testid="capacity-override-checkbox-dev"]')
    expect(checkbox.element.checked).toBe(false)
    await checkbox.setValue(true)
    const profiles = getEmittedProfiles(wrapper)
    const dev = profiles.dev
    expect(dev).toBeDefined()
    expect(dev!.max_capacity_tokens).not.toBeNull()
    expect(dev!.max_capacity_tokens as number).toBeGreaterThan(0)
  })

  it('unchecking the capacity override checkbox emits null', async () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { max_capacity_tokens: 256000 } }) },
    })
    const checkbox = wrapper.find<HTMLInputElement>('[data-testid="capacity-override-checkbox-dev"]')
    expect(checkbox.element.checked).toBe(true)
    await checkbox.setValue(false)
    const profiles = getEmittedProfiles(wrapper)
    const dev = profiles.dev
    expect(dev).toBeDefined()
    expect(dev!.max_capacity_tokens).toBeNull()
  })

  it('changing the capacity input emits the typed value', async () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { max_capacity_tokens: 200000 } }) },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="capacity-input-dev"]')
    await input.setValue('128000')
    const profiles = getEmittedProfiles(wrapper)
    const dev = profiles.dev
    expect(dev).toBeDefined()
    expect(dev!.max_capacity_tokens).toBe(128000)
  })

  it('changing the threshold slider emits the new value, clamped to 0-100', async () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { compaction_threshold_percent: 80 } }) },
    })
    const slider = wrapper.find<HTMLInputElement>('[data-testid="threshold-slider-dev"]')
    await slider.setValue('60')
    const profiles = getEmittedProfiles(wrapper)
    const dev = profiles.dev
    expect(dev).toBeDefined()
    expect(dev!.compaction_threshold_percent).toBe(60)
  })

  it('unchecking the threshold override checkbox emits null', async () => {
    const wrapper = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { compaction_threshold_percent: 70 } }) },
    })
    const checkbox = wrapper.find<HTMLInputElement>('[data-testid="threshold-override-checkbox-dev"]')
    expect(checkbox.element.checked).toBe(true)
    await checkbox.setValue(false)
    const profiles = getEmittedProfiles(wrapper)
    const dev = profiles.dev
    expect(dev).toBeDefined()
    expect(dev!.compaction_threshold_percent).toBeNull()
  })

  it('checkbox states reflect the per-profile override values', () => {
    const enabled = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { max_capacity_tokens: 256000, compaction_threshold_percent: 60 } }) },
    })
    expect(enabled.find<HTMLInputElement>('[data-testid="capacity-override-checkbox-dev"]').element.checked).toBe(true)
    expect(enabled.find<HTMLInputElement>('[data-testid="threshold-override-checkbox-dev"]').element.checked).toBe(true)

    const disabled = mount(CompactionSection, {
      props: { profiles: makeProfiles({ dev: { max_capacity_tokens: null, compaction_threshold_percent: null } }) },
    })
    expect(disabled.find<HTMLInputElement>('[data-testid="capacity-override-checkbox-dev"]').element.checked).toBe(false)
    expect(disabled.find<HTMLInputElement>('[data-testid="threshold-override-checkbox-dev"]').element.checked).toBe(false)
  })

  it('emits updates for one profile without affecting sibling profiles', async () => {
    const wrapper = mount(CompactionSection, {
      props: {
        profiles: makeProfiles({
          dev: { max_capacity_tokens: null },
          prod: { max_capacity_tokens: 400000 },
        }),
      },
    })
    // Toggle dev's capacity override ON.
    const checkbox = wrapper.find<HTMLInputElement>('[data-testid="capacity-override-checkbox-dev"]')
    await checkbox.setValue(true)
    const profiles = getEmittedProfiles(wrapper)
    const dev = profiles.dev
    const prod = profiles.prod
    expect(dev).toBeDefined()
    expect(prod).toBeDefined()
    // dev: now has a non-null capacity.
    expect(dev!.max_capacity_tokens).not.toBeNull()
    // prod: untouched (400000 preserved).
    expect(prod!.max_capacity_tokens).toBe(400000)
  })
})