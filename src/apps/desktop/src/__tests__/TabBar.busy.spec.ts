import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'
import { nextTick, ref, type Ref } from 'vue'

import TabBar from '../components/shell/TabBar.vue'
import { __resetWindowIdForTests } from '../helpers/windowId'
import { useTabsStore } from '../stores/tabs'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  Object.defineProperty(globalThis, 'sessionStorage', {
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_tabbar_busy' }),
    writable: true,
    configurable: true,
  })
}

function mountWithProcessing(state: Record<string, boolean>) {
  const processingState = ref<Record<string, boolean>>(state) as Ref<Record<string, boolean>>
  const wrapper = mount(TabBar, {
    global: {
      provide: { processingState },
    },
  })
  return { wrapper, processingState }
}

describe('TabBar busy indicator', () => {
  beforeEach(() => {
    installStorage()
    __resetWindowIdForTests()
    setActivePinia(createPinia())
  })

  it('marks a chat tab busy while its session worker runs', async () => {
    const store = useTabsStore()
    const chat = store.open({ query: { view: 'chat', session: 'sa' }, title: 'Chat A' })
    const other = store.open({ query: { view: 'chat', session: 'sb' }, title: 'Chat B' })

    const { wrapper, processingState } = mountWithProcessing({ sa: true })
    await nextTick()

    const busy = wrapper.find(`[data-testid="tab-item-${chat.id}"]`)
    const idle = wrapper.find(`[data-testid="tab-item-${other.id}"]`)
    expect(busy.attributes('data-tab-busy')).toBe('true')
    expect(idle.attributes('data-tab-busy')).toBe('false')
    expect(wrapper.find(`[data-testid="tab-loading-${chat.id}"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="tab-busy-bar-${chat.id}"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="tab-loading-${other.id}"]`).exists()).toBe(false)

    // clearing the worker clears the tab
    processingState.value = {}
    await nextTick()
    expect(wrapper.find(`[data-testid="tab-item-${chat.id}"]`).attributes('data-tab-busy')).toBe(
      'false',
    )
    expect(wrapper.find(`[data-testid="tab-loading-${chat.id}"]`).exists()).toBe(false)
  })

  it('marks a task-chat tab busy via its task id', async () => {
    const store = useTabsStore()
    const workspaces = useWorkspacesStore()
    workspaces.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        items: [
          {
            id: 'item_7',
            name: 'Sprint board',
            item_type: 'kanban',
            tasks: [{ id: 'task_9', name: 'Fix CI' }],
          },
        ],
      } as never,
    ]
    const tab = store.open({
      query: { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7/chat/task_9' },
    })

    const { wrapper } = mountWithProcessing({ task_9: true })
    await nextTick()

    expect(wrapper.find(`[data-testid="tab-item-${tab.id}"]`).attributes('data-tab-busy')).toBe(
      'true',
    )
    expect(wrapper.find(`[data-testid="tab-loading-${tab.id}"]`).exists()).toBe(true)
  })

  it('marks a bare board tab busy when any of its tasks runs', async () => {
    const store = useTabsStore()
    const workspaces = useWorkspacesStore()
    workspaces.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        items: [
          {
            id: 'item_7',
            name: 'Sprint board',
            item_type: 'kanban',
            tasks: [
              { id: 'task_9', name: 'Fix CI' },
              { id: 'task_10', name: 'Triage' },
            ],
          },
        ],
      } as never,
    ]
    const board = store.open({
      query: { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' },
    })

    const { wrapper } = mountWithProcessing({ task_10: true })
    await nextTick()

    expect(wrapper.find(`[data-testid="tab-item-${board.id}"]`).attributes('data-tab-busy')).toBe(
      'true',
    )
    expect(wrapper.find(`[data-testid="tab-busy-bar-${board.id}"]`).exists()).toBe(true)
  })

  it('keeps home tabs idle even while workers run elsewhere', async () => {
    const store = useTabsStore()
    const home = store.tabs[0]
    store.open({ query: { view: 'chat', session: 'sa' } })

    const { wrapper } = mountWithProcessing({ sa: true })
    await nextTick()

    expect(wrapper.find(`[data-testid="tab-item-${home?.id}"]`).attributes('data-tab-busy')).toBe(
      'false',
    )
  })

  it('renders idle with no provider (standalone mount)', async () => {
    const store = useTabsStore()
    store.open({ query: { view: 'chat', session: 'sa' } })
    const wrapper = mount(TabBar)
    await nextTick()
    expect(wrapper.findAll('[role="tab"]')[1]?.attributes('data-tab-busy')).toBe('false')
  })
})
