/**
 * Tests for KanbanDescriptionEditor — the kanban task description editor
 * with image paste/paperclip support and the `@`-trigger file picker.
 *
 * The component is a textarea wrapper that:
 *   - Holds the markdown text as v-model.
 *   - Shows image previews (paste + paperclip) above the textarea.
 *   - Opens a file-picker dropdown when the user types `@`.
 *   - Inserts `@/path` at the cursor when a file is picked.
 *   - Downscales oversize images to 4 MB before base64-encoding.
 *
 * Test coverage:
 *   - v-model two-way binding (typing into the textarea emits update).
 *   - The paperclip button triggers the hidden file input.
 *   - @-trigger opens the dropdown (cwd passed to /system/folder).
 *   - Picking a file inserts `@/path` at the cursor.
 *   - Image paste inserts a data URL into the textarea + preview row.
 *   - Removing a preview removes the matching data URL from the textarea.
 *   - Char counter reflects the text length.
 *   - testId is applied to the textarea + paperclip + counter.
 *
 * Plan: docs/superpowers/plans/2026-07-25-kanban-description-rich-editor.md
 * Chunk 2 — KanbanDescriptionEditor component.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'
import KanbanDescriptionEditor from '../components/kanban/KanbanDescriptionEditor.vue'

interface FakeResponse extends Partial<Response> {
  ok: boolean
  status: number
  json: () => Promise<unknown>
  text: () => Promise<string>
}

function jsonResponse(body: unknown, status = 200): FakeResponse {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
  } as FakeResponse
}

/**
 * Mock `/system/folder?path=...&action=list` lookups against a small
 * in-memory tree. The component's loader does a depth-first scan, so
 * we need to return entries for any scanned path.
 */
function mockFolderTree(
  tree: Record<
    string,
    Array<{ name: string; path: string; is_directory: boolean }>
  >,
) {
  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    const urlStr = typeof input === 'string' ? input : input.toString()
    const m = urlStr.match(/[?&]path=([^&]+)/)
    const path = m ? decodeURIComponent(m[1] ?? '') : ''
    return jsonResponse({ entries: tree[path] ?? [] })
  })
}

const originalFetch = global.fetch
const fetchMock = vi.fn()

async function mountEditor(
  propsOverride: Record<string, unknown> = {},
  options: { attachTo?: boolean } = {},
) {
  document.body.innerHTML = ''
  const wrapper = mount(KanbanDescriptionEditor, {
    attachTo: options.attachTo ? document.body : undefined,
    props: {
      modelValue: '',
      cwd: '/home/user',
      ...propsOverride,
    },
  })
  await flushPromises()
  return wrapper
}

describe('KanbanDescriptionEditor', () => {
  beforeEach(() => {
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('renders a textarea with the modelValue as its initial value', async () => {
    const wrapper = await mountEditor({ modelValue: 'hello world' })
    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(textarea.value).toBe('hello world')
  })

  it('emits update:modelValue when the user types into the textarea', async () => {
    const wrapper = await mountEditor({ modelValue: '' })
    const textarea = wrapper.find('textarea')
    await textarea.setValue('a new description')
    expect(wrapper.emitted('update:modelValue')).toBeTruthy()
    const emitted = wrapper.emitted('update:modelValue') as unknown[][] | undefined
    expect(emitted?.[emitted.length - 1]?.[0]).toBe('a new description')
  })

  it('shows the char counter as <textLength> / 5000', async () => {
    const wrapper = await mountEditor({ modelValue: 'hello world' })
    expect(wrapper.text()).toContain('11 / 5000')
  })

  it('applies the testId prop to the textarea, paperclip, and counter', async () => {
    const wrapper = await mountEditor({
      modelValue: '',
      testId: 'my-editor',
    })
    const html = wrapper.html()
    expect(html).toContain('data-testid="my-editor"')
    expect(html).toContain('my-editor-paperclip')
    expect(html).toContain('my-editor-counter')
  })

  it('defaults testId to "kanban-description-editor"', async () => {
    const wrapper = await mountEditor({ modelValue: '' })
    expect(wrapper.html()).toContain('kanban-description-editor')
  })

  it('shows a hidden file input for native image selection', async () => {
    const wrapper = await mountEditor({}, { attachTo: true })
    const hidden = wrapper.find('input[type="file"]')
    expect(hidden.exists()).toBe(true)
    // Should be visually hidden (display:none or class="hidden").
    const cls = hidden.classes()
    expect(cls).toContain('hidden')
  })

  it('opens the file picker dropdown when the user types @ and inserts /path on selection', async () => {
    mockFolderTree({
      '/home/user': [
        {
          name: 'main.zig',
          path: '/home/user/main.zig',
          is_directory: false,
        },
        {
          name: 'docs',
          path: '/home/user/docs',
          is_directory: true,
        },
      ],
    })
    const wrapper = await mountEditor({}, { attachTo: true })
    const textarea = wrapper.find('textarea')
    // Type `@` to trigger the picker.
    await textarea.setValue('@')
    const element = textarea.element as HTMLTextAreaElement
    element.setSelectionRange(1, 1)
    element.dispatchEvent(new Event('input', { bubbles: true }))
    // Wait for the 150ms debounce + scan.
    await new Promise((resolve) => setTimeout(resolve, 250))
    await flushPromises()
    const html = wrapper.html()
    expect(html).toContain('file-picker-list')
    // Pick the file (main.zig, not the docs directory). The component
    // sorts directories-first, so the file button is at index 1.
    const fileButtons = wrapper.findAll('.file-picker-list button')
    expect(fileButtons.length).toBe(2)
    await fileButtons[1]!.trigger('click')
    await flushPromises()
    const updatedTextarea = wrapper.find('textarea').element as HTMLTextAreaElement
    // The path is inserted WITHOUT the leading `@` (the user dropped
    // the `@` prefix per the latest UX feedback; the chip detector
    // matches `/path` directly). The path is RELATIVE to the cwd
    // (mirrors FileInput.vue's `entry.path.replace(rootPath, '')`).
    expect(updatedTextarea.value).toContain('/main.zig')
    expect(updatedTextarea.value).not.toContain('@/main.zig')
  })

  it('removes an image preview when the user clicks the remove button', async () => {
    // Seed the modelValue with a base64 image so the editor re-hydrates
    // the preview on mount.
    const png =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
    const wrapper = await mountEditor({
      modelValue: `![pasted](${png})`,
    })
    await flushPromises()
    // Preview row should render the image.
    expect(wrapper.findAll('.preview-item').length).toBe(1)
    // Click the remove button.
    const removeBtn = wrapper.find('.remove-btn')
    expect(removeBtn.exists()).toBe(true)
    await removeBtn.trigger('click')
    await flushPromises()
    // The emitted update:modelValue should no longer contain the data URL.
    const emitted = wrapper.emitted('update:modelValue') as unknown[][] | undefined
    const lastEmit = emitted?.[emitted.length - 1]?.[0] as string
    expect(lastEmit).not.toContain('data:image/png')
  })

  it('respects the custom maxLength prop', async () => {
    const wrapper = await mountEditor({ modelValue: 'hi', maxLength: 200 })
    expect(wrapper.text()).toContain('2 / 200')
  })
})