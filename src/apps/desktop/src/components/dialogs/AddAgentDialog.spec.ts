// Behavioural tests for AddAgentDialog. Mirrors AddKanbanDialog.spec.ts.

import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AddAgentDialog from './AddAgentDialog.vue'

describe('AddAgentDialog', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the "Add Agent" title and a name input when show=true', async () => {
    const wrapper = mount(AddAgentDialog, { props: { show: true } })
    await nextTick()
    const dialog = wrapper.find('[data-testid="add-agent-dialog"]').element as HTMLElement | null
    expect(dialog?.textContent).toContain('Add Agent')
    expect(wrapper.find('[data-testid="add-agent-name"]').exists()).toBe(true)
  })

  it('disables the Add button when name or path is empty', async () => {
    const wrapper = mount(AddAgentDialog, { props: { show: true } })
    await nextTick()
    const submit = wrapper.find('[data-testid="add-agent-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })

  it('emits "create" with (name, path) when Add is clicked with valid input', async () => {
    const wrapper = mount(AddAgentDialog, { props: { show: true } })
    await nextTick()
    await wrapper.find('[data-testid="add-agent-name"]').setValue('My Agent')
    // selectedPath is set via FilePickerDialog select — for the test,
    // we set it via the Vue ref directly.
    wrapper.vm.selectedPath = '/tmp/agent'
    await wrapper.find('[data-testid="add-agent-submit"]').trigger('click')
    const events = wrapper.emitted('create')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual(['My Agent', '/tmp/agent'])
  })

  it('emits "close" when Cancel is clicked', async () => {
    const wrapper = mount(AddAgentDialog, { props: { show: true } })
    await nextTick()
    await wrapper.find('[data-testid="add-agent-cancel"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})