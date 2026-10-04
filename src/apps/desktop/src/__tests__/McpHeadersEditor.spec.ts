import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import McpHeadersEditor from '../components/pabrik/McpHeadersEditor.vue'

describe('McpHeadersEditor', () => {
  it('renders a row per header', () => {
    const wrapper = mount(McpHeadersEditor, {
      props: { modelValue: [{ key: 'A', value: '1' }, { key: 'B', value: '2' }] },
    })
    const rows = wrapper.findAll('[data-testid="header-row"]')
    expect(rows.length).toBe(2)
  })

  it('shows the empty state when there are no headers', () => {
    const wrapper = mount(McpHeadersEditor, { props: { modelValue: [] } })
    expect(wrapper.text()).toContain('No headers')
  })

  it('adds a new empty header when Add header is clicked', async () => {
    const wrapper = mount(McpHeadersEditor, { props: { modelValue: [] } })
    await wrapper.find('[data-testid="add-header"]').trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([[{ key: '', value: '' }]])
  })

  it('removes a header when its ✕ is clicked', async () => {
    const wrapper = mount(McpHeadersEditor, {
      props: { modelValue: [{ key: 'A', value: '1' }, { key: 'B', value: '2' }] },
    })
    const removeButtons = wrapper.findAll('[data-testid="remove-header"]')
    expect(removeButtons.length).toBe(2)
    await removeButtons[0]!.trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([[{ key: 'B', value: '2' }]])
  })
})
