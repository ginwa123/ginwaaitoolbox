/**
 * Tests for KanbanView.handleCreateTaskSave's create flow with
 * create-mode image attachments (plan: 2026-08-06-kanban-image-urls-column,
 * Migration 069).
 *
 * Bug (pre-fix, original): when the user opened the kanban "Create
 * task" dialog and pasted an image into the description, the editor
 * always emitted `description` containing the inline
 * `data:image/png;base64,…` payload of any pasted image (up to ~5.5 MB
 * for a 4 MB image). The DB TEXT column stored it, and downstream
 * renders (kanban card, detail dialog) had to display it.
 *
 * Intermediate fix (now superseded): upload each pending file via
 * the filesystem-backed attachment endpoint
 * (`POST /api/workspaces/tasks/<id>/attachments`) and patch the
 * description with `![name](<url>)` markdown. The GET endpoint's
 * wildcard route turned out to be broken (the custom router treats
 * `*` as a literal segment), so the URLs in the description
 * rendered as broken-image placeholders in the kanban card.
 *
 * CURRENT fix contract (Migration 069 — kanban image urls column).
 * Three pieces:
 *   1. KanbanDescriptionEditor in create mode (no taskId) stages the
 *      pasted file in `previewFiles` (visual) + `pendingFiles`
 *      (data, defineExpose). It does NOT touch the description text.
 *   2. (THIS FILE covers the host) KanbanView.handleCreateTaskSave
 *      converts each pendingFile.file to a `data:<mime>;base64,...`
 *      URL via FileReader.readAsDataURL, then PATCHes the new
 *      task's `image_urls` column via `updateTaskDetails({ imageUrls })`.
 *      The description stays plain text — no `data:image/` anywhere.
 *   3. In `create_and_run` mode the same `imageUrls` are ALSO
 *      forwarded to runAgentOnNewTask so the chatview's first user
 *      message renders them as thumbnails above the text (same UX
 *      as pasting an image directly into the chat input).
 *
 * Pieces (1) is covered by KanbanDescriptionEditor.spec.ts and the
 * dialog contract by KanbanTaskDetailDialog.createAttachments.spec.ts.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanView from '@/components/kanban/KanbanView.vue'
import * as api from '@/api'
import { useWorkspacesStore } from '@/stores/workspaces'

// Mirror the dialog's PreviewFile interface (defined in FilePreview.vue).
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

// Tiny PNG (1x1 transparent) — same bytes used in editor tests.
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

// Stub the global FileReader so the host's readAsDataURL returns a
// deterministic data URL that mirrors the source File's name + bytes.
// Mirrors the pattern used in KanbanDescriptionEditor.spec.ts.
function installFileReaderStub() {
  const originalReader = globalThis.FileReader
  class StubReader {
    public onload: ((ev: ProgressEvent<FileReader>) => void) | null = null
    public onerror: ((ev: ProgressEvent<FileReader>) => void) | null = null
    public result: string | null = null
    readAsDataURL(blob: Blob) {
      // Synthesise a `data:<mime>;base64,<placeholder>` whose prefix
      // makes it identifiable in assertions. Real encoding isn't
      // necessary — the host only forwards the string.
      const mime =
        (blob as File).type || (blob as Blob).type || 'application/octet-stream'
      const name = (blob as File).name ?? 'blob'
      this.result = `data:${mime};base64,STUB_FOR_${name}`
      // Fire onload on the next macrotask (matches real FileReader
      // scheduling).
      setTimeout(() => {
        this.onload?.({} as ProgressEvent<FileReader>)
      }, 0)
    }
  }
  globalThis.FileReader = StubReader as unknown as typeof FileReader
  return () => {
    globalThis.FileReader = originalReader
  }
}

describe('KanbanView.handleCreateTaskSave — image_urls column PATCH (Migration 069)', () => {
  let wrapper: VueWrapper | null = null
  let restoreReader: (() => void) | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    restoreReader = installFileReaderStub()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    restoreReader?.()
    restoreReader = null
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

  it('create + run: persists imageUrls on the new task AND forwards to runAgentOnNewTask', async () => {
    // Spy on updateTaskDetails — it MUST be called with the data URLs
    // (the new contract per Migration 069).
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    const updateSpy = vi.spyOn(store, 'updateTaskDetails').mockResolvedValue(undefined)
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runSpy = vi
      .spyOn(store, 'runAgentOnNewTask')
      .mockResolvedValue({ status: 'send' })

    const view = await mountView()
    const pendingFiles: PreviewFile[] = [
      { file: makeFile('one.png'), previewUrl: 'blob:1' },
      { file: makeFile('two.jpg'), previewUrl: 'blob:2' },
    ]
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'Bug screenshot',
      description: 'See screenshots',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles,
    })
    // FileReader.onload fires on the next macrotask — let the host's
    // await Promise.all(...) resolve.
    await new Promise((resolve) => setTimeout(resolve, 30))
    await flushPromises()

    // 1. addTask was called with the plain description (no base64).
    expect(addSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      expect.objectContaining({
        name: 'Bug screenshot',
        description: 'See screenshots',
      }),
    )
    // 2. moveTaskToColumn ran.
    expect(moveSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      'col_todo',
      0,
    )
    // 3. updateTaskDetails PATCHed imageUrls with the two data URLs
    //    (in upload order). This is the new contract — images are
    //    stored inline on the task row, not uploaded to a separate
    //    filesystem path.
    const updateCalls = updateSpy.mock.calls
    const imageUrlsCall = updateCalls.find(
      (c) => (c[3] as Record<string, unknown>).imageUrls !== undefined,
    )
    expect(imageUrlsCall).toBeDefined()
    const imageUrls = (imageUrlsCall![3] as Record<string, unknown>)
      .imageUrls as string[]
    expect(Array.isArray(imageUrls)).toBe(true)
    expect(imageUrls.length).toBe(2)
    expect(imageUrls[0]).toMatch(/^data:image\/png;base64,/)
    expect(imageUrls[0]).toContain('STUB_FOR_one.png')
    expect(imageUrls[1]).toMatch(/^data:image\/png;base64,/)
    expect(imageUrls[1]).toContain('STUB_FOR_two.jpg')
    // 4. runAgentOnNewTask received the same data URLs (so the chatview
    //    can render thumbnails above the text).
    expect(runSpy).toHaveBeenCalledTimes(1)
    const params = runSpy.mock.calls[0]![3] as Record<string, unknown>
    expect(params.imageUrls).toEqual(imageUrls)
    // 5. Queue message is plain text (no base64).
    expect(params.queueMessage).toBe('Bug screenshot\n\nSee screenshots')
  })

  it('plain create mode (no run): persists imageUrls on the new task', async () => {
    // The plain-create path is the critical fix — previously the
    // imageUrls were silently dropped (the bug). Now the data URLs
    // land in the image_urls column on the new task row.
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    const updateSpy = vi.spyOn(store, 'updateTaskDetails').mockResolvedValue(undefined)
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)

    const view = await mountView()
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create',
      name: 'To edit later',
      description: 'User typed text',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles: [
        { file: makeFile('one.png'), previewUrl: 'blob:1' },
      ],
    })
    await new Promise((resolve) => setTimeout(resolve, 30))
    await flushPromises()

    // 1. addTask was called with plain description (no base64).
    expect(addSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      expect.objectContaining({
        name: 'To edit later',
        description: 'User typed text',
      }),
    )
    // 2. moveTaskToColumn ran.
    expect(moveSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_new', 'col_todo', 0)
    // 3. updateTaskDetails PATCHed imageUrls (THIS IS THE FIX).
    const updateCalls = updateSpy.mock.calls
    const imageUrlsCall = updateCalls.find(
      (c) => (c[3] as Record<string, unknown>).imageUrls !== undefined,
    )
    expect(imageUrlsCall).toBeDefined()
    const imageUrls = (imageUrlsCall![3] as Record<string, unknown>)
      .imageUrls as string[]
    expect(imageUrls.length).toBe(1)
    expect(imageUrls[0]).toMatch(/^data:image\/png;base64,/)
    expect(imageUrls[0]).toContain('STUB_FOR_one.png')
  })

  it('create + run with NO pending files: image_urls column is NOT touched (empty array = no PATCH)', async () => {
    // Empty input is a no-op — no PATCH, no runAgent imageUrls passed.
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    const updateSpy = vi.spyOn(store, 'updateTaskDetails').mockResolvedValue(undefined)
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
    const runSpy = vi
      .spyOn(store, 'runAgentOnNewTask')
      .mockResolvedValue({ status: 'send' })

    const view = await mountView()
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'No images',
      description: 'Just text',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles: [],
    })
    await flushPromises()

    expect(addSpy).toHaveBeenCalledTimes(1)
    expect(moveSpy).toHaveBeenCalledTimes(1)
    // No imageUrls PATCH when the user didn't attach any images.
    const imageUrlsPatch = updateSpy.mock.calls.find(
      (c) => (c[3] as Record<string, unknown>).imageUrls !== undefined,
    )
    expect(imageUrlsPatch).toBeUndefined()
    // runAgent is still called, but imageUrls defaults to [].
    expect(runSpy).toHaveBeenCalledTimes(1)
    const params = runSpy.mock.calls[0]![3] as Record<string, unknown>
    expect(
      params.imageUrls === undefined ||
        (Array.isArray(params.imageUrls) && params.imageUrls.length === 0),
    ).toBe(true)
  })
})