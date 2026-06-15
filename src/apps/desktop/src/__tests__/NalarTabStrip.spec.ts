import { mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it } from 'vitest'

import NalarTabStrip from '../components/nalar/NalarTabStrip.vue'
import { makeLocalStorageStub } from './helpers'

/**
 * Test pattern: NalarTabStrip is a controlled component. Clicking a
 * tab emits `update:modelValue`; the parent (NalarSettings.vue) is
 * expected to update the bound prop. The component's `watch` on
 * `modelValue` then writes to localStorage. To simulate this in
 * tests, we react to the emit by calling `wrapper.setProps(...)`.
 */

describe('NalarTabStrip', () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('renders all 4 tab labels in order', () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.map(b => b.text().trim())).toEqual([
      'Defaults', 'Profiles', 'Sub-agents', 'MCP Servers',
    ])
  })

  it('emits update:modelValue when a tab is clicked', async () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    await wrapper.findAll('button[role="tab"]')[1].trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['profiles'])
  })

  it('marks the active tab with aria-selected=true', () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'sub-agents' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons[0].attributes('aria-selected')).toBe('false')
    expect(buttons[2].attributes('aria-selected')).toBe('true')
  })

  it('persists the active tab to localStorage when the modelValue prop changes', async () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    // Simulate the parent applying v-model after the click.
    await wrapper.setProps({ modelValue: 'mcp' })
    expect(localStorage.getItem('nalar-settings-active-tab')).toBe('mcp')
  })

  it('emits update:modelValue on mount to restore the active tab from localStorage', () => {
    localStorage.setItem('nalar-settings-active-tab', 'profiles')
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'defaults' },
    })
    // The onMounted hook fires the update so the parent picks up
    // the saved tab.
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['profiles'])
  })
})
