/**
 * Tests for KanbanView.handleCreateTaskSave's create-then-upload branch
 * when the dialog passes `pendingFiles` (plan: 2026-08-06-kanban-no-
 * base64-in-desc).
 *
 * Bug (pre-fix): the dialog's "Create task" flow always emitted
 * `description` containing the inline `data:image/png;base64,…` payload
 * of any pasted image (up to ~5.5 MB for a 4 MB image). The host created
 * the task with that blob, the DB TEXT column stored it, and downstream
 * renders (chat view, task card) had to display it.
 *
 * Fix contract — three pieces:
 *   1. Editor stages the file in `pendingFiles` (no base64 in `description`).
 *   2. Dialog emits `pendingFiles: PreviewFile[]` in `create` /
 *      `create-and-run`.
 *   3. THIS FILE — host uploads each pending file AFTER `addTask`
 *      returns the new taskId, then patches the description with
 *      `![name](<url>)` markdown via `updateTaskDetails`.
 *
 * Pieces (1) and (2) are covered by KanbanDescriptionEditor.spec.ts and
 * KanbanTaskDetailDialog.createAttachments.spec.ts. These tests verify
 * the host's orchestration.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanView from '@/components/kanban/KanbanView.vue'
import * as api from '@/api'
import { useWorkspacesStore } from '@/stores/workspaces'

// Mirror the dialog's PictureFile interface (PreviewFile in FilePreview.vue).
interface PreviewFile {
  file: File
  previewUrl: string
}

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

// Tiny PNG (1x1 transparent) — same bytes used in the editor tests.
function makeFile(name: string): File {
  const bytes = new Uint8Array([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
  ])
  return new File([bytes], name, { type: 'image/png' })
}

describe('KanbanView.handleCreateTaskSave — pendingFiles upload orchestration', () => {
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
    ;(wrapper!.vm as any).activeCreateColumnId = 'col_todo'
    return wrapper!
  }

  it('does NOT upload or patch when pendingFiles is empty', async () => {
    const uploadSpy = vi.spyOn(api, 'uploadTaskAttachment').mockResolvedValue({
      url: '/api/x',
      size: 1,
    })
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    const updateSpy = vi.spyOn(store, 'updateTaskDetails').mockResolvedValue(undefined)
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)

    const view = await mountView()
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create',
      name: 'No images',
      description: 'Just text',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles: [],
    })
    await flushPromises()

    expect(uploadSpy).not.toHaveBeenCalled()
    expect(updateSpy).not.toHaveBeenCalled()
  })

  it('uploads each pending file after addTask and patches the description with ![]() URLs', async () => {
    // Order: addTask → uploadTaskAttachment (per file) → updateTaskDetails
    // → moveTaskToColumn. Any other order means the description is
    // patched before the URLs exist, or the column is moved before the
    // description is finalized.
    const uploadSpy = vi
      .spyOn(api, 'uploadTaskAttachment')
      .mockResolvedValueOnce({
        url: '/api/workspaces/tasks/task_new/attachments/1.png',
        size: 100,
      })
      .mockResolvedValueOnce({
        url: '/api/workspaces/tasks/task_new/attachments/2.png',
        size: 200,
      })
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    const updateSpy = vi.spyOn(store, 'updateTaskDetails').mockResolvedValue(undefined)
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)

    const view = await mountView()
    const pendingFiles: PreviewFile[] = [
      { file: makeFile('one.png'), previewUrl: 'blob:1' },
      { file: makeFile('two.png'), previewUrl: 'blob:2' },
    ]
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create',
      name: 'With images',
      description: 'User typed text',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles,
    })
    await flushPromises()

    // 1. addTask was called with the user text (no base64).
    expect(addSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      expect.objectContaining({
        name: 'With images',
        description: 'User typed text',
      }),
    )
    // 2. Each pending file was uploaded with the new taskId.
    expect(uploadSpy).toHaveBeenCalledTimes(2)
    expect(uploadSpy).toHaveBeenNthCalledWith(1, 'task_new', pendingFiles[0]!.file)
    expect(uploadSpy).toHaveBeenNthCalledWith(2, 'task_new', pendingFiles[1]!.file)
    // 3. updateTaskDetails was called with a description that contains
    //    the user's text AND the appended `![name](<url>)` markdown
    //    for each uploaded file. NO base64 in the description.
    expect(updateSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      expect.objectContaining({
        description: expect.stringContaining('User typed text'),
      }),
    )
    const patchedDescription = updateSpy.mock.calls[0]![3]!.description as string
    expect(patchedDescription).not.toContain('data:image/')
    expect(patchedDescription).not.toContain('base64')
    expect(patchedDescription).toContain('![one.png](/api/workspaces/tasks/task_new/attachments/1.png)')
    expect(patchedDescription).toContain('![two.png](/api/workspaces/tasks/task_new/attachments/2.png)')
    // 4. moveTaskToColumn ran after the description was patched.
    expect(moveSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_new', 'col_todo', 0)
  })

  it('surfaces upload errors and keeps the dialog open (no move, no run)', async () => {
    // If the upload fails, the host should NOT proceed with the
    // move-to-column or run-agent flow. The task is created (with
    // text-only description) and createError gets the error message
    // so the dialog can show it.
    vi.spyOn(api, 'uploadTaskAttachment').mockRejectedValue(
      new Error('Attachment upload failed (500): server error'),
    )
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    const updateSpy = vi.spyOn(store, 'updateTaskDetails').mockResolvedValue(undefined)
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runSpy = vi.spyOn(store, 'runAgentOnNewTask').mockResolvedValue({ status: 'send' })

    const view = await mountView()
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'Will fail upload',
      description: 'Bug screenshot',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles: [{ file: makeFile('bad.png'), previewUrl: 'blob:bad' }],
    })
    await flushPromises()

    // updateSpy may not be called (no successful uploads to patch).
    expect(updateSpy).not.toHaveBeenCalled()
    expect(moveSpy).not.toHaveBeenCalled()
    expect(runSpy).not.toHaveBeenCalled()
    // The host's createError is set so the dialog can surface it.
    expect((view.vm as any).createError).toBeTruthy()
    expect((view.vm as any).createError).toContain('upload')
  })

  it('preserves the (empty) create-error path: pendingFiles=[] continues cleanly to move', async () => {
    // Sanity check — the empty path still calls moveTaskToColumn.
    const uploadSpy = vi.spyOn(api, 'uploadTaskAttachment')
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'updateTaskDetails').mockResolvedValue(undefined)
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)

    const view = await mountView()
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create',
      name: 'sanity',
      description: '',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles: [],
    })
    await flushPromises()

    expect(uploadSpy).not.toHaveBeenCalled()
    expect(moveSpy).toHaveBeenCalled()
    expect((view.vm as any).createError).toBeNull()
  })
})
