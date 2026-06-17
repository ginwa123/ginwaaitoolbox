/**
 * Regression tests for the WorktreeMenu dropdown component.
 *
 * The menu shows different actions based on the `hasWorktree` prop:
 *
 * - `hasWorktree=true`  → "Create a PR", "View in folder", "Clear worktree"
 * - `hasWorktree=false` → "Open in folder", "Refresh status"
 *
 * Each action emits its own event AND a `close` event so the parent can
 * tear down the `v-if`-bound dropdown. The "Clear worktree" action
 * additionally gates on `window.confirm(...)` so a misclick doesn't nuke
 * the worktree.
 *
 * The component is purely presentational (no API calls), so no mocks are
 * needed. Mounting via `@vue/test-utils` and asserting on `.emitted('...')`
 * is sufficient.
 *
 * Guards:
 *   - All worktree-bound menu items render with the correct `data-testid`s
 *   - All no-worktree menu items render with the correct `data-testid`s
 *   - Each item emits the right event pair (action + `close`)
 *   - The confirm dialog gates the "Clear" action
 *   - Clicking outside the menu (anywhere not inside `menuRef`)
 *     emits `close` so the parent can collapse the dropdown
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import WorktreeMenu from '../components/WorktreeMenu.vue'

// Helper: mount the menu with the right props for each test. Centralizing
// the prop shape keeps the tests focused on the behavior under test, not
// on Vue's prop-validation ceremony.
function mountMenu(hasWorktree: boolean) {
  return mount(WorktreeMenu, {
    props: { hasWorktree, branch: 'main', status: 'clean' },
  })
}

describe('WorktreeMenu — worktree-bound (hasWorktree=true)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the three worktree-bound menu items with the correct data-testids', () => {
    wrapper = mountMenu(true)
    // The component uses the `data-testid` attribute as the contract for
    // ChatView's click handlers — if any of these IDs change, the
    // parent wiring silently breaks.
    expect(wrapper.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-view-folder"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-clear"]').exists()).toBe(true)
    // The no-worktree-only items must NOT be present.
    expect(wrapper.find('[data-testid="worktree-menu-refresh"]').exists()).toBe(false)
  })

  it('clicking "Create a PR" emits create-pr and close', async () => {
    wrapper = mountMenu(true)
    await wrapper.find('[data-testid="worktree-menu-create-pr"]').trigger('click')
    expect(wrapper.emitted('create-pr')).toBeTruthy()
    expect(wrapper.emitted('create-pr')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })

  it('clicking "View in folder" emits view-folder and close', async () => {
    wrapper = mountMenu(true)
    await wrapper.find('[data-testid="worktree-menu-view-folder"]').trigger('click')
    expect(wrapper.emitted('view-folder')).toBeTruthy()
    expect(wrapper.emitted('view-folder')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })

  it('clicking "Clear worktree" shows a confirm dialog; on accept, emits clear and close', async () => {
    wrapper = mountMenu(true)
    // The component uses `window.confirm(...)` (a bare global). Stub it
    // so the test does not block on a modal dialog.
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true)

    await wrapper.find('[data-testid="worktree-menu-clear"]').trigger('click')

    expect(confirmSpy).toHaveBeenCalledTimes(1)
    // The confirm message should warn the user about the destructive
    // nature of the action — this guards against an accidental refactor
    // that drops the warning text.
    expect(confirmSpy.mock.calls[0]![0]).toMatch(/clear.*worktree|remove/i)
    expect(wrapper.emitted('clear')).toBeTruthy()
    expect(wrapper.emitted('clear')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })

  it('clicking "Clear worktree" with confirm=false does NOT emit clear', async () => {
    // Belt-and-suspenders: if the user clicks Cancel in the confirm
    // dialog, neither `clear` nor `close` should fire (the menu stays
    // open so they can pick a different action). The plan only listed
    // the accept=true case; this is the rejection counterpart.
    wrapper = mountMenu(true)
    vi.spyOn(window, 'confirm').mockReturnValue(false)

    await wrapper.find('[data-testid="worktree-menu-clear"]').trigger('click')

    expect(wrapper.emitted('clear')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('clicking outside the menu emits close', async () => {
    wrapper = mountMenu(true)
    // The component registers a document-level `click` listener in
    // onMounted (with a 0ms setTimeout so the click that OPENED the
    // menu doesn't immediately close it). After that tick, dispatching
    // a click on a target OUTSIDE the menu must emit `close`.
    await new Promise((r) => setTimeout(r, 5))

    // Build a target node that is NOT inside `menuRef`. The menu's
    // root <div> contains the 3 buttons, so clicking on the body
    // element works as an "outside" target.
    const outsideEl = document.body
    document.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))

    // The component checks `menuRef.value.contains(e.target as Node)`.
    // `document.body` is the dispatch target of the document-level
    // listener; if the listener is registered correctly, this fires.
    expect(wrapper.emitted('close')).toBeTruthy()
    // Reference `outsideEl` so TS/lint don't complain about an unused
    // variable (the dispatch goes through document, not the element,
    // because of how bubbling lands on the document).
    void outsideEl
  })
})

describe('WorktreeMenu — no-worktree (hasWorktree=false)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the two no-worktree menu items with the correct data-testids', () => {
    wrapper = mountMenu(false)
    expect(wrapper.find('[data-testid="worktree-menu-view-folder"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-refresh"]').exists()).toBe(true)
    // The worktree-bound-only items must NOT be present.
    expect(wrapper.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="worktree-menu-clear"]').exists()).toBe(false)
  })

  it('clicking "Open in folder" emits view-folder and close', async () => {
    wrapper = mountMenu(false)
    await wrapper.find('[data-testid="worktree-menu-view-folder"]').trigger('click')
    // The same emit is used for both cases — the parent decides whether
    // to copy the worktree path or the session cwd based on its own
    // gitWorktreeCwd ref. Keeping a single event name avoids forcing
    // ChatView to swap handlers per menu mount.
    expect(wrapper.emitted('view-folder')).toBeTruthy()
    expect(wrapper.emitted('view-folder')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })

  it('clicking "Refresh status" emits refresh and close', async () => {
    wrapper = mountMenu(false)
    await wrapper.find('[data-testid="worktree-menu-refresh"]').trigger('click')
    expect(wrapper.emitted('refresh')).toBeTruthy()
    expect(wrapper.emitted('refresh')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })
})

describe('WorktreeMenu — header', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('shows the branch name in the header', () => {
    wrapper = mountMenu(true)
    expect(wrapper.text()).toContain('main')
  })

  it('falls back to "detached" when branch is empty', () => {
    wrapper = mount(WorktreeMenu, {
      props: { hasWorktree: false, branch: '', status: 'clean' },
    })
    expect(wrapper.text()).toContain('detached')
  })
})
