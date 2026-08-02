/**
 * Behavioural tests for KanbanColumn's per-column sort state.
 *
 * Each KanbanColumn owns its own sortBy + direction refs (local,
 * NOT store, NOT URL). The sort applies in cardsInColumn — first
 * by the per-column mode, then by kanban_position asc as tiebreaker
 * (matches the backend's (sort_field, id) tuple pagination).
 *
 * Tests cover:
 *  - default sort = position asc (today's behaviour, no regression)
 *  - independent state across columns
 *  - sort application for name asc/desc, created_at desc
 *  - tiebreaker on equal sort-field values
 *  - setSortMode via defineExpose (the test seam; production code
 *    drives via the modal's v-model)
 *  - ⋮ menu has 3 items, "Sort tasks…" opens the modal
 *  - backdrop click + Esc + item-select all close the modal
 *
 * Plan: docs/superpowers/plans/2026-08-06-kanban-sort-by.md Tasks 3 + 4
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
// tests (and future URL-restore code, if requested separately) can
// drive the sort state without touching the modal flow.
function setSort(wrapper: VueWrapper, sortBy: string, direction: string) {
  ;(wrapper.vm as unknown as { setSortMode: (s: string, d: string) => void }).setSortMode(sortBy, direction)
}

function cardOrder(wrapper: VueWrapper): string[] {
  return wrapper
    .findAll('[data-kanban-card]')
    .map((node) => node.attributes('data-kanban-card') ?? '')
}

describe('KanbanColumn — per-column sort state', () => {
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

    setSort(wA, 'name', 'asc')
    await nextTick()
    expect(cardOrder(wA)).toEqual(['t_a_a', 't_a_z'])
    expect(cardOrder(wB)).toEqual(['t_b_a', 't_b_z'])

    wA.unmount()
    wB.unmount()
  })

  it('setting sortBy back to position restores the original kanban_position order', async () => {
    // Names whose alpha order does NOT match position order — switching
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
})

describe('KanbanColumn — ⋮ menu + sort modal', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('⋮ menu has 3 items in order: Rename, Sort tasks…, Delete', async () => {
    wrapper = mountColumn(makeColumn(COL_A))
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-trigger"]`).trigger('click')
    // The ⋮ menu's <ul> contains exactly Rename + Sort tasks… + Delete
    // — read the <li> children directly to skip the trigger button.
    const items = wrapper.findAll(
      `[data-testid="kanban-column-${COL_A}-menu"] > li > button`,
    )
    const itemIds = items.map((node) => node.attributes('data-testid'))
    expect(itemIds).toEqual([
      `kanban-column-${COL_A}-menu-rename`,
      `kanban-column-${COL_A}-menu-sort`,
      `kanban-column-${COL_A}-menu-delete`,
    ])
  })

  it('clicking "Sort tasks…" closes the menu + opens the sort modal', async () => {
    wrapper = mountColumn(makeColumn(COL_A))
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-trigger"]`).trigger('click')
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-menu"]`).exists()).toBe(true)
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-sort"]`).trigger('click')
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-menu"]`).exists()).toBe(false)
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-sort-modal"]`).exists()).toBe(true)
  })

  it('backdrop click closes the sort modal', async () => {
    wrapper = mountColumn(makeColumn(COL_A))
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-sort"]`).trigger('click')
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-sort-modal"]`).exists()).toBe(true)
    await wrapper
      .find(`[data-testid="kanban-column-${COL_A}-sort-modal"]`)
      .trigger('click')
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-sort-modal"]`).exists()).toBe(false)
  })

  it('Esc keydown closes the sort modal', async () => {
    wrapper = mountColumn(makeColumn(COL_A))
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-sort"]`).trigger('click')
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-sort-modal"]`).exists()).toBe(true)
    const event = new KeyboardEvent('keydown', { key: 'Escape' })
    document.dispatchEvent(event)
    await nextTick()
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-sort-modal"]`).exists()).toBe(false)
  })

  it('picking a sort item in the modal closes the modal + applies the sort', async () => {
    const tasks = [
      makeTask('t_b', 'Bravo', 0),
      makeTask('t_a', 'Alpha', 1),
      makeTask('t_c', 'Charlie', 2),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-${COL_A}-menu-sort"]`).trigger('click')
    // Modal mounts KanbanSortMenu with showTrigger=false — items
    // render immediately, no click needed.
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    expect(wrapper.find(`[data-testid="kanban-column-${COL_A}-sort-modal"]`).exists()).toBe(false)
    await nextTick()
    expect(cardOrder(wrapper)).toEqual(['t_a', 't_b', 't_c'])
  })
})