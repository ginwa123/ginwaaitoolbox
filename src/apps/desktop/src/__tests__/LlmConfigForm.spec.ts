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
}

describe('LlmConfigForm', () => {
  it('renders all 6 fields', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    expect(wrapper.find('input[placeholder="MiniMax-M2.7"]').exists()).toBe(true)
    expect(wrapper.find('input[placeholder="https://api.minimax.io/v1"]').exists()).toBe(true)
    const selects = wrapper.findAll('select')
    expect(selects.length).toBe(3) // thinking, temperature, url_style
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
})
