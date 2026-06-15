import { mount } from '@vue/test-utils'
import { describe, expect, it, vi } from 'vitest'

import EmptyState from '../components/nalar/EmptyState.vue'

describe('EmptyState', () => {
  it('renders the title and description', () => {
    const wrapper = mount(EmptyState, {
      props: {
        glyph: '⌗',
        title: 'No profiles yet',
        description: 'Profiles are saved LLM configurations.',
      },
    })
    expect(wrapper.text()).toContain('No profiles yet')
    expect(wrapper.text()).toContain('saved LLM configurations')
    expect(wrapper.text()).toContain('⌗')
  })

  it('renders the CTA button when ctaLabel + ctaAction are provided', () => {
    const onCta = vi.fn()
    const wrapper = mount(EmptyState, {
      props: {
        glyph: '⌗',
        title: 'No profiles yet',
        description: 'desc',
        ctaLabel: 'Add profile',
        ctaAction: onCta,
      },
    })
    const button = wrapper.find('button')
    expect(button.exists()).toBe(true)
    expect(button.text()).toBe('Add profile')
  })

  it('omits the CTA button when ctaLabel is not provided', () => {
    const wrapper = mount(EmptyState, {
      props: { glyph: '⌗', title: 't', description: 'd' },
    })
    expect(wrapper.find('button').exists()).toBe(false)
  })
})
