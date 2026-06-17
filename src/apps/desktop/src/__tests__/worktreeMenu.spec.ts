/**
 * Regression tests for the WorktreeMenu dropdown component.
 *
 * The menu has three actions — "Create a PR", "View in folder", "Clear
 * worktree" — and a click-outside listener that closes the menu. Each
 * action emits its own event AND a `close` event so the parent can
 * tear down the `v-if`-bound dropdown. The "Clear worktree" action
 * additionally gates on `window.confirm(...)` so a misclick doesn't
 * nuke the worktree.
 *
 * The component is purely presentational (no API calls), so no mocks
 * are needed. Mounting via `@vue/test-utils` and asserting on
 * `.emitted('...')` is sufficient.
 *
 * Guards the Chunk 5 wiring:
 *   - All 3 menu items render with the correct `data-testid`s
 *   - Each item emits the right event pair (action + `close`)
 *   - The confirm dialog gates the "Clear" action
 *   - Clicking outside the menu (anywhere not inside `menuRef`)
 *     emits `close` so the parent can collapse the dropdown
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import WorktreeMenu from '../components/WorktreeMenu.vue'

describe('WorktreeMenu', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the three menu items with the correct data-testids', () => {
    wrapper = mount(WorktreeMenu)
    // The component uses the `data-testid` attribute as the contract
    // for ChatView's click handlers — if any of these IDs change,
    // the parent wiring silently breaks.
    expect(wrapper.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-view-folder"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="worktree-menu-clear"]').exists()).toBe(true)
  })

  it('clicking "Create a PR" emits create-pr and close', async () => {
    wrapper = mount(WorktreeMenu)
    await wrapper.find('[data-testid="worktree-menu-create-pr"]').trigger('click')
    expect(wrapper.emitted('create-pr')).toBeTruthy()
    expect(wrapper.emitted('create-pr')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })

  it('clicking "View in folder" emits view-folder and close', async () => {
    wrapper = mount(WorktreeMenu)
    await wrapper.find('[data-testid="worktree-menu-view-folder"]').trigger('click')
    expect(wrapper.emitted('view-folder')).toBeTruthy()
    expect(wrapper.emitted('view-folder')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })

  it('clicking "Clear worktree" shows a confirm dialog; on accept, emits clear and close', async () => {
    wrapper = mount(WorktreeMenu)
    // The component uses `window.confirm(...)` (a bare global). Stub it
    // so the test does not block on a modal dialog.
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true)

    await wrapper.find('[data-testid="worktree-menu-clear"]').trigger('click')

    expect(confirmSpy).toHaveBeenCalledTimes(1)
    // The confirm message should warn the user about the destructive
    // nature of the action — this guards against an accidental
    // refactor that drops the warning text.
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
    wrapper = mount(WorktreeMenu)
    vi.spyOn(window, 'confirm').mockReturnValue(false)

    await wrapper.find('[data-testid="worktree-menu-clear"]').trigger('click')

    expect(wrapper.emitted('clear')).toBeFalsy()
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('clicking outside the menu emits close', async () => {
    wrapper = mount(WorktreeMenu)
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
