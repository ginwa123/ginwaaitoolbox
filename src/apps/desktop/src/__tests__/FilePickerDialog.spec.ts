/**
 * Tests for FilePickerDialog — a generic, data-source-agnostic file/folder picker.
 *
 * The component is generic over the item type T. These tests use a MockEntry
 * shape (matching the codebase's FolderEntry from `src/api/index.ts`) but the
 * component works with any tree-shaped dataset — see the last `describe` block
 * for a git-branches example using a totally different item shape.
 *
 * IMPORTANT: The component uses both <Teleport to="body"> AND <Transition>.
 * @vue/test-utils stubs <Transition> by default, which means `wrapper.find()`
 * and `wrapper.text()` do NOT traverse into the dialog content. We must query
 * the document directly via `document.querySelector(selector)` for any
 * data-testid that lives inside the dialog. The helpers below (findInDom,
 * findAllInDom, clickInDom, keydownInDom) make that ergonomic.
 *
 * Pattern notes:
 * - `attachTo: document.body` is required for the Teleport to work in jsdom.
 * - `flushPromises` waits for the expandAncestors() chain to complete after modelValue flips.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import FilePickerDialog from '../components/FilePickerDialog.vue'

// Helpers — query the document directly because the dialog is teleported AND inside a Transition stub
function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  ;(el as HTMLElement).click()
}

function keydownInDom(key: string) {
  const el = findInDom('[data-testid="file-picker-dialog"]')
  if (!el) throw new Error('Dialog not in DOM')
  el.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }))
}

// Mock tree:
//   /
//   └── home
//       └── user
//           ├── docs    (dir)
//           ├── notes   (dir)
//           ├── readme  (file)
//           └── .hidden (file, hidden)
const tree: Record<string, Array<{ name: string; path: string; is_directory: boolean }>> = {
  '/': [{ name: 'home', path: '/home', is_directory: true }],
  '/home': [{ name: 'user', path: '/home/user', is_directory: true }],
  '/home/user': [
    { name: 'docs', path: '/home/user/docs', is_directory: true },
    { name: 'notes', path: '/home/user/notes', is_directory: true },
    { name: 'readme.md', path: '/home/user/readme.md', is_directory: false },
    { name: '.hidden', path: '/home/user/.hidden', is_directory: false },
  ],
  '/home/user/docs': [],
  '/home/user/notes': [
    { name: 'todo.txt', path: '/home/user/notes/todo.txt', is_directory: false },
  ],
}

interface MockEntry {
  name: string
  path: string
  is_directory: boolean
}

function makeLoadItems() {
  return vi.fn(async (path: string) => tree[path] ?? [])
}

function mountDialog(propsOverride: Record<string, unknown> = {}) {
  const loadItems = (propsOverride.loadItems as ReturnType<typeof makeLoadItems> | undefined) ?? makeLoadItems()
  return mount(FilePickerDialog<MockEntry>, {
    attachTo: document.body,
    props: {
      modelValue: false,
      loadItems,
      keyFor: (e: MockEntry) => e.path,
      pathFor: (e: MockEntry) => e.path,
      isExpandable: (e: MockEntry) => e.is_directory,
      ...propsOverride,
    },
  })
}

describe('FilePickerDialog — open/close lifecycle', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders nothing in the DOM when modelValue is false', () => {
    wrapper = mountDialog()
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()
  })

  it('mounts the dialog when modelValue flips to true', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
  })

  it('locks body scroll while open and restores on close', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(document.body.style.overflow).toBe('hidden')
    await wrapper.setProps({ modelValue: false })
    expect(document.body.style.overflow).toBe('')
  })
})

describe('FilePickerDialog — title and initial state', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('shows default title "Select Folder" in folder mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const dialog = findInDom('[data-testid="file-picker-dialog"]')
    expect(dialog?.textContent).toContain('Select Folder')
  })

  it('shows default title "Select File" in file mode', async () => {
    wrapper = mountDialog({ mode: 'file', initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Select File')
  })

  it('shows default title "Select Item" in both mode', async () => {
    wrapper = mountDialog({ mode: 'both', initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Select Item')
  })

  it('overrides default title via the title prop', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', title: 'Pick a parent dir' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const text = findInDom('[data-testid="file-picker-dialog"]')?.textContent ?? ''
    expect(text).toContain('Pick a parent dir')
    expect(text).not.toContain('Select Folder')
  })

  it('calls loadItems with the initialPath on open, expanding ancestors', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const calledPaths = loadItems.mock.calls.map(([p]) => p)
    // Should load /, /home, /home/user, /home/user/docs in that order
    expect(calledPaths).toEqual(['/', '/home', '/home/user', '/home/user/docs'])
  })
})

describe('FilePickerDialog — content rendering', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders items in the content pane after load', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/readme.md"]')).not.toBeNull()
  })

  it('hides hidden files by default', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).toBeNull()
  })

  it('shows hidden files when showHidden prop is true', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', showHidden: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).not.toBeNull()
  })

  it('toggles hidden files via the toolbar button', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).toBeNull()
    clickInDom('[data-testid="file-picker-hidden-toggle"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).not.toBeNull()
    clickInDom('[data-testid="file-picker-hidden-toggle"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).toBeNull()
  })

  it('shows the tree pane with expanded ancestors', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tree"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-tree-/home"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-tree-/home/user"]')).not.toBeNull()
  })

  it('shows the breadcrumb for the current path', async () => {
    wrapper = mountDialog({ initialPath: '/home/user/docs' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('home')
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('user')
    expect(findInDom('[data-testid="file-picker-crumb-2"]')?.textContent).toBe('docs')
  })

  it('hides the Up button at the filesystem root', async () => {
    wrapper = mountDialog({ initialPath: '/' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-up"]')).toBeNull()
  })
})

describe('FilePickerDialog — selection (folder mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('Select button is disabled when nothing is selected', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
  })

  it('clicking a folder in the content pane selects it (folder mode)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user/docs')
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(false)
  })

  it('clicking Select emits select and closes (closeOnSelect: true)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select"]')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user/docs'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('emits select but does NOT close when closeOnSelect is false', async () => {
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'folder',
      closeOnSelect: false,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select"]')
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user/docs'])
    expect(wrapper.emitted('update:modelValue')).toBeUndefined()
  })

  it('clicking a file in folder mode does NOT select it (mode restricts)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('(none)')
  })
})

describe('FilePickerDialog — selection (file mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking a file in file mode selects it', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'file' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe(
      '/home/user/readme.md',
    )
  })

  it('clicking a folder in file mode NAVIGATES INTO it (does not select)', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'file', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/notes"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('(none)')
  })
})

describe('FilePickerDialog — selection (both mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('shows filter chips in both mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'both' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-filter-all"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-filter-folders"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-filter-files"]')).not.toBeNull()
  })

  it('does NOT show filter chips in folder mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-filter-all"]')).toBeNull()
  })

  it('clicking Folders chip hides files', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'both' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-filter-folders"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/readme.md"]')).toBeNull()
  })

  it('clicking a file in both mode selects it', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'both' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe(
      '/home/user/readme.md',
    )
  })
})

describe('FilePickerDialog — search', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('filters content pane items by search query', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const search = findInDom('[data-testid="file-picker-search"]') as HTMLInputElement
    search.value = 'docs'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes"]')).toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/readme.md"]')).toBeNull()
  })

  it('shows empty state when search yields no matches', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const search = findInDom('[data-testid="file-picker-search"]') as HTMLInputElement
    search.value = 'zzzzzz'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('No matches')
  })
})

describe('FilePickerDialog — keyboard navigation', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('Escape closes the dialog and emits cancel', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    keydownInDom('Escape')
    await flushPromises()
    expect(wrapper.emitted('cancel')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('ArrowDown moves the highlight to the next item', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const items = findAllInDom('[data-testid^="file-picker-item-/home/user"]')
    expect(items.length).toBeGreaterThan(1)
    keydownInDom('ArrowDown')
    await flushPromises()
    const first = items[0] as HTMLElement
    expect(first.dataset.index).toBe('0')
    expect(first.getAttribute('aria-selected')).toBe('false')
    keydownInDom('ArrowDown')
    await flushPromises()
    const second = items[1] as HTMLElement
    expect(second.dataset.index).toBe('1')
  })

  it('Enter on a highlighted folder (folder mode, closeOnSelect: true) selects and closes', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    keydownInDom('ArrowDown')
    await flushPromises()
    keydownInDom('Enter')
    await flushPromises()
    expect(wrapper.emitted('select')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('Backspace navigates to the parent path', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    keydownInDom('Backspace')
    await flushPromises()
    // The crumb-1 ("user") should now be the last (current) segment
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('user')
  })
})

describe('FilePickerDialog — navigation', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking a breadcrumb segment navigates to that path', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-crumb-0"]')
    await flushPromises()
    // Should now be at /home — the breadcrumb shows just "home"
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('home')
  })

  it('clicking the Up button navigates to the parent path', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/notes', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-up"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
  })

  it('clicking the root "/" button navigates to the filesystem root', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-root"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tree-/home"]')).not.toBeNull()
  })

  it('clicking the close button emits cancel', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-close"]')
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('clicking the Cancel button emits cancel', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-cancel"]')
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('clicking the backdrop emits cancel', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-backdrop"]')
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })
})

describe('FilePickerDialog — error and empty states', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('shows error UI when loadItems throws', async () => {
    const loadItems = vi.fn(async () => {
      throw new Error('boom')
    })
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('boom')
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Retry')
  })

  it('shows empty state when folder has no children', async () => {
    wrapper = mountDialog({ initialPath: '/home/user/docs' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Empty folder')
  })

  it('calls loadItems again when Retry is clicked after an error', async () => {
    const loadItems = vi.fn(async () => {
      throw new Error('boom')
    })
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(loadItems.mock.calls.length).toBe(3)
    const retryBtns = findAllInDom<HTMLButtonElement>('[data-testid="file-picker-retry"]')
    expect(retryBtns.length).toBeGreaterThan(0)
    retryBtns[0]?.click()
    await flushPromises()
    expect(loadItems.mock.calls.length).toBeGreaterThan(3)
  })
})

describe('FilePickerDialog — agnostic data source (non-folder example)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  // Proves the component works with a totally different shape (git branches)
  interface Branch {
    ref: string
    is_head: boolean
  }

  it('works with any tree-shaped dataset (git branches example)', async () => {
    const branches: Record<string, Branch[]> = {
      '/': [
        { ref: 'main', is_head: false },
        { ref: 'feature/auth', is_head: false },
      ],
      '/main': [{ ref: 'hotfix', is_head: false }],
      '/feature/auth': [{ ref: 'wip', is_head: false }],
    }

    const loadItems = vi.fn(async (path: string) => branches[path] ?? [])

    wrapper = mount(FilePickerDialog<Branch>, {
      attachTo: document.body,
      props: {
        modelValue: false,
        loadItems,
        keyFor: (b: Branch) => b.ref,
        pathFor: (b: Branch) => `/${b.ref}`,
        isExpandable: (_b: Branch) => true, // all branches have children in this mock
        labelFor: (b: Branch) => b.ref,
        iconFor: () => '🌿',
        title: 'Pick a branch',
        initialPath: '/main',
      },
    })

    await wrapper.setProps({ modelValue: true })
    await flushPromises()

    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Pick a branch')
    expect(findInDom('[data-testid="file-picker-item-hotfix"]')).not.toBeNull()
  })
})