// Vitest tests for the model-thinking fields in LlmConfigForm.vue
// (plan 2026-08-23-model-thinking).
//
// Covers:
//  - The new fields are wired into the form data interface.
//  - When `thinking === 'off'`, the budget + effort row is hidden.
//  - When `thinking === 'auto'` or `'on'`, both fields are visible.
//  - The input emits `null` for blank values, parsed integers for
//    valid input, and clamps to >= 1024.

import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import LlmConfigForm from '../components/nalar/LlmConfigForm.vue'

const baseConfig = {
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  max_capacity_tokens: null,
  compaction_threshold_percent: null,
  thinking_budget_tokens: null,
  reasoning_effort: null,
}

describe('LlmConfigForm Thinking fields', () => {
  it('hides budget + effort fields when thinking=off', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, thinking: 'off' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('shows both fields when thinking=on', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, thinking: 'on' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
  })

  it('shows both fields when thinking=auto', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, thinking: 'auto' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
  })

  it('emits null when thinking_budget_tokens input is cleared', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, thinking_budget_tokens: 4096 } },
    })
    const input = wrapper.find('[data-testid=thinking-budget-input]')
    await input.setValue('')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
    expect(emitted?.thinking_budget_tokens).toBeNull()
  })

  it('emits clamped integer when thinking_budget_tokens input is below 1024', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseConfig } },
    })
    const input = wrapper.find('[data-testid=thinking-budget-input]')
    await input.setValue('500')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
    // Floor is 1024 — anything below clamps to 1024.
    expect(emitted?.thinking_budget_tokens).toBe(1024)
  })

  it('emits null when reasoning_effort select is set to Auto (empty)', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, reasoning_effort: 'high' } },
    })
    const select = wrapper.find('[data-testid=reasoning-effort-select]')
    await select.setValue('')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
    expect(emitted?.reasoning_effort).toBeNull()
  })

  it('emits low/medium/high when reasoning_effort is changed', async () => {
    for (const v of ['low', 'medium', 'high'] as const) {
      const wrapper = mount(LlmConfigForm, {
        props: { modelValue: { ...baseConfig, reasoning_effort: null } },
      })
      const select = wrapper.find('[data-testid=reasoning-effort-select]')
      await select.setValue(v)
      const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
      expect(emitted?.reasoning_effort).toBe(v)
    }
  })
})
