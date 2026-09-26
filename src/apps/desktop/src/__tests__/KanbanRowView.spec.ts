/**
 * KanbanRowView — the row-mode body of a kanban board.
 *
 * Renders the same data as the column board as a vertical list grouped by
 * column: a collapsible section header per column (chevron + name + count
 * badge + ⋮ menu) with compact task rows underneath.
 *
 * This component is presentational: it reads `columns` / `tasks` props and
 * re-emits the same event set <KanbanColumn> emits. The only store access
 * is read-only (per-column pagination state) plus the "load more" action.
 */
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick } from 'vue'

import KanbanRowView from '../components/kanban/KanbanRowView.vue'
import { useWorkspacesStore, type KanbanColumn, type Task } from '../stores/workspaces'

const WS_ID = 'ws_row_view'
const ITEM_ID = 'item_row_view'

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
    useRoute: () => ({ query: {}, path: '/', fullPath: '/' }),
  }
})

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_1',
  workspace_item_id: ITEM_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'A task',
  kanban_column_id: 'col_1',
  ...overrides,
})

function mountRowView(
  props: {
    columns?: KanbanColumn[]
    tasks?: Task[]
    collapsedIds?: string[]
    runAllBusyByColumn?: Record<string, boolean>
  } = {},
) {
  return mount(KanbanRowView, {
    props: {
      columns: props.columns ?? [makeColumn()],
      tasks: props.tasks ?? [],
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      collapsedIds: props.collapsedIds ?? [],
      runAllBusyByColumn: props.runAllBusyByColumn ?? {},
    },
  })
}

