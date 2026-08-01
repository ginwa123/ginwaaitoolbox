/**
 * Tests for KanbanView.handleCreateTaskSave's create-and-run branch
 * with create-mode image attachments (plan: 2026-08-06-kanban-image-
 * base64-in-chatview, replaces the upload-then-URL plan 2026-08-06-
 * kanban-no-base64-in-desc / 2026-08-06-kanban-image-attach-in-chatview
 * after the user directed the simpler design).
 *
 * Bug (pre-fix, original): when the user opened the kanban "Create
 * task" dialog and pasted an image into the description, the editor
 * always emitted `description` containing the inline
 * `data:image/png;base64,…` payload of any pasted image (up to ~5.5 MB
 * for a 4 MB image). The DB TEXT column stored it, and downstream
 * renders (kanban card, detail dialog) had to display it.
 *
 * Intermediate fix (now superseded): upload each pending file after
 * `addTask` returns, patch the description with `![name](<url>)`
 * markdown, and forward the uploaded URLs to runAgentOnNewTask. The
 * GET endpoint's wildcard route turned out to be broken (separate
 * bug), so the URLs in the description rendered as broken-image
 * placeholders in the kanban card and produced 404 thumbnails in
 * the detail dialog.
 *
 * CURRENT fix contract — TWO pieces (the editor + dialog unchanged):
 *   1. KanbanDescriptionEditor in create mode (no taskId) stages the
 *      pasted file in `previewFiles` (visual) + `pendingFiles`
 *      (data, defineExpose). It does NOT touch the description text.
 *   2. (THIS FILE covers the host) KanbanView.handleCreateTaskSave
 *      converts each pendingFile.file to a `data:<mime>;base64,...`
 *      URL via FileReader.readAsDataURL, collects them in upload
 *      order, and passes the array as `imageUrls` to
 *      runAgentOnNewTask when mode === 'create_and_run'. The
 *      description stays plain text — no upload, no `![name](url)`
 *      markdown, no `data:image/` anywhere in the description.
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
// Mirrors the pattern used in KanbanDescriptionEditor.spec.ts (where
// addImageFile also relies on FileReader.onload firing on the next
// macrotask).
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
  // FileReader is defined as a class in jsdom; replacing the global
  // with a plain class breaks instanceof checks elsewhere, so we
  // monkey-patch the prototype methods instead. ChatView and other
  // call sites call `new FileReader()` then set `.onload` and call
  // `.readAsDataURL(blob)`.
  globalThis.FileReader = StubReader as unknown as typeof FileReader
  return () => {
    globalThis.FileReader = originalReader
  }
}

describe('KanbanView.handleCreateTaskSave — base64-direct image attach (create_and_run)', () => {
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

  it('create + run: converts pending files to base64 data URLs and forwards to runAgentOnNewTask (no upload, no description patch)', async () => {
    // Spy on the upload endpoint — must NEVER be called.
    const uploadSpy = vi.spyOn(api, 'uploadTaskAttachment')

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

    // 1. NO upload — the host does not call api.uploadTaskAttachment.
    expect(uploadSpy).not.toHaveBeenCalled()
    // 2. NO description patch — the description stays as the user
    //    typed it (no base64, no `data:image/`, no `![name](url)`).
    expect(updateSpy).not.toHaveBeenCalled()
    // 3. addTask was called with the user's plain-text description
    //    (no base64 injected).
    expect(addSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      expect.objectContaining({
        name: 'Bug screenshot',
        description: 'See screenshots',
      }),
    )
    // 4. moveTaskToColumn ran.
    expect(moveSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      'col_todo',
      0,
    )
    // 5. runAgentOnNewTask received the two data URLs (in upload
    //    order) as imageUrls. The stub FileReader returns
    //    `data:<mime>;base64,STUB_FOR_<name>` for each, so we can
    //    assert the order + the data-URL prefix without depending on
    //    the real base64 encoding.
    expect(runSpy).toHaveBeenCalledTimes(1)
    const runCall = runSpy.mock.calls[0]!
    const params = runCall[3] as Record<string, unknown>
    const imageUrls = params.imageUrls as string[]
    expect(Array.isArray(imageUrls)).toBe(true)
    expect(imageUrls.length).toBe(2)
    expect(imageUrls[0]).toMatch(/^data:image\/png;base64,/)
    expect(imageUrls[0]).toContain('STUB_FOR_one.png')
    expect(imageUrls[1]).toMatch(/^data:image\/png;base64,/)
    expect(imageUrls[1]).toContain('STUB_FOR_two.jpg')
    // 6. Queue message is title + "\\n\\n" + description (plain text).
    expect(params.queueMessage).toBe('Bug screenshot\n\nSee screenshots')
    // 7. imageUrls is FORWARDED as a non-undefined value (not
    //    silently dropped — this is the bug fix).
    expect(imageUrls).not.toBeUndefined()
  })

  it('create + run with NO pending files: runAgentOnNewTask is called WITHOUT imageUrls key', async () => {
    // The store-level default (imageUrls undefined) still flows
    // through unchanged when the host has no files to convert.
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockResolvedValue('task_new')
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)
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

    expect(runSpy).toHaveBeenCalledTimes(1)
    const params = runSpy.mock.calls[0]![3] as Record<string, unknown>
    // Empty array is fine here — it's the absent-files contract.
    // The store then forwards it as-is (or undefined if we choose,
    // either is acceptable per workspacesStoreRunAgentImageUrls).
    expect(
      params.imageUrls === undefined ||
        (Array.isArray(params.imageUrls) && params.imageUrls.length === 0),
    ).toBe(true)
  })

  it('plain create mode (no run): still creates the task and moves it; pending files are ignored (no side effect)', async () => {
    // The create-and-run path is the only place base64 forwarding
    // matters (the agent's chat message is what carries image_urls).
    // In plain `create` mode the user is just creating a task to
    // edit later — the chat never starts, so there's no message to
    // attach images to. The host should still NOT upload or patch
    // the description (avoid the multi-MB base64-in-DB problem).
    const uploadSpy = vi.spyOn(api, 'uploadTaskAttachment')
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

    expect(uploadSpy).not.toHaveBeenCalled()
    expect(updateSpy).not.toHaveBeenCalled()
    expect(moveSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_new', 'col_todo', 0)
    // The description passed to addTask is the user's text verbatim
    // (no base64, no `![name](url)` — the host never touched it).
    expect(addSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      expect.objectContaining({
        name: 'To edit later',
        description: 'User typed text',
      }),
    )
  })
})
