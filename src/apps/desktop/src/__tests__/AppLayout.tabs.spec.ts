import { createPinia, setActivePinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, reactive } from 'vue'

import AppLayout from '../components/AppLayout.vue'
import Sidebar from '../components/shell/Sidebar.vue'
import WorkspaceList from '../components/workspace/WorkspaceList.vue'
import { useTabsStore } from '../stores/tabs'
import { useWorkspacesStore } from '../stores/workspaces'
import { __resetWindowIdForTests } from '../helpers/windowId'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

/**
 * Task 4 of the tab-mode plan: AppLayout + the route funnel.
 *
 * The whole point of the design is that the strip is driven by the URL, so
 * this spec drives the REAL navigation paths (a Sidebar emit, a deep-link
 * route change, a click in the strip) and asserts both the store state and
 * the URL. The router is faked with a reactive route so `router.replace` is
 * observable exactly like a real navigation would be.
 *
 * Note on counting: `replace` calls are counted as DELTAS around an action.
 * Mounting normalises the URL too (a cold boot on `/app` names the home
 * tab), so absolute counts would conflate the two.
 */

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

import * as api from '../api'

type Query = Record<string, string>
type Target = { path?: string; query?: Query }

const route = reactive({ path: '/app', query: {} as Query, fullPath: '/app' })
const replaceCalls: Target[] = []
const pushCalls: Target[] = []

function queryString(query: Query): string {
  const text = new URLSearchParams(query).toString()
  return text ? `?${text}` : ''
}

function setRoute(path: string, query: Query = {}): void {
  route.path = path
  route.query = { ...query }
  route.fullPath = path + queryString(query)
}

function applyTarget(target: Target): void {
  setRoute(target.path || '/app', (target.query as Query) || {})
}

const replaceMock = vi.fn((target: Target) => {
  replaceCalls.push(target)
  applyTarget(target)
  return Promise.resolve()
})
const pushMock = vi.fn((target: Target) => {
  pushCalls.push(target)
  applyTarget(target)
  return Promise.resolve()
})

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

let mounted: VueWrapper | null = null

function mountApp(): VueWrapper {
  mounted = mount(AppLayout, {
    global: {
      stubs: {
        // Heavy children are stubbed; Sidebar and TabBar stay real because
        // they are the two things this spec interacts with.
        GitFileViewer: true,
        SkillDetail: true,
        ChatView: { template: '<div data-testid="chatview-stub" />', props: ['chatId', 'chatName', 'cwd'] },
        StandardTaskChatView: true,
        Chats: { template: '<div data-testid="chats-stub" />' },
        SettingsView: true,
        CodeEditor: true,
        KanbanView: { template: '<div data-testid="kanban-stub" />' },
        KanbanChatDialog: true,
        DesignChatDialog: true,
        DesignView: { template: '<div data-testid="design-stub" />' },
        AgentView: { template: '<div data-testid="agent-stub" />' },
        RoutineView: { template: '<div data-testid="routine-stub" />' },
        AgentChatView: true,
      },
    },
  })
  return mounted
}

async function settle(): Promise<void> {
  await flushPromises()
  await nextTick()
  await flushPromises()
  await nextTick()
}

