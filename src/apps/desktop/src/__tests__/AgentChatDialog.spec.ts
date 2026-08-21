// Behavioural tests for AgentChatDialog.

import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentChatDialog from '../components/dialogs/AgentChatDialog.vue'

// Stub ChatView — it transitively pulls in many Pinia stores
// (useNavigationStore, useWorkspacesStore, etc.) and a real SSE bus
// instance, none of which we need to exercise here. We're only
// asserting AgentChatDialog's wrapper behaviour.
vi.mock('../components/views/ChatView.vue', () => ({
  default: {
    name: 'ChatView',
    props: ['workspaceId', 'taskId'],
    template: '<div data-testid="stub-chat-view">stub</div>',
  },
}))

function mountChatDialog(props: Record<string, unknown> = {}) {
  // The dialog uses <Teleport to="body">, so we attach to document.body
  // and search via document.querySelector. Same pattern as
  // AddAgentDialog.spec.ts / AgentKnowledgeDialog.spec.ts.
  document.body.innerHTML = ''
  return mount(AgentChatDialog, {
    attachTo: document.body,
    props: {
      show: true,
      task: { id: 'task_1', name: 'Test Chat' },
      workspaceId: 'ws_1',
      itemId: 'item_1',
      cwd: '/tmp/agent',
      ...props,
    },
  })
}

describe('AgentChatDialog', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('renders the dialog when show=true', async () => {
    mountChatDialog()
    await nextTick()
    expect(document.querySelector('[data-testid="agent-chat-dialog"]')).toBeTruthy()
  })

  it('emits close when close button clicked', async () => {
    const wrapper = mountChatDialog()
    await nextTick()
    const closeBtn = document.querySelector('[data-testid="agent-chat-close"]') as HTMLButtonElement
    closeBtn.click()
    await nextTick()
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('does not render when show=false', async () => {
    mountChatDialog({ show: false })
    await nextTick()
    expect(document.querySelector('[data-testid="agent-chat-dialog"]')).toBeFalsy()
  })
})
