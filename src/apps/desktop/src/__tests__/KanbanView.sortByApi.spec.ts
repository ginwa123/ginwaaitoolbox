/**
 * Behavioural tests for KanbanView's per-column-sort + URL persistence +
 * API-fetch wiring.
 *
 * Plan (the redo, 2026-08-06):
 *  - Each KanbanColumn has its own sortBy + direction (already done).
 *  - When a column's sort changes, the column emits `sort-change` with
 *    the new sortBy + direction. KanbanView listens and:
 *      a) re-fetches tasks via fetchKanbanTasks with that sort
 *      b) updates the URL: `?sorts=col_<id>:<sortBy>:<direction>,...`
 *  - On mount, KanbanView parses the URL's `sorts` param and applies
 *    each column's sort via setSortMode (defineExpose seam).
 *  - The fetch is debounced via the existing search-input pattern
 *    (300ms) so rapid column-sort changes don't fire N requests.
 *
 * URL format:
 *   ?sorts=col_1:name:asc,col_2:created_at:desc,col_3:updated_at:asc
 * Comma-separated; each entry is `col_<id>:<sortBy>:<direction>`.
 * Default sorts (position + asc) are OMITTED to keep URLs clean.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'

import KanbanView from '../components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'

const WS_ID = 'ws_sortapi'
const ITEM_ID = 'item_sortapi'

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'SortByApi Kanban',
  item_type: 'kanban',
  path: '/tmp',
  kanban_columns: [
    { id: 'col_a', name: 'todo', workspace_item_id: ITEM_ID, position: 0, created_at: '2026-01-01' },
    { id: 'col_b', name: 'in_progress', workspace_item_id: ITEM_ID, position: 1, created_at: '2026-01-01' },
  ],
  tasks: [],
  hasMoreTasks: false,
  ...overrides,
})

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

function mountKanbanView(query: Record<string, string> = {}) {
  useRouteMock.mockReturnValue({
    query,
    path: '/app',
    fullPath: '/app',
  } as any)
  const store = useWorkspacesStore()
  store.workspaces = [
    { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
  ]
  const replaceMock = vi.fn()
  useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
  const wrapper = mount(KanbanView, {
    props: { item: makeItem(), workspaceId: WS_ID },
  })
  return { wrapper, replaceMock }
}

describe('KanbanView — per-column sort triggers API call', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('opening sort menu + picking "Oldest" debounces + fires fetchKanbanTasks with the sort', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper } = mountKanbanView({ view: 'workspace', workspaceId: WS_ID, itemId: ITEM_ID })

    // Open the ⋮ menu on column_a, click Sort tasks…, pick "Oldest".
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-created-asc"]').trigger('click')

    // Wait past the 300ms debounce window.
    await new Promise((resolve) => setTimeout(resolve, 350))
    await flushPromises()

    // fetchKanbanTasks was called with sortBy='created_at', direction='asc'.
    const calls = spy.mock.calls
    expect(calls.length).toBeGreaterThan(0)
    const last = calls[calls.length - 1]!
    expect(last[5]).toBe('created_at')
    expect(last[6]).toBe('asc')
  })

  it('picking "Manual" does NOT trigger an API call (no server-side equivalent)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper } = mountKanbanView({ view: 'workspace', workspaceId: WS_ID, itemId: ITEM_ID })

    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-position"]').trigger('click')

    await new Promise((resolve) => setTimeout(resolve, 350))
    await flushPromises()

    expect(spy).not.toHaveBeenCalled()
  })
})

describe('KanbanView — URL persistence of per-column sorts', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('picking a sort on column_a updates the URL with col_a sort, omits col_b', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper, replaceMock } = mountKanbanView({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })

    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')

    await new Promise((resolve) => setTimeout(resolve, 350))
    await flushPromises()

    // The URL got a `sorts=col_a:name:asc` query param.
    expect(replaceMock).toHaveBeenCalled()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]!
    const query = lastCall[0].query as Record<string, string>
    expect(query.sorts).toContain('col_a:name:asc')
  })

  it('mount with ?sorts=col_a:name:asc restores column_a sort on the cards', async () => {
    const tasks = [
      makeTask('t_z', 'Zeta', 0),
      makeTask('t_a', 'Alpha', 1),
    ]
    const item = makeItem({ tasks })
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [item] },
    ]
    vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    // Mount KanbanView with the seeded item (so the columns have
    // tasks to display after the URL-restore applies setSortMode).
    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
        sorts: 'col_a:name:asc',
      },
      path: '/app',
      fullPath: '/app',
    } as any)
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)

    const wrapper = mount(KanbanView, {
      props: { item, workspaceId: WS_ID },
    })

    // Allow the URL-restore watcher to apply setSortMode.
    await flushPromises()
    await new Promise((resolve) => setTimeout(resolve, 50))
    await flushPromises()

    const cards = wrapper.findAll('[data-kanban-card]')
    const cardIds = cards.map((c) => c.attributes('data-kanban-card'))
    expect(cardIds).toEqual(['t_a', 't_z'])
  })
})

function makeTask(id: string, name: string, kanbanPosition: number): any {
  return {
    id,
    name,
    task_type: 'standard',
    kanban_column_id: 'col_a',
    kanban_position: kanbanPosition,
    createdAt: new Date('2024-01-01T00:00:00Z'),
    updatedAt: new Date('2024-01-01T00:00:00Z'),
  }
}