/**
 * Regression tests for the git icon rendered in the ChatsList
 * sidebar. Rows show icon-only badges (no model badge, no text
 * labels) in front of the chat name:
 *   - `chat-git-branch`: kanban fork/branch SVG with PR-status colors
 *     when the session has a `git_branch` value (tooltip carries the
 *     branch + worktree path).
 *   - `worktree-badge`: same SVG icon (dim fallback) when only
 *     `git_worktree_cwd` is set (bound worktree, non-git cwd).
 * Both are absent when the values are empty.
 *
 * This guards the Chunk 4 wiring:
 *   - `Session` interface declares `git_worktree_cwd` (api/index.ts)
 *   - `SessionEvent` interface declares `git_worktree_cwd`
 *     (SSE updates carry it through)
 *   - `ChatsList.vue` `loadChats` maps `session.git_worktree_cwd`
 *     into the local `navItems[i].git_worktree_cwd`
 *   - The template renders the icon gated on
 *     `v-if="item.git_branch"` / `v-else-if="item.git_worktree_cwd"`
 *
 * The component is mounted with `vi.spyOn(api, 'getChats')` (the
 * same pattern as `sidebarActiveState.spec.ts`).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'

import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { mount } from '@vue/test-utils'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

// ChatsList calls useRouter() in setup; the `mocks: { $router: ... }`
// option below only patches `this.$router` (Options API), so we
// stub the composable at module level — same as
// sidebarActiveState.spec.ts.
const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/', fullPath: '/' })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

function mountChatsList() {
  return mount(ChatsList, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      // Real Vue ref — ChatsList has `watch(processingState, ..., { deep: true })`.
      // A plain `{ value: {} }` object would log `[Vue warn]: Invalid watch source`
      // and turn the watchers into silent no-ops.
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

describe('ChatsList git icon', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // ChatsList setup calls workspacesStore.onSessionEvent(cb)
    // synchronously, which now requires the sseBus to be installed
    // (Chunk 6 of unify-frontend-sse). Install a stub bus before
    // mounting the component.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('renders the worktree icon when a session has a non-empty git_worktree_cwd', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_abc',
          session_name: 'My Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          git_worktree_cwd: '/abs/.worktrees/worktree/session_abc',
        },
      ],
      has_more: false,
      next_cursor: null,

      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // ChatsList no longer opens a session-events SSE stream of its
    // own — that subscription moved to workspacesStore (Chunk 5).
    // The component still mounts cleanly without a local SSE stub.

    const wrapper = mountChatsList()
    // Wait for the async loadChats() in onMounted to resolve and the
    // navItems to populate, then let Vue's render queue flush.
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    const badge = wrapper.find('[data-testid="worktree-badge"]')
    expect(badge.exists()).toBe(true)
    // Icon-only fallback: same kanban fork/branch SVG, no text label.
    expect(badge.html()).toContain('M6 3v12')
    expect(badge.text()).not.toContain('🌳')
    expect(badge.text()).not.toContain('worktree')
    // The badge exposes the worktree path via the title attribute
    // (hovering shows it as a native tooltip). The browser's
    // attribute name is lowercase `title`, which jsdom preserves
    // verbatim.
    expect(badge.attributes('title')).toBe('/abs/.worktrees/worktree/session_abc')
  })

  it('does NOT render the worktree icon when git_worktree_cwd is empty', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_plain',
          session_name: 'Plain Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          git_worktree_cwd: '',
        },
      ],
      has_more: false,

      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
  })

  it('does NOT render the worktree icon when git_worktree_cwd is missing from the session', async () => {
    // Belt-and-suspenders: some old sessions predate the
    // set_git_worktree tool, so the field is absent (undefined) on
    // the wire. The ChatsList loadChats mapper uses
    // `session.git_worktree_cwd || ''` which collapses both empty
    // and missing into the falsy default, hiding the badge.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_legacy',
          session_name: 'Legacy Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          // no git_worktree_cwd key at all
        },
      ],

      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
  })

  it('does NOT render a model badge even when selected_profile_model is set', async () => {
    // Chat rows show only the git icon + name + time. The model badge
    // was removed (icon-only rows) — a session with a profile model
    // must render no model text, while the worktree icon still shows
    // for the bound path.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_both',
          session_name: 'Both',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: 'gpt-4o',
          git_worktree_cwd: '/worktrees/feature-x',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(true)
    expect(wrapper.text()).not.toContain('🤖')
    expect(wrapper.text()).not.toContain('gpt-4o')
  })

  it('renders the icon-only branch badge when git_branch is present', async () => {
    // Sidebar parity with WorkspaceItemTaskCard's SVG icon, but
    // icon-only: no branch-name text, no legacy chip. The branch +
    // worktree path stay discoverable via the tooltip.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_branch',
          session_name: 'Branched Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          cwd: '/repo',
          git_worktree_cwd: '/repo/.worktrees/feature-x',
          git_branch: 'worktree/feature-x',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    const badge = wrapper.find('[data-testid="chat-git-branch"]')
    expect(badge.exists()).toBe(true)
    // Icon-only: the SVG icon with no branch-name text.
    expect(badge.html()).toContain('M6 3v12')
    expect(badge.text()).not.toContain('worktree/feature-x')
    // The row still shows the chat name.
    expect(wrapper.text()).toContain('Branched Chat')
    // Legacy chip yields to the branch badge.
    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
    // Tooltip surfaces the branch + full worktree path.
    expect(badge.attributes('title')).toContain('worktree/feature-x')
    expect(badge.attributes('title')).toContain('/repo/.worktrees/feature-x')
  })

  it('renders no git badge when both git_branch and git_worktree_cwd are empty', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_plain2',
          session_name: 'Plain Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          cwd: '',
          git_worktree_cwd: '',
          git_branch: '',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    expect(wrapper.find('[data-testid="chat-git-branch"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
  })
})
