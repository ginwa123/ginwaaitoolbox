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
}

describe('DefaultsSection', () => {
  it('renders all 3 section headers', () => {
    const wrapper = mount(DefaultsSection, {
      props: { modelValue: { ...baseConfig } },
    })
    expect(wrapper.text()).toContain('Default LLM')
    expect(wrapper.text()).toContain('Model parameters')
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
})
