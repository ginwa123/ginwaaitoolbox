// KanbanChat — inline chat view for the kanban task chat.
// Replaces the former KanbanChatDialog modal overlay: no Teleport, no
// backdrop, no show prop, no Esc handling. The component renders inline
// in AppLayout's <main> v-else-if chain (replacing the board), so
// assertions use wrapper.find (NOT document.querySelector — there is
// nothing teleported to <body>).

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import KanbanChat from '../components/kanban/KanbanChat.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

function makeStubClient(): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'open',
    onStateChange: () => () => {},
  }
  return stub as SseClient
}

function installBusForTests() {
  __resetSseBus()
  installSseBus()
  __setSseBusGlobalClient(makeStubClient())
}

const TASK_A: Task = {
  id: 'task_a',
  name: 'Task Alpha',
  description: '',
} as Task

const TASK_B: Task = {
  id: 'task_b',
  name: 'Task Beta',
  description: '',
} as Task

function mountChat(props: {
  task: Task | null
  workspaceId?: string
  itemId?: string
  projectName?: string
  cwd?: string
}): VueWrapper {
  return mount(KanbanChat, {
    props,
    attachTo: document.body,
  })
}

describe('KanbanChat', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    // jsdom 29 dropped localStorage from defaults; ChatView transitively
    // loads the navigation store which reads localStorage at module-load
    // time. Install a Map-backed stub so navigation.ts can boot.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // ChatView's onMounted connects via the SSE bus. Install a stub
    // client so unhandled rejections don't bleed across tests.
    installBusForTests()
    // ChatView's onMounted queues async work (scroll-to-bottom,
    // connectSse). Fake timers prevent those from firing after
    // teardown and producing "containerRef is null" warnings.
    vi.useFakeTimers()
    setActivePinia(createPinia())
    document.body.innerHTML = ''
  })

  afterEach(() => {
    vi.useRealTimers()
    wrapper?.unmount()
    wrapper = null
    document.body.innerHTML = ''
  })

  it('renders inline with the task name in the header', async () => {
    wrapper = mountChat({
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    const root = wrapper.find('[data-testid="kanban-chat"]')
    expect(root.exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-chat-title"]').text()).toContain(
      'Task Alpha',
    )
  })

  it('renders inline — nothing is teleported to <body>', async () => {
    wrapper = mountChat({
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    // The old dialog teleported to <body> (outside the wrapper tree).
    // The inline view lives inside the wrapper — no dialog testids
    // should leak to the document level.
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog"]'),
    ).toBeNull()
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog-backdrop"]'),
    ).toBeNull()
    expect(wrapper.find('[data-testid="kanban-chat"]').exists()).toBe(true)
  })

  it('emits close when the ✕ header button is clicked', async () => {
    wrapper = mountChat({
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    const closeBtn = wrapper.find('[data-testid="kanban-chat-close"]')
    expect(closeBtn.exists()).toBe(true)
    await closeBtn.trigger('click')
    await flushPromises()
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('swaps task content when task prop changes (key contract)', async () => {
    wrapper = mountChat({
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="kanban-chat-title"]').text()).toContain(
      'Task Alpha',
    )
    // Switch task — the title should update and ChatView should remount.
    await wrapper.setProps({ task: TASK_B })
    await flushPromises()
    expect(wrapper.find('[data-testid="kanban-chat-title"]').text()).toContain(
      'Task Beta',
    )
  })

  it('shows the shell with a fallback title when task is null', async () => {
    wrapper = mountChat({
      task: null,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    // The shell renders (header), but the chat body is gated on task
    // being non-null.
    expect(wrapper.find('[data-testid="kanban-chat"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-chat-title"]').text()).toContain(
      'Chat',
    )
  })
})
