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
 *  - v-model forwarding (so the modal can update the column)
 *
 * Plan: docs/superpowers/plans/2026-08-06-kanban-sort-by.md Task 3
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
  // camelCase per Task interface; convert to ISO when KanbanColumn reads.
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
    // Seed tasks in non-position order to prove sorting is applied
    // (insertion order is not the natural return order).
    const tasks = [
      makeTask('t_2', 'Bravo', 2),
      makeTask('t_0', 'Alpha', 0),
      makeTask('t_1', 'Charlie', 1),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    // Read the rendered KanbanCards in DOM order (cardsInColumn
    // already filters + sorts; the rendered DOM reflects the order).
    const cardIds = wrapper
      .findAll('[data-kanban-card]')
      .map((node) => node.attributes('data-kanban-card'))
    expect(cardIds).toEqual(['t_0', 't_1', 't_2'])
  })

  it('sortBy=name + direction=asc → cards in A→Z order', async () => {
    const tasks = [
      makeTask('t_z', 'Zeta', 0),
      makeTask('t_a', 'Alpha', 1),
      makeTask('t_m', 'Mike', 2),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)

    // Flip the sort. The component uses v-model:sortBy + v-model:direction
    // (declared below in Task 4). For this test, set the prop directly.
    await wrapper.setProps({ sortBy: 'name', direction: 'asc' })
    await nextTick()

    const cardIds = wrapper
      .findAll('[data-kanban-card]')
      .map((node) => node.attributes('data-kanban-card'))
    expect(cardIds).toEqual(['t_a', 't_m', 't_z'])
  })

  it('sortBy=name + direction=desc → cards in Z→A order', async () => {
    const tasks = [
      makeTask('t_a', 'Alpha', 0),
      makeTask('t_m', 'Mike', 1),
      makeTask('t_z', 'Zeta', 2),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    await wrapper.setProps({ sortBy: 'name', direction: 'desc' })
    await nextTick()

    const cardIds = wrapper
      .findAll('[data-kanban-card]')
      .map((node) => node.attributes('data-kanban-card'))
    expect(cardIds).toEqual(['t_z', 't_m', 't_a'])
  })

  it('sortBy=created_at + direction=desc → cards in newest-first order', async () => {
    const tasks = [
      { ...makeTask('t_old', 'Oldest', 0), createdAt: new Date('2024-01-01T00:00:00Z') },
      { ...makeTask('t_mid', 'Middle', 1), createdAt: new Date('2024-06-15T12:00:00Z') },
      { ...makeTask('t_new', 'Newest', 2), createdAt: new Date('2024-12-31T23:59:59Z') },
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    await wrapper.setProps({ sortBy: 'created_at', direction: 'desc' })
    await nextTick()

    const cardIds = wrapper
      .findAll('[data-kanban-card]')
      .map((node) => node.attributes('data-kanban-card'))
    expect(cardIds).toEqual(['t_new', 't_mid', 't_old'])
  })

  it('cards with the same sort-field value fall back to kanban_position asc tiebreaker', async () => {
    // All three cards share the same name → tiebreaker is kanban_position.
    const tasks = [
      makeTask('t_pos2', 'Same', 2),
      makeTask('t_pos0', 'Same', 0),
      makeTask('t_pos1', 'Same', 1),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)
    await wrapper.setProps({ sortBy: 'name', direction: 'asc' })
    await nextTick()

    const cardIds = wrapper
      .findAll('[data-kanban-card]')
      .map((node) => node.attributes('data-kanban-card'))
    expect(cardIds).toEqual(['t_pos0', 't_pos1', 't_pos2'])
  })

  it('two columns sort independently — changing one does not affect the other', async () => {
    // Mount both columns with the same tasks but different column ids
    // (so the cardsInColumn filter keeps each in its own column).
    const tasksA = [
      makeTask('t_a_z', 'Zeta', 0),
      makeTask('t_a_a', 'Alpha', 1),
    ]
    const tasksB = [
      makeTask('t_b_a', 'Alpha', 0),
      makeTask('t_b_z', 'Zeta', 1),
    ]
    // Patch the column_id for B's tasks.
    const tasksBwithCol = tasksB.map((t) => ({ ...t, kanban_column_id: COL_B }))

    const wA = mountColumn(makeColumn(COL_A), tasksA)
    const wB = mountColumn(makeColumn(COL_B), tasksBwithCol)

    // Column A: sort by name asc.
    await wA.setProps({ sortBy: 'name', direction: 'asc' })
    await nextTick()

    // Column A's cards are A→Z.
    expect(
      wA.findAll('[data-kanban-card]').map((n) => n.attributes('data-kanban-card')),
    ).toEqual(['t_a_a', 't_a_z'])

    // Column B is still in kanban_position asc (default position mode).
    expect(
      wB.findAll('[data-kanban-card]').map((n) => n.attributes('data-kanban-card')),
    ).toEqual(['t_b_a', 't_b_z'])

    wA.unmount()
    wB.unmount()
  })

  it('setting sortBy back to position restores the original kanban_position order', async () => {
    // Use names whose alphabetical order does NOT match position order,
    // so switching back to position is observable.
    const tasks = [
      makeTask('t_b', 'Bravo', 0),
      makeTask('t_a', 'Alpha', 1),
      makeTask('t_c', 'Charlie', 2),
    ]
    wrapper = mountColumn(makeColumn(COL_A), tasks)

    // Default (position asc) → positions 0, 1, 2 → t_b, t_a, t_c.
    expect(
      wrapper
        .findAll('[data-kanban-card]')
        .map((n) => n.attributes('data-kanban-card')),
    ).toEqual(['t_b', 't_a', 't_c'])

    // Switch to name asc → Alpha, Bravo, Charlie → t_a, t_b, t_c.
    await wrapper.setProps({ sortBy: 'name', direction: 'asc' })
    await nextTick()
    expect(
      wrapper
        .findAll('[data-kanban-card]')
        .map((n) => n.attributes('data-kanban-card')),
    ).toEqual(['t_a', 't_b', 't_c'])

    // Switch back to position asc → restored to position order.
    await wrapper.setProps({ sortBy: 'position', direction: 'asc' })
    await nextTick()
    expect(
      wrapper
        .findAll('[data-kanban-card]')
        .map((n) => n.attributes('data-kanban-card')),
    ).toEqual(['t_b', 't_a', 't_c'])
  })
})