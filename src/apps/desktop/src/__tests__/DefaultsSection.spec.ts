import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import DefaultsSection from '../components/nalar/DefaultsSection.vue'

const baseConfig = {
  api_endpoint: '',
  api_key: '',
  model: '',
  url_style: 'openai' as const,
  temperature: 0.7,
  max_tokens: '',
  system_prompt: '',
  notify_on_complete: false,
  // Plan 2026-07-07-compaction-inline: top-level compaction defaults.
  max_capacity_token_model: null as number | null,
  compaction_threshold_percent: null as number | null,
}

describe('DefaultsSection', () => {
  it('renders all 4 section headers', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    expect(wrapper.text()).toContain('Default LLM')
    expect(wrapper.text()).toContain('Model parameters')
    expect(wrapper.text()).toContain('Compaction defaults')
    expect(wrapper.text()).toContain('System prompt')
  })

  it('emits update:modelValue when api_endpoint changes', async () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const input = wrapper.find('[data-testid="api-endpoint-input"]')
    await input.setValue('https://api.test/v1')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{
      ...baseConfig,
      api_endpoint: 'https://api.test/v1',
    }])
  })

  it('renders the temperature slider with the current value', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, temperature: 1.2 } },
    })
    const slider = wrapper.find('[data-testid="temperature-slider"]')
    expect((slider.element as HTMLInputElement).value).toBe('1.2')
  })

  it('shows the approximate token count for the system prompt', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, system_prompt: 'one two three four five' } },
    })
    // 5 words * 1.3 = 6.5 -> ceil = 7
    expect(wrapper.text()).toMatch(/~ ?7 tokens/)
  })

  // ─── Plan 2026-07-07-compaction-inline: Compaction defaults ───

  it('renders the capacity-override checkbox unchecked when null', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const checkbox = wrapper.find('[data-testid="defaults-capacity-override-checkbox"]')
    expect((checkbox.element as HTMLInputElement).checked).toBe(false)
  })

  it('disables the capacity input when override is null', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const input = wrapper.find('[data-testid="defaults-capacity-input"]')
    expect((input.element as HTMLInputElement).disabled).toBe(true)
  })

  it('enables the capacity input when override is set', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, max_capacity_token_model: 200000 } },
    })
    const input = wrapper.find('[data-testid="defaults-capacity-input"]')
    expect((input.element as HTMLInputElement).disabled).toBe(false)
    expect((input.element as HTMLInputElement).value).toBe('200000')
  })

  it('toggling the capacity-override checkbox emits the value', async () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const checkbox = wrapper.find('[data-testid="defaults-capacity-override-checkbox"]')
    await checkbox.setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseConfig
    expect(emitted.max_capacity_token_model).not.toBeNull()
    // Default seed value is 500_000 when null → toggle on.
    expect(emitted.max_capacity_token_model).toBe(500000)
  })

  it('toggling the capacity-override checkbox off emits null', async () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, max_capacity_token_model: 250000 } },
    })
    const checkbox = wrapper.find('[data-testid="defaults-capacity-override-checkbox"]')
    await checkbox.setValue(false)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseConfig
    expect(emitted.max_capacity_token_model).toBeNull()
  })

  it('renders the threshold-override checkbox unchecked when null', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const checkbox = wrapper.find('[data-testid="defaults-threshold-override-checkbox"]')
    expect((checkbox.element as HTMLInputElement).checked).toBe(false)
  })

  it('disables the threshold slider when override is null', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const slider = wrapper.find('[data-testid="defaults-threshold-slider"]')
    expect((slider.element as HTMLInputElement).disabled).toBe(true)
  })

  it('renders threshold slider value when override is set', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, compaction_threshold_percent: 70 } },
    })
    const slider = wrapper.find('[data-testid="defaults-threshold-slider"]')
    expect((slider.element as HTMLInputElement).value).toBe('70')
    expect((slider.element as HTMLInputElement).disabled).toBe(false)
  })

  it('toggling the threshold-override checkbox on emits the default 80', async () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const checkbox = wrapper.find('[data-testid="defaults-threshold-override-checkbox"]')
    await checkbox.setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseConfig
    expect(emitted.compaction_threshold_percent).toBe(80)
  })

  it('threshold slider input clamps to 0-100 range', async () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig, compaction_threshold_percent: 50 } },
    })
    const slider = wrapper.find('[data-testid="defaults-threshold-slider"]')
    await slider.setValue('150')  // try to set > 100
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseConfig
    expect(emitted.compaction_threshold_percent).toBe(100)  // clamped
  })
})
