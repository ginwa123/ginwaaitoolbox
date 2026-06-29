/**
 * Tests for FileInput — chat input's @-triggered file/folder autocomplete.
 *
 * The component lets a user attach a folder to their message by typing
 * `@` in the textarea; the picker shows matching files/folders and the
 * user can select one (Enter or click). On selection, the matched
 * `@query` token is replaced by the picked path.
 *
 * Regression test for "keep the @ symbol on select":
 *   - When the user types `@d` and selects `/docs/superpowers`, the
 *     `@` trigger must be preserved in the input — the post-selection
 *     text should be `@/docs/superpowers`, not `/docs/superpowers`.
 *   - The pre-fix code sliced off `atMatch[0].length` (which INCLUDES
 *     the `@`) and replaced with `file.path`, losing the `@`.
 *
 * Plan: docs/plans/2026-06-26-keep-at-on-select.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from '@/components/FileInput.vue'

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
 * in-memory tree. The component's `loadAllFiles` does a depth-first
 * scan, so we need to return the entries for any scanned path.
 */
function mockFolderTree(
  tree: Record<string, Array<{ name: string; path: string; is_directory: boolean }>>,
) {
  fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
    const urlStr = typeof input === 'string' ? input : input.toString()
    const m = urlStr.match(/[?&]path=([^&]+)/)
    const path = m ? decodeURIComponent(m[1] ?? '') : ''
    return jsonResponse({ entries: tree[path] ?? [] })
  })
}

/**
 * Set the textarea's value and explicitly position the cursor at the
 * end, then dispatch `input` so the component's `autoResize` handler
 * runs and updates `cursorPos`. jsdom does not always move
 * `selectionStart` to the end of a programmatically-set `.value`.
 */
async function typeInTextarea(
  textareaWrapper: ReturnType<VueWrapper['find']>,
  value: string,
) {
  const element = textareaWrapper.element as HTMLTextAreaElement
  await textareaWrapper.setValue(value)
  element.setSelectionRange(value.length, value.length)
  element.dispatchEvent(new Event('input', { bubbles: true }))
  // Wait for the 150ms debounce on detectAtTrigger + any async scan chain.
  await new Promise((resolve) => setTimeout(resolve, 250))
  await flushPromises()
}

const originalFetch = global.fetch
const fetchMock = vi.fn()

async function mountInput(propsOverride: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user', ...propsOverride },
  })
  await flushPromises()
  return wrapper
}

describe('FileInput — @ autocomplete on select keeps the @ symbol', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('preserves @ when the user types a query and presses Enter to pick the first match', async () => {
    // /home/user has both `/docs` (matches "d") and a non-matching `/bin`.
    // /home/user/docs has `/docs/superpowers` (also matches "d"). Lexical
    // order: "/docs" < "/docs/superpowers", so /docs lands at index 0.
    // The picker is sorted by relative path ascending, so the highlighted
    // first entry for "@d" is always the shortest path starting with "d".
    mockFolderTree({
      '/home/user': [
        { name: 'bin', path: '/home/user/bin', is_directory: true },
        { name: 'docs', path: '/home/user/docs', is_directory: true },
      ],
      '/home/user/bin': [],
      '/home/user/docs': [
        { name: 'superpowers', path: '/home/user/docs/superpowers', is_directory: true },
      ],
      '/home/user/docs/superpowers': [],
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@d')

    // File picker should be open with at least one match.
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Press Enter — selectedFileIndex starts at 0, so the first match (/docs)
    // is selected.
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    // BUG (pre-fix): /docs  — the @ was lost
    // FIX:           @/docs — the @ is preserved
    expect(finalValue).toBe('@/docs')
  })

  it('preserves @ when prefix text is present (e.g. "Hello @d")', async () => {
    mockFolderTree({
      '/home/user': [
        { name: 'docs', path: '/home/user/docs', is_directory: true },
      ],
      '/home/user/docs': [],
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, 'Hello @d')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('Hello @/docs')
  })

  it('preserves @ when the user clicks a folder in the picker (just "@", no query)', async () => {
    mockFolderTree({
      '/home/user': [
        { name: 'bin', path: '/home/user/bin', is_directory: true },
        { name: 'docs', path: '/home/user/docs', is_directory: true },
      ],
      '/home/user/bin': [],
      '/home/user/docs': [],
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Click the first folder button (bin).
    const buttons = wrapper.findAll('.file-picker-list button')
    expect(buttons.length).toBeGreaterThan(0)
    await (buttons[0]!).trigger('click')
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('@/bin')
  })

  it('preserves @ when the user types a partial path like "@/doc" then selects', async () => {
    mockFolderTree({
      '/home/user': [
        { name: 'docs', path: '/home/user/docs', is_directory: true },
      ],
      '/home/user/docs': [
        { name: 'superpowers', path: '/home/user/docs/superpowers', is_directory: true },
      ],
      '/home/user/docs/superpowers': [],
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@/doc')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    // The "/doc" query is replaced by the full relative path; the @
    // is preserved as a prefix marker.
    expect(finalValue).toBe('@/docs')
  })

  it('does not modify the input when Enter is pressed without a selection (no matches)', async () => {
    // Empty tree — no matches.
    mockFolderTree({ '/home/user': [] })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@zzz')

    // No matches, no "selected file" → Enter should be a no-op on the input.
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('@zzz')
  })
})
