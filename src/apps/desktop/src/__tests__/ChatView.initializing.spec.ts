/**
 * Tests for ChatView's initializing ready-gate.
 *
 * While the first history fetch is outstanding (`isInitializing`), the
 * transcript shows a skeleton (not the empty state) and the composer is
 * disabled (textarea + send). Once history resolves, the skeleton goes
 * away and the composer enables. Pending drafts (`pending-*`) skip the
 * history fetch by design, so they render ready immediately.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import FileInput from '../components/file/FileInput.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn(), back: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

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

function makeStubClient(): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting' as SseState,
    onStateChange: () => () => {},
  }
  return stub as SseClient
}

function installBaseMocks() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 's_init',
    session_name: '',
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

function emptyHistory() {
  return {
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  }
}

describe('ChatView initializing gate', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      Object.defineProperty(globalThis, 'localStorage', {
        value: makeLocalStorageStub(),
        writable: true,
        configurable: true,
      })
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    installBaseMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

  it('shows the skeleton + disabled composer while history is in flight, then resolves to ready', async () => {
    let resolveHistory!: (v: unknown) => void
    vi.spyOn(api, 'getChatHistory').mockReturnValue(
      new Promise((r) => {
        resolveHistory = r
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      }) as any,
    )

    wrapper = mount(ChatView, {
      props: { chatId: 's_init', chatName: 'Init Chat' },
      attachTo: document.body,
    })
    await flushPromises()
    await nextTick()

    // Initializing: skeleton visible, empty state hidden, composer disabled.
    expect(wrapper.find('[data-testid="chat-initializing-skeleton"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-load-error"]').exists()).toBe(false)
    const fileInput = wrapper.findComponent(FileInput)
    expect(fileInput.props('isInitializing')).toBe(true)
    expect(
      wrapper.find('[data-testid="chat-message-textarea"]').attributes('disabled'),
    ).toBeDefined()

    // History resolves (empty) → skeleton gone, empty state shown, composer enabled.
    resolveHistory(emptyHistory())
    for (let i = 0; i < 50; i++) {
      await new Promise((r) => setTimeout(r, 10))
      await nextTick()
      if (!wrapper.find('[data-testid="chat-initializing-skeleton"]').exists()) break
    }
    expect(wrapper.find('[data-testid="chat-initializing-skeleton"]').exists()).toBe(false)
    expect(wrapper.findComponent(FileInput).props('isInitializing')).toBe(false)
    expect(
      wrapper.find('[data-testid="chat-message-textarea"]').attributes('disabled'),
    ).toBeUndefined()
  })

  it('pending drafts render ready immediately (no skeleton)', async () => {
    const historySpy = vi.spyOn(api, 'getChatHistory').mockResolvedValue(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      emptyHistory() as any,
    )
    wrapper = mount(ChatView, {
      props: { chatId: 'pending-123', chatName: 'Draft' },
      attachTo: document.body,
    })
    await flushPromises()
    await nextTick()

    expect(historySpy).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="chat-initializing-skeleton"]').exists()).toBe(false)
    expect(wrapper.findComponent(FileInput).props('isInitializing')).toBe(false)
  })

  it('renders the load error with retry when history fails', async () => {
    vi.spyOn(api, 'getChatHistory').mockRejectedValue(new Error('offline'))
    wrapper = mount(ChatView, {
      props: { chatId: 's_init', chatName: 'Init Chat' },
      attachTo: document.body,
    })
    await flushPromises()
    await nextTick()

    const err = wrapper.find('[data-testid="chat-load-error"]')
    expect(err.exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-initializing-skeleton"]').exists()).toBe(false)
  })
})
