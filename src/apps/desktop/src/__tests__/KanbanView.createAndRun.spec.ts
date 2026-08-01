/**
 * Tests for KanbanView.handleCreateTaskSave's
 * `mode: 'create_and_run'` branch.
 *
 * Mount pattern: shallow mount with stub children + vi.spyOn for the
 * store actions. We assert the call ORDER and payload, not the
 * implementation details. The dialog emit is mocked via the parent
 * by reaching into the dialog component.
 *
 * Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
 *   Task 3 / Step 3.1
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanView from '@/components/kanban/KanbanView.vue'
import * as api from '@/api'
import { useWorkspacesStore } from '@/stores/workspaces'
import { useNotificationStore } from '@/stores/notifications'

// Stub the heavy children — we only test the host's handleCreateTaskSave.
vi.mock('@/components/kanban/KanbanColumn.vue', () => ({
  default: { name: 'KanbanColumn', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanSearchInput.vue', () => ({
  default: { name: 'KanbanSearchInput', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanTaskDetailDialog.vue', () => ({
  default: {
    name: 'KanbanTaskDetailDialog',
    template: '<div data-testid="stub-dialog" />',
  },
}))
vi.mock('@/composables/useKanbanScrollRestore', () => ({
  useKanbanScrollRestore: () => ({}),
}))
vi.mock('@/components/preview/InlineEditableText.vue', () => ({
  default: { name: 'InlineEditableText', template: '<div />' },
}))

const ITEM: any = {
  id: 'item_1',
  name: 'Kanban',
  path: '/home/u/proj',
  tasks: [],
  kanban_columns: [
    { id: 'col_todo', name: 'todo', position: 0, workspace_item_id: 'item_1' },
  ],
}

describe('KanbanView.handleCreateTaskSave — create_and_run', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  async function mountView() {
    wrapper = mount(KanbanView, {
      props: {
        item: structuredClone(ITEM),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()
    // The host guards handleCreateTaskSave on `activeCreateColumnId`
    // (set when the user clicks + on a column). Set it directly via
    // the vm so we don't have to drive the @add-task emit path.
    ;(wrapper!.vm as any).activeCreateColumnId = 'col_todo'
    return wrapper!
  }

  it('creates the task, moves it to the column, then runs the agent — in that order', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 'My task',
      description: 'desc',
      task_type: 'standard',
    })
    vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'send' })

    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runSpy = vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue({ status: 'send' })

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      description: 'desc',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    // Call order: addTask -> moveTaskToColumn -> runAgentOnNewTask
    const addOrder = addSpy.mock.invocationCallOrder[0]!
    const moveOrder = moveSpy.mock.invocationCallOrder[0]!
    const runOrder = runSpy.mock.invocationCallOrder[0]!
    expect(addOrder).toBeLessThan(moveOrder)
    expect(moveOrder).toBeLessThan(runOrder)

    // Queue message is title + "\n\n" + description
    // NEW (plan: 2026-08-06-kanban-task-profile-selector): use
    // objectContaining so the new selectedProfile field doesn't
    // break this assertion (default empty string).
    expect(runSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      expect.objectContaining({
        queueMessage: 'My task\n\ndesc',
        cwd: '/home/u/proj',
        isAutoRetryUntilStop: '0',
      }),
    )
    // Reuses the existing selectTask emit so the AppLayout -> Sidebar
    // chain handles setActiveTask + router.replace (D1 from the plan).
    expect(view.emitted('selectTask')).toBeTruthy()
    expect(view.emitted('selectTask')![0]).toEqual(['task_new'])
  })

  it('queue message is just the title when description is empty', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 'Just title',
      description: '',
      task_type: 'standard',
    })
    vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'send' })

    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runSpy = vi
      .spyOn(store, 'runAgentOnNewTask')
      .mockResolvedValue({ status: 'send' })

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'Just title',
      description: '',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    expect(runSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      expect.objectContaining({
        queueMessage: 'Just title',
        cwd: '/home/u/proj',
        isAutoRetryUntilStop: '0',
      }),
    )
  })

  it('forwards unattended toggle value', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 'My task',
      description: 'd',
      task_type: 'standard',
    })
    vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'send' })

    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runSpy = vi
      .spyOn(store, 'runAgentOnNewTask')
      .mockResolvedValue({ status: 'send' })

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      description: 'd',
      is_auto_retry_until_stop: '1',
      tags: [],
    })
    await flushPromises()
    expect(runSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      expect.objectContaining({
        queueMessage: 'My task\n\nd',
        cwd: '/home/u/proj',
        isAutoRetryUntilStop: '1',
      }),
    )
  })

  it('does NOT navigate when runAgentOnNewTask returns undefined (partial success)', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 't',
      description: 'd',
      task_type: 'standard',
    })
    vi.spyOn(api, 'sendChatMessage').mockRejectedValue(new Error('boom'))

    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue(undefined)
    const notifySpy = vi.spyOn(useNotificationStore(), 'notifyError')

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    expect(view.emitted('selectTask')).toBeUndefined()
    expect(notifySpy).toHaveBeenCalled()
  })

  it('does NOT navigate when runAgentOnNewTask returns status != queued', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 't',
      description: 'd',
      task_type: 'standard',
    })

    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue({ status: 'offline' })

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()
    expect(view.emitted('selectTask')).toBeUndefined()
  })

  it('still creates the task in plain create mode (existing behavior unchanged)', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 't',
      description: 'd',
      task_type: 'standard',
    })

    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runAgentSpy = vi.spyOn(store, 'runAgentOnNewTask')

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()
    expect(runAgentSpy).not.toHaveBeenCalled()
    expect(view.emitted('selectTask')).toBeUndefined()
  })

  // NEW (plan: 2026-08-06-kanban-task-profile-selector)
  it('forwards selectedProfile from dialog emit to runAgentOnNewTask', async () => {
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_new',
      name: 'My task',
      description: 'desc',
      task_type: 'standard',
    })
    vi.spyOn(api, 'sendChatMessage').mockResolvedValue({ status: 'send' })

    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runSpy = vi
      .spyOn(store, 'runAgentOnNewTask')
      .mockResolvedValue({ status: 'send' })

    const view = await mountView()
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      description: 'desc',
      is_auto_retry_until_stop: '0',
      tags: [],
      selectedProfile: '900r1bu',
    })
    await flushPromises()

    expect(runSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      expect.objectContaining({
        selectedProfile: '900r1bu',
      }),
    )
  })
})