import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import LlmConfigForm from '../components/nalar/LlmConfigForm.vue'

const baseValue = {
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  // Plan 2026-07-07-compaction-inline: per-profile compaction overrides.
  max_capacity_tokens: null as number | null,
  compaction_threshold_percent: null as number | null,
  // Plan 2026-08-23-model-thinking: model-thinking knobs.
  thinking_budget_tokens: null as number | null,
  reasoning_effort: null as 'low' | 'medium' | 'high' | 'auto' | null,
}

describe('LlmConfigForm', () => {
  it('renders all 6 fields', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    expect(wrapper.find('input[placeholder="MiniMax-M2.7"]').exists()).toBe(true)
    expect(wrapper.find('input[placeholder="https://api.minimax.io/v1"]').exists()).toBe(true)
    const selects = wrapper.findAll('select')
    // thinking, temperature, url_style, reasoning_effort — 4 selects.
    // (plan 2026-08-23-model-thinking added reasoning_effort.)
    expect(selects.length).toBe(4)
  })

  it('hides the API key by default (type=password)', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue, api_key: 'sk-secret' } } })
    const keyInput = wrapper.find('[data-testid="api-key-input"]')
    expect(keyInput.attributes('type')).toBe('password')
  })

  it('toggles the API key to type=text when the show button is clicked', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue, api_key: 'sk-secret' } } })
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('text')
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('password')
  })

  it('emits update:modelValue when the model field changes', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const modelInput = wrapper.find('input[placeholder="MiniMax-M2.7"]')
    await modelInput.setValue('gpt-4o')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{ ...baseValue, model: 'gpt-4o' }])
  })

  it('shows a validation error under the model field when errors.model is set', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue }, errors: { model: 'Model is required' } },
    })
    expect(wrapper.text()).toContain('Model is required')
  })

  // ─── Plan 2026-07-07-compaction-inline: Compaction overrides ───

  it('renders the capacity-override checkbox unchecked when null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const checkbox = wrapper.find('[data-testid="profile-capacity-override-checkbox"]')
    expect((checkbox.element as HTMLInputElement).checked).toBe(false)
  })

  it('disables the capacity input when override is null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).disabled).toBe(true)
  })

  it('enables the capacity input when override is set', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, max_capacity_tokens: 400000 } },
    })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).disabled).toBe(false)
    expect((input.element as HTMLInputElement).value).toBe('400000')
  })

  it('toggling the profile capacity checkbox on emits a seed value', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    await wrapper.find('[data-testid="profile-capacity-override-checkbox"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.max_capacity_tokens).toBe(500000)
  })

  it('toggling the profile capacity checkbox off emits null', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, max_capacity_tokens: 350000 } },
    })
    await wrapper.find('[data-testid="profile-capacity-override-checkbox"]').setValue(false)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.max_capacity_tokens).toBeNull()
  })

  it('renders the threshold-override checkbox unchecked when null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const checkbox = wrapper.find('[data-testid="profile-threshold-override-checkbox"]')
    expect((checkbox.element as HTMLInputElement).checked).toBe(false)
  })

  it('disables the threshold slider when override is null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const slider = wrapper.find('[data-testid="profile-threshold-slider"]')
    expect((slider.element as HTMLInputElement).disabled).toBe(true)
  })

  it('renders threshold slider value when override is set', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, compaction_threshold_percent: 60 } },
    })
    const slider = wrapper.find('[data-testid="profile-threshold-slider"]')
    expect((slider.element as HTMLInputElement).value).toBe('60')
    expect((slider.element as HTMLInputElement).disabled).toBe(false)
  })

  it('toggling the profile threshold checkbox on emits 80', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    await wrapper.find('[data-testid="profile-threshold-override-checkbox"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.compaction_threshold_percent).toBe(80)
  })

  it('profile threshold slider clamps to 0-100 range', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, compaction_threshold_percent: 50 } },
    })
    await wrapper.find('[data-testid="profile-threshold-slider"]').setValue('120')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.compaction_threshold_percent).toBe(100)  // clamped
  })
})
