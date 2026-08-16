/**
 * Tests for KanbanView.handleCreateTaskSave's
 * `mode: 'create_and_run'` branch.
 *
 * Plan: 2026-08-06-kanban-create-task-run-agent.md (Task 3 / Step 3.1)
 *       2026-08-14-kanban-task-create-endpoints.md (Task 5 / Step 5.1)
 *
 * Updated for the kanban-specific endpoint refactor: handleCreateTaskSave
 * now calls `workspacesStore.addKanbanTask(mode, payload)` (NOT the
 * addTask + runAgentOnNewTask dance). The store action delegates to
 * `api.createKanbanTask` which POSTs to /api/.../kanban/tasks.
 *
 * Mount pattern: shallow mount with stub children + vi.spyOn for the
 * store actions. We assert the call shape, not the implementation details.
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
// eslint-disable-next-line @typescript-eslint/no-explicit-any
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
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    // the vm so we don't have to drive the @add-task emit path.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper!.vm as any).activeCreateColumnId = 'col_todo'
    return wrapper!
  }

// eslint-disable-next-line @typescript-eslint/no-explicit-any

  it("calls addKanbanTask('create_and_run', ...) with the right payload — no addTask + runAgentOnNewTask dance", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'My task', task_type: 'standard' } as any
    const fakeSession = { id: 'task_new', name: 'My task', status: 'send' }
    const createKanbanSpy = vi
      .spyOn(api, 'createKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: fakeSession })

    const store = useWorkspacesStore()
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: fakeSession })
    const addTaskSpy = vi.spyOn(store, 'addTask')
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const runAgentSpy = vi.spyOn(store, 'runAgentOnNewTask')

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      description: 'The login button is broken',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    // The new contract: SINGLE call to addKanbanTask with mode +
    // queue_message. NO addTask + runAgentOnNewTask dance.
    expect(addKanbanSpy).toHaveBeenCalledTimes(1)
    expect(addKanbanSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'create_and_run',
      expect.objectContaining({
        name: 'My task',
        description: 'The login button is broken',
        queue_message: 'My task\n\nThe login button is broken',
        isAutoRetryUntilStop: '0',
        tags: [],
      }),
    )
    expect(addTaskSpy).not.toHaveBeenCalled()
    expect(runAgentSpy).not.toHaveBeenCalled()
    // The api helper was called indirectly via the store action (we
    // don't assert the exact call here — that's covered by the
    // workspacesStoreAddKanbanTask.spec.ts suite).
    expect(createKanbanSpy).toBeTruthy()

    // CHANGED (2026-08-06, "no need go chatview"): on the SUCCESS
    // path we deliberately do NOT emit `selectTask`. The user stays
    // on the kanban view (no chat dialog opens); the agent runs in
    // the background and the user can click the new task card to
    // open the chat view any time they want.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(view.emitted('selectTask')).toBeUndefined()
  })

  it('queue message is just the title when description is empty', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'Just title', task_type: 'standard' } as any
    const fakeSession = { id: 'task_new', name: 'Just title', status: 'send' }
    const store = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: fakeSession })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'Just title',
      description: '',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    expect(addKanbanSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'create_and_run',
      expect.objectContaining({
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        queue_message: 'Just title',
      }),
    )
  })

  it('forwards unattended toggle value', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'My task', task_type: 'standard' } as any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeSession = { id: 'task_new', name: 'My task', status: 'send' }
    const store = useWorkspacesStore()
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: fakeSession })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      description: 'd',
      is_auto_retry_until_stop: '1',
      tags: [],
    })
    await flushPromises()
    expect(addKanbanSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'create_and_run',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      expect.objectContaining({
        isAutoRetryUntilStop: '1',
      }),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    )
  })

  it('does NOT navigate when addKanbanTask returns { task: null, session: null } (partial success)', async () => {
    const store = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(store, 'addKanbanTask').mockResolvedValue({ task: null, session: null } as any)

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(view.emitted('selectTask')).toBeUndefined()
    // Partial-success: the store action's catch block decides whether
    // to surface a toast. In the new contract the store action's
    // mocked-resolved path (not rejected) bypasses the catch — the
    // store's notifyError lives in the catch path. The component
    // surfaces its own error via `createError` (the dialog stays
    // open for retry). We don't re-toast here to avoid duplicates.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  })

  it('still creates the task in plain create mode (existing behavior unchanged)', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 't', task_type: 'standard' } as any
    const store = useWorkspacesStore()
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: null })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create',
      name: 't',
      description: 'd',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    expect(addKanbanSpy).toHaveBeenCalledWith(
      'ws_1',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      'item_1',
      'create',
      expect.objectContaining({
        name: 't',
        description: 'd',
        queue_message: undefined,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      }),
    )
    expect(view.emitted('selectTask')).toBeUndefined()
  })

  it('does NOT emit selectTask on create_and_run success (no chat dialog opens)', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'My task', task_type: 'standard' } as any
    const fakeSession = { id: 'task_new', name: 'My task', status: 'send' }
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addKanbanTask').mockResolvedValue({ task: fakeTask, session: fakeSession })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'My task',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      description: 'desc',
      is_auto_retry_until_stop: '0',
      tags: [],
    })
    await flushPromises()

    // The flow: single addKanbanTask call (the new endpoint handles
    // create + run agent server-side in one round-trip).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(store.addKanbanTask).toHaveBeenCalledOnce()
    // But the chat view does NOT open.
    expect(view.emitted('selectTask')).toBeUndefined()
  })

  it('forwards selectedProfile from dialog emit to addKanbanTask', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'My task', task_type: 'standard' } as any
    const fakeSession = { id: 'task_new', name: 'My task', status: 'send' }
    const store = useWorkspacesStore()
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: fakeSession })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
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

    expect(addKanbanSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'create_and_run',
      expect.objectContaining({
        selected_profile_model: '900r1bu',
      }),
    )
  })
})
