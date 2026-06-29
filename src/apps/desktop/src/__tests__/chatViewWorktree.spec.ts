/**
 * Tests for the worktree-aware status bar in ChatView.vue.
 *
 * The chat status bar (the small git-branch + worktree chip at the
 * bottom of the chat) becomes a clickable button when the session is
 * bound to a worktree. The button:
 *   - is rendered only when `gitStatus.is_git_repo` is true
 *   - is `:disabled` when `gitWorktreeCwd` is empty (no worktree bound)
 *   - shows `🌳 <basename>` when a worktree is bound
 *   - clicking it opens the WorktreeMenu dropdown
 *   - exposes the full worktree path via its `title` attribute
 *
 * The `gitWorktreeCwd` ref is populated by `loadChatHistory` from the
 * `git_worktree_cwd` field of the `/api/llm/session/:id/messages`
 * response (Chunk 4 backend wiring). The `gitStatus` ref is populated
 * by `startGitStatusPoll` from `api.getGitStatus(effectiveCwd)`.
 *
 * Guards the Chunk 7 wiring:
 *   - The status button has the expected `data-testid="worktree-status-button"`
 *   - The `:disabled` binding tracks `!gitWorktreeCwd` correctly
 *   - The `<template v-if="gitWorktreeCwd">` block renders the
 *     `🌳 <basename>` text
 *   - The `:title` binding shows the full worktree path
 *
 * Mounting ChatView is heavier than the standalone components: it
 * opens an SSE stream, polls git status, calls `getChatHistory`,
 * `getQueuedMessages`, `getNalarConfig`, and sets up a spacer
 * MutationObserver. All of those are stubbed via `vi.spyOn(api, ...)`.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'

import * as api from '../api'
import ChatView from '../components/ChatView.vue'

// jsdom 29 (the version used by this project's Vitest) does not
// implement `Element.prototype.scrollTo`. The VirtualScroller's
// `scrollToBottom` calls `containerRef.value.scrollTo({top, behavior})`
// on every render. With a 0×0 test container the call still reaches
// the method and would throw `TypeError: containerRef.value.scrollTo
// is not a function` as an unhandled rejection, polluting the test
// log. Polyfill a no-op `scrollTo` on the jsdom HTMLElement prototype
// so the existing code path runs cleanly. Other tests in the
// project that hit this path (e.g. NalarBrowserInlinePreview.spec.ts)
// continue to log the unhandled error — this is a pre-existing
// issue in the test infrastructure, not a ChatView-specific
// regression, and a global polyfill belongs in setup.ts (out of
// scope for Chunk 8).
if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: () => void } } }
  ).HTMLElement.prototype.scrollTo = function () {
    // no-op
  }
}

// ─── shared SSE stub ────────────────────────────────────────────────────────
// The chat SSE connection (now unified — llm + queue channels on one
// EventSource, see plan 2026-06-30-unify-sse-endpoints.md Chunk 7)
// returns an object that matches the SseClient interface (close /
// reconnect / getState / onStateChange). Tests don't fire events; they
// just need the close() call to be a no-op so onUnmounted doesn't
// throw.
function makeSseStub(): api.SseClient {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: vi.fn(() => 'open' as const),
    onStateChange: vi.fn(() => () => {}),
  } as unknown as api.SseClient
}

// ─── default mocks ──────────────────────────────────────────────────────────
// `installChatViewMocks` wires up the api.* dependencies the
// component touches in onMounted. The `getChatHistory` callback lets
// each test customize the `git_worktree_cwd` field (and the cwd) the
// mocked response returns.
function installChatViewMocks(opts: {
  gitWorktreeCwd?: string
  cwd?: string
} = {}) {
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: opts.cwd ?? '/tmp/main-repo',
    git_worktree_cwd: opts.gitWorktreeCwd ?? '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  } as any)
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  // A `watch(() => sessionId.value, ...)` in ChatView fires
  // `api.getSession(newId)` once onMounted sets the sessionId. The
  // mock must return a session-shaped object so the watch's
  // `session?.selectedProfile` lookup is safe.
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
  } as any)
  // The status poll checks `is_git_repo` to decide whether to render
  // the status button. We always return a clean repo so the button
  // shows.
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: true,
    branch: 'main',
    has_changes: false,
    is_clean: true,
    current: 'main',
    status: 'clean',
  } as any)
  // loadProfiles() is called outside onMounted; the response shape
  // matches the real `/api/config/nalar` payload.
  vi.spyOn(api, 'getNalarConfig').mockResolvedValue({
    profiles: {},
  } as any)
  // The unified factory opens ONE EventSource carrying both the llm
  // and queue channels. The stub satisfies the SseClient interface
  // (close / reconnect / getState / onStateChange) so onUnmounted's
  // chatSse.value.close() call is a no-op. Tests don't fire events
  // through the channel callbacks (this spec only exercises the
  // worktree status button — see kanbanSse.spec.ts and
  // workspacesStoreSessionEvents.spec.ts for the event-dispatch
  // pattern using capturedOpts).
  vi.spyOn(api, 'createUnifiedSseConnection').mockReturnValue(makeSseStub())
}

// ─── mount helper ───────────────────────────────────────────────────────────
async function mountChatView(chatId = 'session_test') {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  // onMounted is async: loadChatHistory → connectSse → startGitStatusPoll
  // → getQueuedMessages. Wait several ticks for all the awaits to
  // resolve and the template to re-render with the loaded values.
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  return wrapper
}

describe('ChatView worktree status button', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    // jsdom 29 in this project's Vitest does not provide localStorage.
    // navigation.ts reads localStorage at store init (loadSidebarCollapsed
    // etc.), so we stub a minimal in-memory implementation that
    // satisfies the `localStorage.getItem/.setItem/.removeItem` calls.
    // See nav.spec.ts for the same pattern.
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => { store[k] = String(v) },
        removeItem: (k: string) => { delete store[k] },
        clear: () => { for (const k in store) delete store[k] },
        key: () => null,
        length: 0,
      } as Storage)
    } else {
      localStorage.clear()
    }

    // ChatView setup() now reads useNavigationStore() to wire the
    // sub-agent peek panel (@peek event + lazy peek composable).
    // Pinia must be active for any useXxxStore() call.
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('when git_worktree_cwd is empty, the status button is still clickable and opens a context-appropriate dropdown', async () => {
    installChatViewMocks({ gitWorktreeCwd: '' })

    wrapper = await mountChatView('session_no_wt')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)
    // The button is ALWAYS clickable now (no `:disabled` binding).
    // Clicking opens a dropdown with the no-worktree menu items
    // ("Open in folder", "Refresh status") — NOT the worktree-bound
    // items ("Create a PR", "Clear worktree").
    const htmlBtn = btn.element as HTMLButtonElement
    expect(htmlBtn.disabled).toBe(false)
    // The 🌳-basename template block should be absent (it's gated on
    // v-if="gitWorktreeCwd").
    expect(wrapper!.text()).not.toContain('🌳')

    // Open the dropdown.
    await btn.trigger('click')
    await nextTick()
    await nextTick()

    // No-worktree menu items — "Refresh status" is the unambiguous
    // tell. "Open in folder" shares its data-testid with the
    // worktree-bound "View in folder" item.
    expect(wrapper!.find('[data-testid="worktree-menu-refresh"]').exists()).toBe(true)
    // Worktree-bound items should NOT be present.
    expect(wrapper!.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(false)
    expect(wrapper!.find('[data-testid="worktree-menu-clear"]').exists()).toBe(false)
  })

  it('when git_worktree_cwd is set, the status button shows branch + caret; worktree basename is in the menu', async () => {
    installChatViewMocks({
      gitWorktreeCwd: '/abs/.worktrees/auth-fix',
    })

    wrapper = await mountChatView('session_with_wt')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)
    expect((btn.element as HTMLButtonElement).disabled).toBe(false)
    // The chip keeps the branch name visible. The worktree basename is
    // intentionally NOT shown in the chip anymore (it was noisy when
    // branch and basename were nearly identical strings); the menu
    // header carries the worktree info instead.
    expect(btn.text()).toContain('main')
    expect(btn.text()).not.toContain('🌳')
    expect(btn.text()).not.toContain('auth-fix')
    // The dropdown caret is always rendered now (chip is always clickable).
    expect(btn.text()).toContain('▾')

    // The worktree basename surfaces inside the dropdown menu header
    // (added in the no-worktree-aware menu refactor).
    await btn.trigger('click')
    await nextTick()
    await nextTick()
    expect(wrapper!.text()).toContain('main')
    // The full worktree path is still discoverable via the title tooltip.
    expect(btn.attributes('title') ?? '').toContain('/abs/.worktrees/auth-fix')
  })

  it('when git_worktree_cwd is set, clicking the status button opens the dropdown', async () => {
    installChatViewMocks({
      gitWorktreeCwd: '/abs/.worktrees/auth-fix',
    })

    wrapper = await mountChatView('session_with_wt_dropdown')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)

    // The WorktreeMenu uses the three testids we created in
    // worktreeMenu.spec.ts. Before the click, none of them exist
    // (the menu is v-if-bound to showWorktreeMenu=false).
    expect(wrapper!.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(false)

    await btn.trigger('click')
    await nextTick()
    await nextTick()

    // The WorktreeMenu has mounted. All 3 of its items are present.
    expect(wrapper!.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(true)
    expect(wrapper!.find('[data-testid="worktree-menu-view-folder"]').exists()).toBe(true)
    expect(wrapper!.find('[data-testid="worktree-menu-clear"]').exists()).toBe(true)
  })

  it('the status button title attribute shows the full worktree path', async () => {
    installChatViewMocks({
      gitWorktreeCwd: '/abs/.worktrees/auth-fix',
    })

    wrapper = await mountChatView('session_with_wt_title')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)
    // The production template binds:
    //   :title="gitWorktreeCwd ? `Worktree: ${gitWorktreeCwd}\n...` : `...`"
    // The full path must appear in the title (the basename is too
    // short to be a unique identifier when the user has multiple
    // worktrees named the same).
    const title = btn.attributes('title') ?? ''
    expect(title).toContain('/abs/.worktrees/auth-fix')
  })
})
