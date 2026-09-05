import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import KanbanMove from '../KanbanMove.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
  mount(KanbanMove, { props: props as never })

describe('KanbanMove.vue — in-progress placeholder', () => {
  it('shows task/column from XML parameters when content empty (not unknown + running)', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<task_id>task_1782549179378</task_id><target_column_name>done</target_column_name>',
    })
    const html = wrapper.html()
    expect(html).toContain('task_1782549179378')
    expect(html).toContain('done')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="kanban-move-running"]').exists()).toBe(true)
  })

  it('prefers content when completed', () => {
    const wrapper = makeWrapper({
      content: '<kanban_move><success>true</success><task_id>task_1</task_id><task_name>from-content</task_name><column_id>col_1</column_id><column_name>in progress</column_name><position>0</position></kanban_move>',
      parameters: '<task_id>task_2</task_id><target_column_name>done</target_column_name>',
    })
    const html = wrapper.html()
    expect(html).toContain('from-content')
    expect(html).toContain('in progress')
    expect(html).not.toContain('task_2')
    expect(html.toLowerCase()).not.toContain('running')
  })
})
