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

  it('renders all 3 tab labels in order: General / Profiles / MCP Servers (no Sub-agents)', () => {
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // General tab is the FIRST tab. Tab order matters — operational
    // settings (notification toggles + retry delay) belong at the top.
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'general' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    // Plan 2026-09-04-subagents-per-profile: global Sub-agents tab removed.
    expect(buttons.map(b => b.text().trim())).toEqual([
      'General', 'Profiles', 'MCP Servers',
    ])
  })

  it('does NOT render the Compaction or Defaults tabs', () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'general' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.some(b => b.text().trim() === 'Compaction')).toBe(false)
    expect(buttons.some(b => b.text().trim() === 'Defaults')).toBe(false)
  })

  it('emits update:modelValue when a tab is clicked', async () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'general' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.length).toBe(3)
    await buttons[2]!.trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['mcp'])
  })

  it('marks the active tab with aria-selected=true', () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'mcp' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.length).toBe(3)
    expect(buttons[0]!.attributes('aria-selected')).toBe('false')
    expect(buttons[2]!.attributes('aria-selected')).toBe('true')
  })

  it('persists the active tab to localStorage when the modelValue prop changes', async () => {
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'general' },
    })
    // Simulate the parent applying v-model after the click.
    await wrapper.setProps({ modelValue: 'mcp' })
    expect(localStorage.getItem('nalar-settings-active-tab')).toBe('mcp')
  })

  it('emits update:modelValue on mount to restore the active tab from localStorage', () => {
    localStorage.setItem('nalar-settings-active-tab', 'mcp')
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'general' },
    })
    // The onMounted hook fires the update so the parent picks up
    // the saved tab.
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['mcp'])
  })

  it('emits "general" when the General tab is clicked', async () => {
    // Explicit test for the NEW tab — lock in the wire value so a
    // future rename doesn't silently break the parent (which uses
    // this exact string in the type Tab = 'general' | ...).
    const wrapper = mount(NalarTabStrip, {
      props: { modelValue: 'profiles' },
    })
    const buttons = wrapper.findAll('button[role="tab"]')
    expect(buttons.length).toBe(3)
    await buttons[0]!.trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['general'])
  })
})
