// Behavioural tests for AgentChatDialog.

import { describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

describe('AgentChatDialog', () => {
  it('renders the dialog when show=true', async () => {
    const { default: AgentChatDialog } = await import('../components/dialogs/AgentChatDialog.vue')
    const wrapper = mount(AgentChatDialog, {
      props: {
        show: true,
        task: { id: 'task_1', name: 'Test Chat' },
        workspaceId: 'ws_1',
        itemId: 'item_1',
        cwd: '/tmp/agent',
      },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="agent-chat-dialog"]').exists()).toBe(true)
  })

  it('emits close when close button clicked', async () => {
    const { default: AgentChatDialog } = await import('../components/dialogs/AgentChatDialog.vue')
    const wrapper = mount(AgentChatDialog, {
      props: {
        show: true,
        task: { id: 'task_1' },
        workspaceId: 'ws_1',
        itemId: 'item_1',
        cwd: '/tmp',
      },
    })
    await nextTick()
    await wrapper.find('[data-testid="agent-chat-close"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('does not render when show=false', async () => {
    const { default: AgentChatDialog } = await import('../components/dialogs/AgentChatDialog.vue')
    const wrapper = mount(AgentChatDialog, {
      props: {
        show: false,
        task: { id: 'task_1' },
        workspaceId: 'ws_1',
        itemId: 'item_1',
        cwd: '/tmp',
      },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="agent-chat-dialog"]').exists()).toBe(false)
  })
})