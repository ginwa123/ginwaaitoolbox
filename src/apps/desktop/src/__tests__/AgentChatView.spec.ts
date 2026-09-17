// Behavioural tests for AgentChatView (inline, non-dialog).

import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentChatView from '../components/views/AgentChatView.vue'

// Stub ChatView — it transitively pulls in many Pinia stores
// (useNavigationStore, useWorkspacesStore, etc.) and a real SSE bus
// instance, none of which we need to exercise here. We're only
// asserting AgentChatView's wrapper behaviour.
vi.mock('../components/views/ChatView.vue', () => ({
  default: {
    name: 'ChatView',
    props: ['workspaceId', 'taskId'],
    template: '<div data-testid="stub-chat-view">stub</div>',
  },
}))

function mountChatView(props: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  return mount(AgentChatView, {
    attachTo: document.body,
    props: {
      task: { id: 'task_1', name: 'Test Chat' },
      workspaceId: 'ws_1',
      itemId: 'item_1',
      cwd: '/tmp/agent',
      ...props,
    },
  })
}

describe('AgentChatView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('renders inline without Teleport/dialog chrome', async () => {
    mountChatView()
    await nextTick()
    expect(document.querySelector('[data-testid="agent-chat-view"]')).toBeTruthy()
    // No dialog overlay, no backdrop, no aria-modal popup.
    expect(document.querySelector('[data-testid="agent-chat-dialog"]')).toBeFalsy()
    expect(document.querySelector('[role="dialog"]')).toBeFalsy()
  })

  it('emits close when close button clicked', async () => {
    const wrapper = mountChatView()
    await nextTick()
    const closeBtn = document.querySelector('[data-testid="agent-chat-close"]') as HTMLButtonElement
    closeBtn.click()
    await nextTick()
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('falls back to default title when task has no name', async () => {
    mountChatView({ task: { id: 'task_1' } })
    await nextTick()
    expect(document.body.textContent).toContain('Agent Chat')
  })

  it('uses the shared content bg so agent chats match standalone + design chats', async () => {
    mountChatView()
    await nextTick()
    const root = document.querySelector('[data-testid="agent-chat-view"]') as HTMLElement
    expect(root.getAttribute('style')).toContain('--semantic-content-bg')
    expect(root.getAttribute('style')).not.toContain('--semantic-card-bg')
  })
})
