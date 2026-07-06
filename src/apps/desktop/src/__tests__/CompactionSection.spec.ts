import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import CompactionSection from '../components/nalar/CompactionSection.vue'

const baseConfig = {
  max_capacity_token_model: null as number | null,
  compaction_threshold_percent: null as number | null,
}

describe('CompactionSection', () => {
  it('renders the section root and intro paragraph', () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { ...baseConfig } },
    })
    expect(wrapper.find('[data-testid="compaction-section"]').exists()).toBe(true)
    expect(wrapper.text()).toMatch(/Built-in defaults/)
  })

  it('renders both section headers', () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { ...baseConfig } },
    })
    expect(wrapper.text()).toContain('Context window')
    expect(wrapper.text()).toContain('Compaction threshold')
  })

  it('capacity input is disabled and shows placeholder when override is OFF', () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="capacity-input"]')
    expect(input.element.disabled).toBe(true)
    expect(input.element.value).toBe('')
    expect(input.element.placeholder).toBe('500000')
  })

  it('threshold slider is disabled when override is OFF', () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const slider = wrapper.find<HTMLInputElement>('[data-testid="threshold-slider"]')
    expect(slider.element.disabled).toBe(true)
    // When OFF, the slider still mirrors the backend default (80).
    expect(slider.element.value).toBe('80')
  })

  it('checking the capacity override checkbox seeds the field with a non-null value', async () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { ...baseConfig } },
    })
    const checkbox = wrapper.find<HTMLInputElement>('[data-testid="capacity-override-checkbox"]')
    expect(checkbox.element.checked).toBe(false)
    await checkbox.setValue(true)
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{
      max_capacity_token_model: 500000,
      compaction_threshold_percent: null,
    }])
  })

  it('unchecking the capacity override checkbox emits null', async () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { max_capacity_token_model: 256000, compaction_threshold_percent: null } },
    })
    const checkbox = wrapper.find<HTMLInputElement>('[data-testid="capacity-override-checkbox"]')
    expect(checkbox.element.checked).toBe(true)
    await checkbox.setValue(false)
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{
      max_capacity_token_model: null,
      compaction_threshold_percent: null,
    }])
  })

  it('changing the capacity input emits the typed value', async () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { max_capacity_token_model: 200000, compaction_threshold_percent: null } },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="capacity-input"]')
    await input.setValue('128000')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{
      max_capacity_token_model: 128000,
      compaction_threshold_percent: null,
    }])
  })

  it('changing the threshold slider emits the new value, clamped to 0-100', async () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { max_capacity_token_model: null, compaction_threshold_percent: 80 } },
    })
    const slider = wrapper.find<HTMLInputElement>('[data-testid="threshold-slider"]')
    await slider.setValue('60')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{
      max_capacity_token_model: null,
      compaction_threshold_percent: 60,
    }])
  })

  it('unchecking the threshold override checkbox emits null', async () => {
    const wrapper = mount(CompactionSection, {
      props: { modelValue: { max_capacity_token_model: null, compaction_threshold_percent: 70 } },
    })
    const checkbox = wrapper.find<HTMLInputElement>('[data-testid="threshold-override-checkbox"]')
    expect(checkbox.element.checked).toBe(true)
    await checkbox.setValue(false)
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{
      max_capacity_token_model: null,
      compaction_threshold_percent: null,
    }])
  })

  it('renders the override checkbox states correctly based on field values', () => {
    const enabled = mount(CompactionSection, {
      props: { modelValue: { max_capacity_token_model: 256000, compaction_threshold_percent: 60 } },
    })
    expect((enabled.find<HTMLInputElement>('[data-testid="capacity-override-checkbox"]').element.checked)).toBe(true)
    expect((enabled.find<HTMLInputElement>('[data-testid="threshold-override-checkbox"]').element.checked)).toBe(true)

    const disabled = mount(CompactionSection, {
      props: { modelValue: { max_capacity_token_model: null, compaction_threshold_percent: null } },
    })
    expect((disabled.find<HTMLInputElement>('[data-testid="capacity-override-checkbox"]').element.checked)).toBe(false)
    expect((disabled.find<HTMLInputElement>('[data-testid="threshold-override-checkbox"]').element.checked)).toBe(false)
  })
})