describe('AppLayout — tab mode', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    Object.defineProperty(globalThis, 'sessionStorage', {
      value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_applayout' }),
      writable: true,
      configurable: true,
    })
    __resetWindowIdForTests()

    __resetSseBus()
    installSseBus()
    __setSseBusGlobalClient(makeStubClient())

    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    } as never)
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({ entries: [], path: '/', absolute: '/', home: '/' } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '' } as any)

    useRouteMock.mockReset()
    useRouterMock.mockReset()
    replaceCalls.length = 0
    pushCalls.length = 0
    replaceMock.mockClear()
    pushMock.mockClear()
    setRoute('/app', {})
    useRouteMock.mockReturnValue(route)
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock, back: vi.fn() })
  })

  afterEach(() => {
    // Unmount even when an assertion failed — a leaked AppLayout keeps its
    // route watcher alive and would contaminate the next test through the
    // shared reactive route.
    mounted?.unmount()
    mounted = null
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('renders the strip, names the home tab in the URL, and does not loop', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()

    expect(wrapper.find('[data-testid="tab-bar"]').exists()).toBe(true)
    expect(wrapper.findAll('[role="tab"]')).toHaveLength(1)
    expect(tabs.activeTab?.key).toBe('home')
    expect(route.query.tab).toBe(tabs.activeTabId)

    const settles = replaceCalls.length
    await settle()
    expect(replaceCalls.length).toBe(settles)
  })

  it('names a deep-linked chat in a tab and keeps the URL shape', async () => {
    setRoute('/app', { view: 'chat', session: 'sa' })
    mountApp()
    await settle()

    const tabs = useTabsStore()
    expect(tabs.tabs.map((t) => t.key)).toEqual(['home', 'chat:sa'])
    expect(tabs.activeTab?.key).toBe('chat:sa')
    expect(route.query).toEqual({ view: 'chat', session: 'sa', tab: tabs.activeTabId })
    expect(route.path).toBe('/app')
  })

  it('creates a tab from a sidebar navigation, focuses it on the second visit, and never loops', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()
    const sidebar = wrapper.findComponent(Sidebar)

    let replaces = replaceCalls.length
    let pushes = pushCalls.length
    sidebar.vm.$emit('navigate', 'chat-sa', 'Chat A')
    await settle()
    expect(tabs.tabCount).toBe(2)
    expect(tabs.activeTab?.key).toBe('chat:sa')
    expect(pushCalls.at(-1)?.query).toEqual({ view: 'chat', session: 'sa' })
    expect(pushCalls.length).toBe(pushes + 1)
    expect(replaceCalls.length).toBe(replaces + 1)
    expect(route.query.tab).toBe(tabs.activeTabId)

    replaces = replaceCalls.length
    pushes = pushCalls.length
    sidebar.vm.$emit('navigate', 'chat-sb', 'Chat B')
    await settle()
    expect(tabs.tabCount).toBe(3)
    expect(pushCalls.length).toBe(pushes + 1)
    expect(replaceCalls.length).toBe(replaces + 1)

    const sa = tabs.tabs.find((t) => t.key === 'chat:sa')
    replaces = replaceCalls.length
    pushes = pushCalls.length
    sidebar.vm.$emit('navigate', 'chat-sa', 'Chat A')
    await settle()
    expect(tabs.tabCount).toBe(3)
    expect(tabs.activeTabId).toBe(sa?.id)
    expect(pushCalls.length).toBe(pushes + 1)
    expect(replaceCalls.length).toBe(replaces + 1)
    expect(route.query.tab).toBe(sa?.id)

    // the funnel settles: no further navigation happens on its own
    const settled = replaceCalls.length
    await settle()
    expect(replaceCalls.length).toBe(settled)
  })

  it('keeps one tab when opening task chats inside a kanban item', async () => {
    setRoute('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' })
    mountApp()
    await settle()
    const tabs = useTabsStore()
    const workspaces = useWorkspacesStore()
    workspaces.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        items: [
          {
            id: 'item_7',
            name: 'AGENTIC_KANBAN',
            item_type: 'kanban',
            tasks: [{ id: 'task_9', name: 'fix-husky-vue-build' }],
          },
        ],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    workspaces.setActiveWorkspaceItem('item_7')
    await settle()
    // precondition for the whole test: the item type must be resolvable, which
    // is what tells the funnel a task chat belongs to this tab
    expect(workspaces.activeWorkspaceItem?.item_type).toBe('kanban')
    expect(tabs.tabCount).toBe(2)
    expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7')

    // opening a card must NOT spawn a tab per card
    for (const taskId of ['task_9', 'task_10', 'task_11']) {
      setRoute('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: `item_7/chat/${taskId}` })
      await settle()
    }
    expect(tabs.tabCount).toBe(2)
    expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7')
    expect(tabs.activeTab?.query.itemId).toBe('item_7/chat/task_11')
    expect(route.query.tab).toBe(tabs.activeTabId)

    // going back to the bare board keeps the same tab
    setRoute('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' })
    await settle()
    expect(tabs.tabCount).toBe(2)
  })

  it('repairs a ?tab= that names a different target', async () => {
    setRoute('/app', { view: 'chat', session: 'sa', tab: 'tab_stale' })
    mountApp()
    await settle()

    const tabs = useTabsStore()
    expect(tabs.activeTab?.key).toBe('chat:sa')
    expect(tabs.activeTabId).not.toBe('tab_stale')
    expect(route.query.tab).toBe(tabs.activeTabId)
  })

  it('creates no tab and leaves the URL untouched for an overlay view', async () => {
    setRoute('/app', { view: 'skill', skill: 'brainstorming' })
    mountApp()
    await settle()

    expect(useTabsStore().tabCount).toBe(1)
    expect(replaceCalls).toHaveLength(0)
    expect(route.query).toEqual({ view: 'skill', skill: 'brainstorming' })
  })

  it('activates a tab when it is clicked in the strip and rewrites the URL', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()
    const sidebar = wrapper.findComponent(Sidebar)
    sidebar.vm.$emit('navigate', 'chat-sa', 'Chat A')
    await settle()
    sidebar.vm.$emit('navigate', 'chat-sb', 'Chat B')
    await settle()

    const sa = tabs.tabs.find((t) => t.key === 'chat:sa')
    expect(sa).toBeTruthy()
    const replaces = replaceCalls.length
    const pushes = pushCalls.length

    await wrapper.find(`[data-testid="tab-item-${sa?.id}"]`).trigger('click')
    await settle()

    expect(tabs.activeTabId).toBe(sa?.id)
    expect(route.query).toEqual({ view: 'chat', session: 'sa', tab: sa?.id })
    // switching tabs is a replace, never a push
    expect(replaceCalls.length).toBe(replaces + 1)
    expect(pushCalls.length).toBe(pushes)
  })

  it('closes the active tab from the strip and activates the right neighbour', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()
    const sidebar = wrapper.findComponent(Sidebar)
    sidebar.vm.$emit('navigate', 'chat-sa', 'Chat A')
    await settle()
    sidebar.vm.$emit('navigate', 'chat-sb', 'Chat B')
    await settle()

    const sa = tabs.tabs.find((t) => t.key === 'chat:sa')
    const sb = tabs.tabs.find((t) => t.key === 'chat:sb')
    await wrapper.find(`[data-testid="tab-close-${sa?.id}"]`).trigger('click')
    await settle()

    expect(tabs.tabCount).toBe(2)
    expect(tabs.activeTabId).toBe(sb?.id)
    expect(route.query.tab).toBe(sb?.id)
  })

  it('opens a workspace item in the background from the sidebar and stays put', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()
    const replaces = replaceCalls.length
    const pushes = pushCalls.length
    const activeBefore = tabs.activeTabId

    // The gesture arrives from a workspace row, through WorkspaceList.
    wrapper
      .findComponent(WorkspaceList)
      .vm.$emit('openItemInBackground', { workspaceId: 'ws_1', itemId: 'item_7', name: 'Board' })
    await settle()

    // a tab was remembered, nothing navigated, the user stays on the same tab
    expect(tabs.tabCount).toBe(2)
    expect(tabs.byKey('ws:ws_1:item_7')?.title).toBe('Board')
    expect(tabs.activeTabId).toBe(activeBefore)
    expect(pushCalls.length).toBe(pushes)
    expect(replaceCalls.length).toBe(replaces)
    expect(route.query.tab).toBe(activeBefore)

    // and the tab is real: clicking it in the strip navigates there. The item
    // must exist in the tree, because activating a tab also mirrors the target
    // into the stores (that is what makes the view actually change).
    const workspaces = useWorkspacesStore()
    workspaces.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        items: [{ id: 'item_7', name: 'Board', item_type: 'kanban', tasks: [] }],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    const background = tabs.byKey('ws:ws_1:item_7')
    await wrapper.find(`[data-testid="tab-item-${background?.id}"]`).trigger('click')
    await settle()
    expect(tabs.activeTabId).toBe(background?.id)
    expect(route.query).toEqual({ view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7', tab: background?.id })
    expect(workspaces.activeWorkspaceItemId).toBe('item_7')
  })

  it('follows a session-id change in place instead of leaving a dead tab', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()
    const sidebar = wrapper.findComponent(Sidebar)

    sidebar.vm.$emit('navigate', 'chat-session-1789000000000', 'New Chat')
    await settle()
    expect(tabs.tabCount).toBe(2)
    const synthetic = tabs.activeTab
    expect(synthetic?.key).toBe('chat:session-1789000000000')

    // the backend assigns the real id on the first message → update-chat-id
    const app = wrapper.vm as unknown as { handleUpdateChatId: (oldId: string, newId: string) => void }
    app.handleUpdateChatId('session-1789000000000', 'real-7')
    setRoute('/app', { view: 'chat', session: 'real-7' })
    await settle()

    // one chat, one tab: the synthetic key is gone and the tab kept its identity
    expect(tabs.tabCount).toBe(2)
    expect(tabs.activeTabId).toBe(synthetic?.id)
    expect(tabs.byKey('chat:real-7')?.id).toBe(synthetic?.id)
    expect(tabs.byKey('chat:session-1789000000000')).toBeNull()
    expect(route.query.tab).toBe(synthetic?.id)
  })

  it('switching tabs changes the rendered view, not just the URL', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()
    const workspaces = useWorkspacesStore()
    workspaces.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        items: [
          { id: 'item_kanban', name: 'AGENTIC_KANBAN', item_type: 'kanban', tasks: [] },
          { id: 'item_agent', name: 'AGENTIC BASIC', item_type: 'agent', tasks: [] },
        ],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    ]
    const sidebar = wrapper.findComponent(Sidebar)

    // a sidebar click sets the store AND navigates (WorkspaceItem → Sidebar)
    workspaces.setActiveWorkspaceItem('item_kanban')
    sidebar.vm.$emit('navigate', 'workspace', undefined, undefined, 'ws_1', 'item_kanban')
    await settle()
    expect(workspaces.activeWorkspaceItemId).toBe('item_kanban')
    expect(wrapper.find('[data-testid="kanban-stub"]').exists()).toBe(true)

    workspaces.setActiveWorkspaceItem('item_agent')
    sidebar.vm.$emit('navigate', 'workspace', undefined, undefined, 'ws_1', 'item_agent')
    await settle()
    expect(workspaces.activeWorkspaceItemId).toBe('item_agent')
    expect(wrapper.find('[data-testid="agent-stub"]').exists()).toBe(true)

    // the regression: activating a tab only rewrote the URL, so the previous
    // view stayed on screen
    const kanbanTab = tabs.byKey('ws:ws_1:item_kanban')
    await wrapper.find(`[data-testid="tab-item-${kanbanTab?.id}"]`).trigger('click')
    await settle()
    expect(tabs.activeTabId).toBe(kanbanTab?.id)
    expect(workspaces.activeWorkspaceItemId).toBe('item_kanban')
    expect(wrapper.find('[data-testid="kanban-stub"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="agent-stub"]').exists()).toBe(false)

    // and back again, from the other tab
    const agentTab = tabs.byKey('ws:ws_1:item_agent')
    await wrapper.find(`[data-testid="tab-item-${agentTab?.id}"]`).trigger('click')
    await settle()
    expect(workspaces.activeWorkspaceItemId).toBe('item_agent')
    expect(wrapper.find('[data-testid="agent-stub"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-stub"]').exists()).toBe(false)
  })

  it('switching to a chat tab retires the workspace item', async () => {
    const wrapper = mountApp()
    await settle()
    const tabs = useTabsStore()
    const workspaces = useWorkspacesStore()
    const sidebar = wrapper.findComponent(Sidebar)

    sidebar.vm.$emit('navigate', 'chat-sa', 'Chat A')
    await settle()
    sidebar.vm.$emit('navigate', 'workspace', undefined, undefined, 'ws_1', 'item_7')
    await settle()
    expect(tabs.byKey('ws:ws_1:item_7')).toBeTruthy()

    const chatTab = tabs.byKey('chat:sa')
    await wrapper.find(`[data-testid="tab-item-${chatTab?.id}"]`).trigger('click')
    await settle()

    expect(workspaces.activeWorkspaceItemId).toBeNull()
    expect(wrapper.find('[data-testid="chatview-stub"]').exists()).toBe(true)
  })

  it('creates no tab, renders no strip and never adds ?tab= when tab mode is off', async () => {
    const tabs = useTabsStore()
    tabs.setEnabled(false)
    setRoute('/app', { view: 'chat', session: 'sa' })

    const wrapper = mountApp()
    await settle()

    expect(wrapper.find('[data-testid="tab-bar"]').exists()).toBe(false)
    expect(tabs.tabCount).toBe(1)
    expect(replaceCalls.some((call) => call.query?.tab)).toBe(false)
    // the URL is left exactly as the user (or a bookmark) provided it
    expect(route.query).toEqual({ view: 'chat', session: 'sa' })
  })
})