describe('KanbanRowView', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  // ─── Grouping ────────────────────────────────────────────────────────────

  it('renders one group per column, in the order given', () => {
    wrapper = mountRowView({
      columns: [
        makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
        makeColumn({ id: 'col_b', name: 'in progress', position: 1 }),
        makeColumn({ id: 'col_c', name: 'done', position: 2 }),
      ],
    })
    const groups = wrapper.findAll('[data-kanban-row-group]')
    expect(groups.map((g) => g.attributes('data-kanban-row-group'))).toEqual([
      'col_a',
      'col_b',
      'col_c',
    ])
  })

  it('renders each column name in its group header', () => {
    wrapper = mountRowView({
      columns: [
        makeColumn({ id: 'col_a', name: 'todo' }),
        makeColumn({ id: 'col_b', name: 'done' }),
      ],
    })
    expect(wrapper.find('[data-testid="kanban-row-group-col_a-name"]').text()).toBe('todo')
    expect(wrapper.find('[data-testid="kanban-row-group-col_b-name"]').text()).toBe('done')
  })

  it('groups tasks by kanban_column_id', () => {
    wrapper = mountRowView({
      columns: [makeColumn({ id: 'col_a' }), makeColumn({ id: 'col_b' })],
      tasks: [
        makeTask({ id: 't1', kanban_column_id: 'col_a' }),
        makeTask({ id: 't2', kanban_column_id: 'col_b' }),
        makeTask({ id: 't3', kanban_column_id: 'col_a' }),
      ],
    })
    const a = wrapper.find('[data-testid="kanban-row-group-col_a-rows"]')
    const b = wrapper.find('[data-testid="kanban-row-group-col_b-rows"]')
    expect(a.findAll('[data-kanban-row]').map((r) => r.attributes('data-kanban-row'))).toEqual([
      't1',
      't3',
    ])
    expect(b.findAll('[data-kanban-row]').map((r) => r.attributes('data-kanban-row'))).toEqual([
      't2',
    ])
  })

  it('excludes tasks whose kanban_column_id matches no column', () => {
    wrapper = mountRowView({
      columns: [makeColumn({ id: 'col_a' })],
      tasks: [
        makeTask({ id: 't1', kanban_column_id: 'col_a' }),
        makeTask({ id: 'orphan', kanban_column_id: 'col_gone' }),
      ],
    })
    expect(wrapper.findAll('[data-kanban-row]')).toHaveLength(1)
    expect(wrapper.find('[data-kanban-row="orphan"]').exists()).toBe(false)
  })

  it('shows the loaded-row count per group', () => {
    wrapper = mountRowView({
      tasks: [
        makeTask({ id: 't1', kanban_column_id: 'col_1' }),
        makeTask({ id: 't2', kanban_column_id: 'col_1' }),
        makeTask({ id: 't3', kanban_column_id: 'col_1' }),
      ],
    })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-count"]').text()).toBe('3')
  })

  it('shows a 0 count for an empty group', () => {
    wrapper = mountRowView({ tasks: [] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-count"]').text()).toBe('0')
  })

  // ─── Empty states ────────────────────────────────────────────────────────

  it('renders the board-level empty state when there are no columns', () => {
    wrapper = mountRowView({ columns: [], tasks: [] })
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows-empty"]`).exists()).toBe(true)
    expect(wrapper.text()).toContain('No columns on this board')
    expect(wrapper.findAll('[data-kanban-row-group]')).toHaveLength(0)
  })

  it('renders the per-group empty placeholder for a column with no tasks', () => {
    wrapper = mountRowView({ tasks: [] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No tasks yet')
  })

  it('does not render the per-group empty placeholder when the group has rows', () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-empty"]').exists()).toBe(false)
  })

  // ─── Collapse ────────────────────────────────────────────────────────────

  it('renders rows when the group is expanded', () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })], collapsedIds: [] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-rows"]').exists()).toBe(true)
  })

  it('hides rows when the group is collapsed', () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })], collapsedIds: ['col_1'] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-rows"]').exists()).toBe(false)
  })

  it('the collapse toggle emits toggleCollapse with the column id', async () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    await wrapper.find('[data-testid="kanban-row-group-col_1-toggle"]').trigger('click')
    expect(wrapper.emitted('toggleCollapse')?.[0]).toEqual(['col_1'])
  })

  it('reflects the collapsed state in aria-expanded', () => {
    wrapper = mountRowView({ collapsedIds: ['col_1'] })
    expect(
      wrapper.find('[data-testid="kanban-row-group-col_1-toggle"]').attributes('aria-expanded'),
    ).toBe('false')
  })

  it('reflects the expanded state in aria-expanded', () => {
    wrapper = mountRowView({ collapsedIds: [] })
    expect(
      wrapper.find('[data-testid="kanban-row-group-col_1-toggle"]').attributes('aria-expanded'),
    ).toBe('true')
  })

  // ─── Group header: description + inline rename ───────────────────────────

  it('renders the column description when present', () => {
    wrapper = mountRowView({ columns: [makeColumn({ description: 'Things to do' })] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-description"]').text()).toBe(
      'Things to do',
    )
  })

  it('omits the description element when the column has none', () => {
    wrapper = mountRowView({ columns: [makeColumn({ description: null })] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-description"]').exists()).toBe(false)
  })

  it('clicking the group name starts an inline rename', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-name"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="kanban-row-group-col_1-rename-input"]')
    expect(input.exists()).toBe(true)
    expect((input.element as HTMLInputElement).value).toBe('todo')
  })

  it('committing an inline rename emits renameColumn', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-name"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="kanban-row-group-col_1-rename-input"]')
    await input.setValue('backlog')
    await input.trigger('keyup.enter')
    expect(wrapper.emitted('renameColumn')?.[0]).toEqual([{ columnId: 'col_1', name: 'backlog' }])
  })

  it('an unchanged inline rename emits nothing', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-name"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="kanban-row-group-col_1-rename-input"]')
    await input.trigger('keyup.enter')
    expect(wrapper.emitted('renameColumn')).toBeUndefined()
  })

  it('Escape cancels an inline rename without emitting', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-name"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="kanban-row-group-col_1-rename-input"]')
    await input.setValue('discarded')
    await input.trigger('keyup.escape')
    expect(wrapper.emitted('renameColumn')).toBeUndefined()
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-rename-input"]').exists()).toBe(false)
  })

  // ─── Group ⋮ menu ────────────────────────────────────────────────────────

  it('the ⋮ menu is closed by default', () => {
    wrapper = mountRowView()
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-menu"]').exists()).toBe(false)
  })

  it('clicking the ⋮ trigger opens the menu', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-menu"]').exists()).toBe(true)
  })

  it('the menu offers Rename, Sort tasks…, Delete and Run all agents', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    const text = wrapper.find('[data-testid="kanban-row-group-col_1-menu"]').text()
    expect(text).toContain('Rename')
    expect(text).toContain('Sort tasks…')
    expect(text).toContain('Delete')
    expect(text).toContain('Run all agents')
  })

  it('Rename emits requestRenameColumn and closes the menu', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-rename"]').trigger('click')
    expect(wrapper.emitted('requestRenameColumn')?.[0]).toEqual(['col_1'])
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-menu"]').exists()).toBe(false)
  })

  it('Delete emits requestDeleteColumn', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-delete"]').trigger('click')
    expect(wrapper.emitted('requestDeleteColumn')?.[0]).toEqual(['col_1'])
  })

  it('Run all agents emits requestRunAllAgents', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-run-all"]').trigger('click')
    expect(wrapper.emitted('requestRunAllAgents')?.[0]).toEqual(['col_1'])
  })

  it('Run all agents is disabled while the column is busy', async () => {
    wrapper = mountRowView({ runAllBusyByColumn: { col_1: true } })
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    const btn = wrapper.find('[data-testid="kanban-row-group-col_1-menu-run-all"]')
    expect(btn.attributes('disabled')).toBeDefined()
    expect(btn.text()).toContain('Running all agents…')
  })

  it('only one group menu is open at a time', async () => {
    wrapper = mountRowView({
      columns: [makeColumn({ id: 'col_a' }), makeColumn({ id: 'col_b' })],
    })
    await wrapper.find('[data-testid="kanban-row-group-col_a-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_b-menu-trigger"]').trigger('click')
    expect(wrapper.find('[data-testid="kanban-row-group-col_a-menu"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="kanban-row-group-col_b-menu"]').exists()).toBe(true)
  })

  // ─── Sort modal ──────────────────────────────────────────────────────────

  it('Sort tasks… opens the sort modal for that column', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-sort-modal"]').exists()).toBe(true)
  })

  it('picking a sort emits sortChange carrying the column id', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await nextTick()
    expect(wrapper.emitted('sortChange')?.[0]).toEqual([
      { columnId: 'col_1', sortBy: 'name', direction: 'asc' },
    ])
  })

  it('picking a sort closes the modal', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-sort-modal"]').exists()).toBe(false)
  })

  it('clicking the sort modal backdrop closes it without emitting', async () => {
    wrapper = mountRowView()
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-row-group-col_1-sort-modal"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-sort-modal"]').exists()).toBe(false)
    expect(wrapper.emitted('sortChange')).toBeUndefined()
  })

  // ─── Row events ──────────────────────────────────────────────────────────

  it('clicking a row emits selectTask', async () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    await wrapper.find('[data-kanban-row="t1"] [data-task-row]').trigger('click')
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['t1'])
  })

  it('clicking the ⋯ details button emits viewTaskDetail', async () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    await wrapper.find('[data-testid="kanban-row-t1-details"]').trigger('click')
    expect(wrapper.emitted('viewTaskDetail')?.[0]).toEqual(['t1'])
  })

  it('the ⋯ details click does not also emit selectTask', async () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    await wrapper.find('[data-testid="kanban-row-t1-details"]').trigger('click')
    expect(wrapper.emitted('selectTask')).toBeUndefined()
  })

  // ─── Pagination ──────────────────────────────────────────────────────────

  it('shows no Load more button when the column has no further pages', () => {
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-load-more"]').exists()).toBe(false)
  })

  it('shows Load more and a + count suffix when the column has more pages', () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [
          {
            id: ITEM_ID,
            name: 'Sprint',
            item_type: 'kanban',
            columnPagination: { col_1: { cursor: 'c1', hasMore: true, isLoading: false } },
          },
        ],
      },
    ]
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-load-more"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-count"]').text()).toBe('1+')
  })

  it('clicking Load more calls loadMoreTasksForColumn for that column', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [
          {
            id: ITEM_ID,
            name: 'Sprint',
            item_type: 'kanban',
            columnPagination: { col_1: { cursor: 'c1', hasMore: true, isLoading: false } },
          },
        ],
      },
    ]
    const spy = vi.spyOn(store, 'loadMoreTasksForColumn').mockResolvedValue()
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })

    await wrapper.find('[data-testid="kanban-row-group-col_1-load-more"]').trigger('click')
    expect(spy).toHaveBeenCalledWith(WS_ID, ITEM_ID, 'col_1')
  })

  it('Load more is disabled while a page is loading', () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [
          {
            id: ITEM_ID,
            name: 'Sprint',
            item_type: 'kanban',
            columnPagination: { col_1: { cursor: 'c1', hasMore: true, isLoading: true } },
          },
        ],
      },
    ]
    wrapper = mountRowView({ tasks: [makeTask({ id: 't1' })] })
    const btn = wrapper.find('[data-testid="kanban-row-group-col_1-load-more"]')
    expect(btn.attributes('disabled')).toBeDefined()
    expect(btn.text()).toContain('Loading…')
  })

  it('does not show Load more for an empty group even when more pages exist', () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [
          {
            id: ITEM_ID,
            name: 'Sprint',
            item_type: 'kanban',
            columnPagination: { col_1: { cursor: 'c1', hasMore: true, isLoading: false } },
          },
        ],
      },
    ]
    wrapper = mountRowView({ tasks: [] })
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-load-more"]').exists()).toBe(false)
  })
})
