import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import KanbanList from '../KanbanList.vue'

const makeWrapper = (props: { content: unknown; parameters?: string }) =>
  mount(KanbanList, { props: props as never })

describe('KanbanList.vue — in-progress placeholder', () => {
  it('shows running badge when content empty', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<workspace_id>ws_1</workspace_id><item_id>item_1</item_id>',
    })
    const html = wrapper.html()
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="kanban-list-running"]').exists()).toBe(true)
  })

  it('renders columns/tasks when completed (no running badge)', () => {
    const wrapper = makeWrapper({
      content: {
        workspace_id: 'ws_1',
        item_id: 'item_1',
        columns: [{ id: 'col_1', name: 'todo', position: 0, task_count: 1 }],
        tasks: [{ id: 'task_1', name: 'fix it', column_id: 'col_1', column_name: 'todo', position: 0 }],
        total_count: 1,
        limit: 50,
        offset: 0,
        has_more: false,
        hint: null,
      },
      parameters: '<workspace_id>ws_1</workspace_id><item_id>item_1</item_id>',
    })
    const html = wrapper.html()
    expect(html).toContain('1 column')
    expect(html).toContain('1 task')
    expect(html.toLowerCase()).not.toContain('running')
    expect(wrapper.find('[data-testid="kanban-list-running"]').exists()).toBe(false)
  })
})
