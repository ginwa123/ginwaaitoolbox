import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import KanbanList from '../KanbanList.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
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
      content: '<kanban><workspace_id>ws_1</workspace_id><item_id>item_1</item_id><columns><column><id>col_1</id><name>todo</name><position>0</position><task_count>1</task_count></column></columns><tasks><task><id>task_1</id><name>fix it</name><column_id>col_1</column_id><column_name>todo</column_name><position>0</position></task></tasks></kanban>',
      parameters: '<workspace_id>ws_1</workspace_id><item_id>item_1</item_id>',
    })
    const html = wrapper.html()
    expect(html).toContain('1 column')
    expect(html).toContain('1 task')
    expect(html.toLowerCase()).not.toContain('running')
    expect(wrapper.find('[data-testid="kanban-list-running"]').exists()).toBe(false)
  })
})
