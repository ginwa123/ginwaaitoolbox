/**
 * Unit tests for the workspaces store's init() flow.
 * Mocks api.getWorkspaces, api.getWorkspacesItems, and api.getTasks
 * to assert the 3-call flow + task-attachment logic.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

describe('useWorkspacesStore.init()', () => {
  const getWorkspacesMock = vi.fn()
  const getWorkspacesItemsMock = vi.fn()
  const getTasksMock = vi.fn()

  // Re-created per beforeEach so tests start with a clean Map. The shared
  // helper just builds the stub; lifecycle is the test's responsibility.
  let localStorageStub: Storage
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    // Reset stub + re-install (beforeEach may run after a previous test cleared it).
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    // init() calls installSessionEventHandlers() which uses
    // useSseBus() — install a stub bus before the store's init()
    // runs so the install path doesn't throw.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('fetches workspaces, then items + tasks per workspace in parallel', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [
        { id: 'ws_1', name: 'Workspace 1', icon: '📁' },
        { id: 'ws_2', name: 'Workspace 2', icon: '📁' },
      ],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_1a', name: 'A' }], count: 1 })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [], count: 0 })
    getTasksMock.mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })

    const store = useWorkspacesStore()
    await store.init()

    expect(getWorkspacesMock).toHaveBeenCalledTimes(1)
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)
    expect(getWorkspacesItemsMock).toHaveBeenNthCalledWith(1, 'ws_1')
    expect(getWorkspacesItemsMock).toHaveBeenNthCalledWith(2, 'ws_2')
    // item_1a triggers one getTasks call; ws_2 has no items
    expect(getTasksMock).toHaveBeenCalledTimes(1)
    expect(getTasksMock).toHaveBeenCalledWith('ws_1', 'item_1a')
  })

  it('attaches tasks from getTasks(wsId, itemId) to the matching item', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        { id: 'item_a', name: 'A' },
        { id: 'item_b', name: 'B' },
      ],
      count: 2,
    })
    // Tasks for item_a
    getTasksMock.mockResolvedValueOnce({
      tasks: [
        { id: 't1', name: 'T1', workspace_item_id: 'item_a' },
        { id: 't2', name: 'T2', workspace_item_id: 'item_a' },
      ],
      has_more: false,
      next_cursor: null,
    })
    // Tasks for item_b
    getTasksMock.mockResolvedValueOnce({
      tasks: [{ id: 't3', name: 'T3', workspace_item_id: 'item_b' }],
      has_more: false,
      next_cursor: null,
    })

    const store = useWorkspacesStore()
    await store.init()

    const items = store.workspaces[0]!.items
    expect(items).toHaveLength(2)
    const itemA = items.find((i) => i.id === 'item_a')!
    const itemB = items.find((i) => i.id === 'item_b')!
    expect(itemA.tasks).toHaveLength(2)
    expect(itemA.tasks!.map((t) => t.id).sort()).toEqual(['t1', 't2'])
    expect(itemB.tasks).toHaveLength(1)
    expect(itemB.tasks![0]!.id).toBe('t3')
  })

  it('restores expanded state from localStorage for workspaces and items', async () => {
    localStorage.setItem('nalar-workspace-expanded', JSON.stringify(['ws_1']))
    localStorage.setItem('nalar-workspace-item-expanded', JSON.stringify(['item_1a']))

    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_1a', name: 'A' }], count: 1 })
    getTasksMock.mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces[0]!.expanded).toBe(true)
    expect(store.workspaces[0]!.items[0]!.expanded).toBe(true)
  })

  it('falls back to empty workspaces array when init fails', async () => {
    getWorkspacesMock.mockRejectedValueOnce(new Error('network down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toEqual([])
    expect(store.loadingError).toBe('network down')
    expect(store.isLoading).toBe(false)
  })

  it('keeps the workspace with empty tasks when a per-item tasks fetch fails', async () => {
    // Per-item task failure is non-fatal (logged + best-effort).
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_a', name: 'A' }], count: 1 })
    getTasksMock.mockRejectedValueOnce(new Error('tasks down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toHaveLength(1)
    expect(store.workspaces[0]!.items[0]!.tasks).toEqual([])
    expect(store.loadingError).toBeNull()
  })
})
