/**
 * Tests for the column description subtitle rendered between the
 * header row (name + count + ⋮ menu) and the cards drop zone in
 * KanbanColumn.vue.
 *
 * The description element has data-testid="kanban-column-{id}-description"
 * and is shown only when column.description is truthy (non-empty
 * string). The backend sends "" as the "no description" sentinel,
 * so the v-if="column.description" guard handles:
 *   - "" (empty string from the backend's NOT NULL DEFAULT '' column)
 *   - null (the API JSON serializes the SQLite empty TEXT as null
 *     through some paths)
 *   - undefined (legacy column literals in test fixtures predate
 *     the description field)
 *
 * Plan: docs/superpowers/plans/2026-06-27-kanban-column-description-settings.md
 *   Chunk 2 / Task 2.4
 */
import { beforeEach, describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import KanbanColumn from '@/components/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnT, Task } from '@/api'

const baseColumn: KanbanColumnT = {
  id: 'col_test',
  workspace_item_id: 'wi_test',
  name: 'in_review',
  description: 'Awaiting code review',
  position: 0,
  created_at: '2026-06-26T10:00:00Z',
}

const baseTask: Task = {
  id: 'task_test',
  name: 'test task',
  kanban_column_id: null,
  kanban_position: 0,
}

describe('KanbanColumn description display', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders the description under the column name when present', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: baseColumn,
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(true)
    expect(desc.text()).toBe('Awaiting code review')
    expect((desc.element as HTMLParagraphElement).title).toBe('Awaiting code review')
    wrapper.unmount()
  })

  it('does not render the description element when description is empty', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: { ...baseColumn, description: '' },
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does not render the description element when description is null', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: { ...baseColumn, description: null },
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does not render the description element when description is undefined', () => {
    const columnWithoutDescription: KanbanColumnT = { ...baseColumn }
    delete columnWithoutDescription.description
    const wrapper = mount(KanbanColumn, {
      props: {
        column: columnWithoutDescription,
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })
})