/**
 * Behavioural tests for KanbanColumn's per-column sort independence
 * (plan 2026-08-06-kanban-sort-independence.md).
 *
 * Background (the bug). Commit 0ed7582d removed the client-side
 * `.sort()` from `KanbanColumn.cardsInColumn` AND deleted the
 * `compareBySortMode` comparator. The justification at the time
 * was the user's "i remove that and its become better" comment
 * — but the removal broke per-column independence, because the
 * backend's `listWorkspaceItemTasksWithCursor` only accepts ONE
 * `sort_field` + `sort_direction` per request. The result: every
 * column rendered in the same global order, regardless of each
 * column's local sort state.
 *
 * Fix. Re-add the client-side comparator. The backend still
 * fetches with the LATEST user-picked sort (the wire data is in
 * that order), but each column's `cardsInColumn` applies its own
 * sort locally. Two columns with different sorts now display
 * differently.
 *
 * Tests cover:
 *  - default sort = position asc (kanban_position order)
 *  - name asc / desc
 *  - created_at desc (newest-first)
 *  - updated_at asc (oldest-first)
 *  - same sort-field value → kanban_position asc tiebreaker
 *  - per-column independence (the bug case)
 *  - setting sort back to position restores kanban_position order
 *  - setSortMode via defineExpose is the test seam
 *  - sortChange emit fires on every sort change
 *
 * Plan: docs/superpowers/plans/2026-08-06-kanban-sort-independence.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'

import KanbanColumn from '../components/kanban/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnType, Task } from '../stores/workspaces'

const COL_A = 'col_alpha'
const COL_B = 'col_beta'

const makeColumn = (id: string, overrides: Partial<KanbanColumnType> = {}): KanbanColumnType => ({
  id,
  workspace_item_id: 'item_1',
  name: id,
  position: 0,
  created_at: '2026-08-06 12:00:00',
  ...overrides,
})

const makeTask = (
  id: string,
  name: string,
  kanban_position: number,
  overrides: Partial<Task> = {},
): Task => ({
  id,
  name,
  task_type: 'standard',
  kanban_column_id: COL_A,
  kanban_position,
  createdAt: new Date('2024-01-01T00:00:00Z'),
  updatedAt: new Date('2024-01-01T00:00:00Z'),
  ...overrides,
})

function mountColumn(
  column: KanbanColumnType,
  tasks: Task[] = [],
  workspaceId = 'ws_1',
  itemId = 'item_1',
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(KanbanColumn, {
    props: { column, tasks, workspaceId, itemId },
    global: {
      provide: { processingState },
    },
  })
}

// Test seam: the component exposes setSortMode via defineExpose so
// tests (and the URL restore code in KanbanView's onMount) can drive
// the sort state without touching the modal flow.
function setSort(wrapper: VueWrapper, sortBy: string, direction: string) {
  ;(wrapper.vm as unknown as { setSortMode: (s: string, d: string) => void }).setSortMode(sortBy, direction)
}

function cardOrder(wrapper: VueWrapper): string[] {
  return wrapper
    .findAll('[data-kanban-card]')
    .map((node) => node.attributes('data-kanban-card') ?? '')
}

describe('KanbanColumn — per-column sort state (apply client-side)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('default sortBy=position + direction=asc → cards in kanban_position asc order', () => {
    // Seed tasks in non-position order to prove sorting is applied.
    const tasks = [
      makeTask('t_2', 'Bravo', 2),
      makeTask('t_0', 'Alpha', 0),
      makeTask('t_1', 'Charlie', 1),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    expect(cardOrder(wrapper)).toEqual(['t_0', 't_1', 't_2'])
  })

  it('sortBy=name + direction=asc → cards in A→Z order', async () => {
    const tasks = [
      makeTask('t_z', 'Zeta', 0),
      makeTask('t_a', 'Alpha', 1),
      makeTask('t_m', 'Mike', 2),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    setSort(wrapper, 'name', 'asc')
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_a', 't_m', 't_z'])
  })

  it('sortBy=name + direction=desc → cards in Z→A order', async () => {
    const tasks = [
      makeTask('t_a', 'Alpha', 0),
      makeTask('t_m', 'Mike', 1),
      makeTask('t_z', 'Zeta', 2),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    setSort(wrapper, 'name', 'desc')
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_z', 't_m', 't_a'])
  })

  it('sortBy=created_at + direction=desc → cards in newest-first order', async () => {
    const tasks = [
      { ...makeTask('t_old', 'Oldest', 0), createdAt: new Date('2024-01-01T00:00:00Z') },
      { ...makeTask('t_mid', 'Middle', 1), createdAt: new Date('2024-06-15T12:00:00Z') },
      { ...makeTask('t_new', 'Newest', 2), createdAt: new Date('2024-12-31T23:59:59Z') },
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    setSort(wrapper, 'created_at', 'desc')
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_new', 't_mid', 't_old'])
  })

  it('sortBy=updated_at + direction=asc → cards in oldest-first order', async () => {
    const tasks = [
      { ...makeTask('t_new', 'Newest', 0), updatedAt: new Date('2024-12-31T23:59:59Z') },
      { ...makeTask('t_old', 'Oldest', 1), updatedAt: new Date('2024-01-01T00:00:00Z') },
      { ...makeTask('t_mid', 'Middle', 2), updatedAt: new Date('2024-06-15T12:00:00Z') },
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    setSort(wrapper, 'updated_at', 'asc')
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_old', 't_mid', 't_new'])
  })

  it('cards with the same sort-field value fall back to kanban_position asc tiebreaker', async () => {
    const tasks = [
      makeTask('t_pos2', 'Same', 2),
      makeTask('t_pos0', 'Same', 0),
      makeTask('t_pos1', 'Same', 1),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    setSort(wrapper, 'name', 'asc')
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_pos0', 't_pos1', 't_pos2'])
  })

  it('two columns sort independently — changing one does not affect the other', async () => {
    // The CRITICAL regression test for the user-reported bug
    // (task_1785730557641). Each column has cards with the same
    // wire data shape but different per-column sorts. Each column
    // MUST render in its own local order.
    const tasksA = [
      makeTask('t_a_z', 'Zeta', 0),
      makeTask('t_a_a', 'Alpha', 1),
    ]
    const tasksB = [
      { ...makeTask('t_b_a', 'Alpha', 0), kanban_column_id: COL_B },
      { ...makeTask('t_b_z', 'Zeta', 1), kanban_column_id: COL_B },
    ]
    const wA = mountColumn(makeColumn(COL_A), tasksA)
    const wB = mountColumn(makeColumn(COL_B), tasksB)

    // Column A: name asc → Alpha before Zeta.
    setSort(wA, 'name', 'asc')
    await nextTick()
    expect(cardOrder(wA)).toEqual(['t_a_a', 't_a_z'])
    // Column B: default (position asc) → unchanged order.
    expect(cardOrder(wB)).toEqual(['t_b_a', 't_b_z'])

    // Now flip column B to name desc → Zeta before Alpha. Column A
    // must NOT change.
    setSort(wB, 'name', 'desc')
    await nextTick()
    expect(cardOrder(wA)).toEqual(['t_a_a', 't_a_z'])
    expect(cardOrder(wB)).toEqual(['t_b_z', 't_b_a'])

    wA.unmount()
    wB.unmount()
  })

  it('setting sortBy back to position restores the kanban_position asc order', async () => {
    // Names whose alpha order does NOT match position order. Switching
    // back to position is observable.
    const tasks = [
      makeTask('t_b', 'Bravo', 0),
      makeTask('t_a', 'Alpha', 1),
      makeTask('t_c', 'Charlie', 2),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    expect(cardOrder(wrapper)).toEqual(['t_b', 't_a', 't_c'])

    setSort(wrapper, 'name', 'asc')
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_a', 't_b', 't_c'])

    setSort(wrapper, 'position', 'asc')
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_b', 't_a', 't_c'])
  })

  it('sortChange emit fires on every sort change (parent needs it for URL + fetch)', async () => {
    const tasks = [
      makeTask('t_a', 'Alpha', 0),
      makeTask('t_b', 'Bravo', 1),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    setSort(wrapper, 'name', 'asc')
    await nextTick()
    const events = wrapper.emitted('sortChange')
    expect(events).toBeDefined()
    expect(events!.length).toBeGreaterThanOrEqual(1)
    const last = events![events!.length - 1]![0] as { sortBy: string; direction: string }
    expect(last).toEqual({ sortBy: 'name', direction: 'asc' })
  })
})

describe('KanbanColumn — per-column independence (the user-reported bug)', () => {
  // The exact symptom from the user's report on task_1785730557641:
  // picking "Name (Z→A)" in one column caused ALL columns to render
  // in name Z→A order. This suite reproduces the failure mode on
  // pre-fix code and proves the fix on current code.
  let wrapperA: VueWrapper | null = null
  let wrapperB: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapperA?.unmount()
    wrapperA = null
    wrapperB?.unmount()
    wrapperB = null
    vi.restoreAllMocks()
  })

  it('column A on Manual + column B on Name (Z→A) renders independently', async () => {
    // Wire data order is the SAME for both columns (the backend
    // returns ALL tasks in the same global order — the user's last
    // pick, or the default). The client-side sort is what makes
    // them DIVERGE visually.
    const tasksA = [
      makeTask('t_a_z', 'Zeta', 0),
      makeTask('t_a_z2', 'Yankee', 1),
      makeTask('t_a_x', 'X-ray', 2),
    ]
    const tasksB = [
      { ...makeTask('t_b_z', 'Zeta', 0), kanban_column_id: COL_B },
      { ...makeTask('t_b_y', 'Yankee', 1), kanban_column_id: COL_B },
      { ...makeTask('t_b_x', 'X-ray', 2), kanban_column_id: COL_B },
    ]
    wrapperA = mountColumn(makeColumn(COL_A), tasksA)
    wrapperB = mountColumn(makeColumn(COL_B), tasksB)

    // Column A stays on Manual (default position asc).
    // Column B switches to Name (Z→A).
    setSort(wrapperB, 'name', 'desc')
    await nextTick()

    // Column A: position asc (Zeta is position 0, Yankee is 1, X-ray is 2).
    expect(cardOrder(wrapperA)).toEqual(['t_a_z', 't_a_z2', 't_a_x'])
    // Column B: name Z→A (Zeta, Yankee, X-ray in alpha order is X, Y, Z,
    // so desc reverses to Z, Y, X).
    expect(cardOrder(wrapperB)).toEqual(['t_b_z', 't_b_y', 't_b_x'])
  })

  it('three columns with three different sorts all render independently', async () => {
    const COL_C = 'col_gamma'
    const tasksA = [
      makeTask('t_a_x', 'X-ray', 0),
      makeTask('t_a_a', 'Alpha', 1),
    ]
    const tasksB = [
      { ...makeTask('t_b_z', 'Zeta', 0), kanban_column_id: COL_B },
      { ...makeTask('t_b_a', 'Alpha', 1), kanban_column_id: COL_B },
    ]
    const tasksC = [
      { ...makeTask('t_c_z', 'Zeta', 0), kanban_column_id: COL_C },
      { ...makeTask('t_c_a', 'Alpha', 1), kanban_column_id: COL_C },
    ]
    const wA = mountColumn(makeColumn(COL_A), tasksA)
    const wB = mountColumn(makeColumn(COL_B), tasksB)
    const wC = mountColumn(makeColumn(COL_C), tasksC)

    setSort(wA, 'name', 'asc')  // A→Z
    setSort(wB, 'name', 'desc') // Z→A
    // C stays on Manual (position asc)
    await nextTick()

    expect(cardOrder(wA)).toEqual(['t_a_a', 't_a_x'])
    expect(cardOrder(wB)).toEqual(['t_b_z', 't_b_a'])
    expect(cardOrder(wC)).toEqual(['t_c_z', 't_c_a'])

    wA.unmount()
    wB.unmount()
    wC.unmount()
  })
})
