import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import McpServersSection from '../components/pabrik/McpServersSection.vue'
import type { McpServer } from '../api'

const baseServer: McpServer = {
  name: 'context7',
  url: 'https://mcp.context7.com/mcp',
  headers: [],
}

describe('McpServersSection', () => {
  it('shows the section explainer', () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [] } })
    expect(wrapper.text()).toContain('External tool providers')
  })

  it('shows the empty state when no servers exist', () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [] } })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('masks header values to first 3 + last 3 chars', () => {
    const wrapper = mount(McpServersSection, {
      props: { modelValue: [{ ...baseServer, headers: [{ key: 'X-Token', value: 'abcdef1234567890xyz' }] }] },
    })
    // 'abcdef1234567890xyz' is 19 chars; mask = first 3 + (19-6=13) asterisks + last 3
    expect(wrapper.text()).toContain('abc' + '*'.repeat(13) + 'xyz')
  })

  it('emits add when + Add server is clicked', async () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [] } })
    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.emitted('add')).toBeTruthy()
  })

  it('emits edit / delete', async () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [baseServer] } })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseServer])
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['context7'])
  })

  it('emits toggle with the server name when the toggle is clicked', async () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [baseServer] } })
    await wrapper.find('[data-testid="toggle-btn"]').trigger('click')
    expect(wrapper.emitted('toggle')?.[0]).toEqual(['context7'])
  })

  it('shows a Disabled pill + dimmed row when enabled === false', () => {
    const wrapper = mount(McpServersSection, {
      props: { modelValue: [{ ...baseServer, enabled: false }] },
    })
    expect(wrapper.find('[data-testid="disabled-pill"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="toggle-btn"]').attributes('aria-pressed')).toBe('false')
    expect(wrapper.find('li').classes()).toContain('opacity-60')
  })

  it('renders missing enabled as enabled (no pill, pressed)', () => {
    const wrapper = mount(McpServersSection, { props: { modelValue: [baseServer] } })
    expect(wrapper.find('[data-testid="disabled-pill"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="toggle-btn"]').attributes('aria-pressed')).toBe('true')
    expect(wrapper.find('li').classes()).not.toContain('opacity-60')
  })
})
