/**
 * Tests for the CreateWorktreeDialog component. The dialog is purely
 * presentational (no API calls) — it collects an absolute path, emits
 * `create(path)`, and lets the parent send the LLM-mediated
 * set_git_worktree message. Mirrors the testing style of
 * createPrDialog.spec.ts.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import CreateWorktreeDialog from '../components/CreateWorktreeDialog.vue'

function mountDialog() {
  return mount(CreateWorktreeDialog, {
    attachTo: document.body,  // Teleport-style positioning + body click for backdrop
  })
}

describe('CreateWorktreeDialog', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the dialog with a path input and Create/Cancel buttons', () => {
    wrapper = mountDialog()
    expect(wrapper.find('[data-testid="create-worktree-dialog"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-path"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-submit"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="create-worktree-cancel"]').exists()).toBe(true)
  })

  it('focuses the path input on mount', async () => {
    wrapper = mountDialog()
    // The component uses setTimeout(0) to focus, so wait one tick
    await new Promise((r) => setTimeout(r, 5))
    const input = wrapper.find('[data-testid="create-worktree-path"]').element as HTMLInputElement
    expect(document.activeElement).toBe(input)
  })

  it('clicking Create with an absolute path emits create(path) and close is NOT emitted (parent closes)', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-path"]').setValue('/home/me/proj/.worktrees/auth-fix')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    // The component emits `create` but does NOT emit `close` — the parent
    // decides when to close the dialog (so it can show an error first).
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/.worktrees/auth-fix'])
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('trims whitespace from the path before emitting', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-path"]').setValue('  /tmp/foo  ')
    await wrapper.find('[data-testid="create-worktree-submit"]').trigger('click')
    expect(wrapper.emitted('create')![0]).toEqual(['/tmp/foo'])
  })

  it('Create button is disabled when the path is empty', () => {
    wrapper = mountDialog()
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })

  it('Create button is disabled when the path is whitespace-only', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-path"]').setValue('   ')
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })

  it('Create button is enabled when the path has at least one non-whitespace char', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-path"]').setValue('/x')
    const submit = wrapper.find('[data-testid="create-worktree-submit"]')
    expect(submit.attributes('disabled')).toBeUndefined()
  })

  it('pressing Enter in the input emits create', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-path"]').setValue('/home/me/proj/.worktrees/feature-x')
    await wrapper.find('[data-testid="create-worktree-path"]').trigger('keyup.enter')
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/.worktrees/feature-x'])
  })

  it('clicking Cancel emits close', async () => {
    wrapper = mountDialog()
    await wrapper.find('[data-testid="create-worktree-cancel"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('pressing Escape emits close', async () => {
    wrapper = mountDialog()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await new Promise((r) => setTimeout(r, 0))  // wait for the event handler
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})
