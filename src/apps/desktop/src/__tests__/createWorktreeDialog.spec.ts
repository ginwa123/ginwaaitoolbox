/**
 * Tests for the CreateWorktreeDialog component. The dialog combines a
 * FolderExplorer (for picking the parent directory) + a basename input
 * + an "Up" navigation button. It composes the final absolute path
 * as `${parentDir}/${basename}` and emits `create(path)` on submit.
 *
 * The FolderExplorer is stubbed via `vi.mock` because it makes network
 * calls (listFolder API) that we don't exercise in the dialog tests —
 * those belong in FolderExplorer's own test suite. We just need to
 * verify the dialog wires up the explorer's folder-click event to
 * update parentDir.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import type { FolderEntry } from '../api'

// Stub the FolderExplorer — we only care that the dialog wires up
// its events. Real folder tree behavior is tested in
// folderExplorer.spec.ts (or wherever).
vi.mock('../components/FolderExplorer.vue', () => ({
  default: {
    name: 'FolderExplorer',
    props: ['cwd'],
    emits: ['folder-click', 'file-click'],
    template: `
      <div data-testid="folder-explorer-stub">
        <button
          v-for="folder in folders"
          :key="folder.path"
          :data-testid="'stub-folder-' + folder.name"
          @click="$emit('folder-click', folder)"
        >{{ folder.name }}</button>
      </div>
    `,
    setup() {
      return {
        folders: [
          { name: 'subdir', path: '/home/me/proj/subdir', is_directory: true } as FolderEntry,
          { name: 'another', path: '/home/me/proj/another', is_directory: true } as FolderEntry,
        ],
      }
    },
  },
}))

import CreateWorktreeDialog from '../components/CreateWorktreeDialog.vue'

function mountDialog(initialCwd?: string) {
  return mount(CreateWorktreeDialog, {
    props: initialCwd ? { initialCwd } : {},
    attachTo: document.body,  // Teleport-style positioning + body click for backdrop
  })
}

describe('CreateWorktreeDialog — initial state', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the dialog with parent input, explorer, name input and Create/Cancel buttons', () => {
    wrapper = mountDialog('/home/me/proj')
    expect(wrapper.find('[data-testid="create-worktree-dialog"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-parent"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-explorer"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-name"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-submit"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-cancel"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-up"]').exists()).toBe(true)
  })

  it('uses the initialCwd prop as the starting parent directory', () => {
    wrapper = mountDialog('/home/me/myapp')
    const parentInput = wrapper.find('[data-testid="create-worktree-parent"]').element as HTMLInputElement
    expect(parentInput.value).toBe('/home/me/myapp')
  })

  it('falls back to "/" when initialCwd is not provided', () => {
    wrapper = mountDialog()
    const parentInput = wrapper.find('[data-testid="create-worktree-parent"]').element as HTMLInputElement
    expect(parentInput.value).toBe('/')
  })

  it('Create button is disabled when basename is empty', () => {
    wrapper = mountDialog('/home/me/proj')
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })
})

describe('CreateWorktreeDialog — parent directory navigation', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('clicking a folder in the explorer navigates into it (updates parentDir)', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="stub-folder-subdir"]').trigger('click')
    const parentInput = wrapper.find('[data-testid="create-worktree-parent"]').element as HTMLInputElement
    expect(parentInput.value).toBe('/home/me/proj/subdir')
  })

  it('clicking Up moves to the parent directory', async () => {
    wrapper = mountDialog('/home/me/proj/subdir')
    await wrapper.find('[data-testid="create-worktree-up"]').trigger('click')
    const parentInput = wrapper.find('[data-testid="create-worktree-parent"]').element as HTMLInputElement
    expect(parentInput.value).toBe('/home/me/proj')
  })

  it('Up button is disabled when parentDir is root', () => {
    wrapper = mountDialog('/')
    const up = wrapper.find('[data-testid="create-worktree-up"]')
    expect(up.attributes('disabled')).toBeDefined()
  })

  it('typing in the path bar updates parentDir', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="create-worktree-parent"]').setValue('/tmp/experiments')
    const parentInput = wrapper.find('[data-testid="create-worktree-parent"]').element as HTMLInputElement
    expect(parentInput.value).toBe('/tmp/experiments')
  })
})

describe('CreateWorktreeDialog — submit', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('clicking Create with a basename emits create(parent + basename) and close is NOT emitted', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('auth-fix')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/auth-fix'])
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('composes parent + basename without a trailing slash on parent', async () => {
    wrapper = mountDialog('/home/me/proj/')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('bug-123')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/bug-123'])
  })

  it('handles root as parent without a double slash', async () => {
    wrapper = mountDialog('/')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('top-level')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    expect(wrapper.emitted('create')![0]).toEqual(['/top-level'])
  })

  it('trims whitespace from the basename before emitting', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('  bug-123  ')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/bug-123'])
  })

  it('Create button is enabled when basename has at least one non-whitespace char', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('x')
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeUndefined()
  })

  it('Create button is disabled when basename is whitespace-only', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('   ')
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })

  it('pressing Enter in the basename input emits create', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('feature-x')
    await wrapper.find('[data-testid="create-worktree-name"]').trigger('keyup.enter')
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/feature-x'])
  })

  it('reflects the composed path in the hint text after navigating', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="stub-folder-subdir"]').trigger('click')
    await wrapper.find('[data-testid="create-worktree-name"]').setValue('my-feature')
    // The hint <code> block should now show the composed full path
    expect(wrapper.text()).toContain('/home/me/proj/subdir/my-feature')
  })
})

describe('CreateWorktreeDialog — close', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('clicking Cancel emits close', async () => {
    wrapper = mountDialog('/home/me/proj')
    await wrapper.find('[data-testid="create-worktree-cancel"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('pressing Escape emits close', async () => {
    wrapper = mountDialog('/home/me/proj')
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await new Promise((r) => setTimeout(r, 0))  // wait for the event handler
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})
