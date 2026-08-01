// KanbanChatDialog — centred modal dialog that wraps <ChatView> for the
// kanban task chat. Tests follow the project's established Teleport-based
// dialog pattern (see vue-teleport-vitest-document-queryselector skill):
//   - attachTo: document.body so the wrapper stays alive
//   - document.querySelector for DOM assertions (NOT wrapper.find — the
//     teleported content is not in the wrapper's DOM tree)
//   - afterEach: wrapper.unmount() + force-remove teleported nodes

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import KanbanChatDialog from '../components/kanban/KanbanChatDialog.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

function makeStubClient(): SseClient {
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

function mountDialog(props: {
  show: boolean
  task: Task | null
  workspaceId?: string
  itemId?: string
  projectName?: string
  cwd?: string
}): VueWrapper {
  return mount(KanbanChatDialog, {
    props,
    attachTo: document.body,
  })
}

describe('KanbanChatDialog', () => {
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
    // Defensive: remove any leftover teleported dialog nodes
    document
      .querySelectorAll('[data-testid="kanban-chat-dialog"]')
      .forEach((el) => el.remove())
    document
      .querySelectorAll('[data-testid="kanban-chat-dialog-root"]')
      .forEach((el) => el.remove())
  })

  it('does not render when show=false', async () => {
    wrapper = mountDialog({
      show: false,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog"]'),
    ).toBeNull()
  })

  it('renders when show=true with a task', async () => {
    wrapper = mountDialog({
      show: true,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    const dialog = document.querySelector('[data-testid="kanban-chat-dialog"]')
    expect(dialog).not.toBeNull()
    const title = document.querySelector('[data-testid="kanban-chat-dialog-title"]')
    expect(title?.textContent).toContain('Task Alpha')
  })

  it('emits update:show=false when backdrop is clicked', async () => {
    wrapper = mountDialog({
      show: true,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    const backdrop = document.querySelector(
      '[data-testid="kanban-chat-dialog-backdrop"]',
    ) as HTMLElement
    expect(backdrop).not.toBeNull()
    backdrop.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')).toBeTruthy()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
  })

  it('does NOT close when click inside the dialog panel (not backdrop)', async () => {
    wrapper = mountDialog({
      show: true,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    const panel = document.querySelector(
      '[data-testid="kanban-chat-dialog"]',
    ) as HTMLElement
    expect(panel).not.toBeNull()
    panel.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('emits update:show=false when Escape key is pressed', async () => {
    wrapper = mountDialog({
      show: true,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    // The dialog listens via @keydown on the teleport root, so the
    // event must be dispatched on the root element (or bubbled from
    // a focused child).
    const root = document.querySelector(
      '[data-testid="kanban-chat-dialog-root"]',
    ) as HTMLElement
    expect(root).not.toBeNull()
    root.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await flushPromises()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
  })

  it('emits update:show=false when ✕ header button is clicked', async () => {
    wrapper = mountDialog({
      show: true,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    const closeBtn = document.querySelector(
      '[data-testid="kanban-chat-dialog-close"]',
    ) as HTMLElement
    expect(closeBtn).not.toBeNull()
    closeBtn.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
  })

  it('emits both update:show and close on every close path (backward compat)', async () => {
    wrapper = mountDialog({
      show: true,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    const backdrop = document.querySelector(
      '[data-testid="kanban-chat-dialog-backdrop"]',
    ) as HTMLElement
    backdrop.click()
    await flushPromises()
    expect(wrapper.emitted('update:show')?.at(-1)).toEqual([false])
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('swaps task content when task prop changes (key contract)', async () => {
    wrapper = mountDialog({
      show: true,
      task: TASK_A,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog-title"]')
        ?.textContent,
    ).toContain('Task Alpha')
    // Switch task — the title should update and ChatView should remount.
    await wrapper.setProps({ task: TASK_B })
    await flushPromises()
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog-title"]')
        ?.textContent,
    ).toContain('Task Beta')
  })

  it('hides the dialog content when task is null (waiting state)', async () => {
    wrapper = mountDialog({
      show: true,
      task: null,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      projectName: 'Sprint',
      cwd: '',
    })
    await flushPromises()
    // The dialog shell renders (header + backdrop), but the chat body
    // is gated on task being non-null.
    const dialog = document.querySelector('[data-testid="kanban-chat-dialog"]')
    expect(dialog).not.toBeNull()
    const title = document.querySelector('[data-testid="kanban-chat-dialog-title"]')
    expect(title?.textContent).toContain('Chat')
  })
})
