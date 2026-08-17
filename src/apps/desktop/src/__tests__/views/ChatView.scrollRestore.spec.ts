/**
 * Tests for ChatView's scroll-position restore behavior on mount.
 *
 * Why these tests exist:
 *   When a user opens a task, scrolls up to read older messages,
 *   closes the chatview (✕), and reopens the same task, the chat
 *   should land back at the same scroll position they left — not
 *   auto-stick to the bottom every time. Without
 *   useChatScrollRestore + the `isInitialLoad` guard in ChatView,
 *   the new instance's VirtualScroller container starts at
 *   scrollTop = 0 / bottom and the user loses their reading
 *   position.
 *
 * These tests verify the END-TO-END integration: a pre-seeded
 * localStorage value causes the ChatView to scroll to that position
 * on mount (instead of the bottom). The composable itself is
 * tested separately in useChatScrollRestore.spec.ts; this file
 * focuses on the wiring inside ChatView.vue.
 *
 * Coverage:
 *   - restores the saved scroll position when the saved value is
 *     in the middle (the common case: user scrolled up to read)
 *   - falls through to scrollToBottom when the saved value is
 *     "near bottom" (within BOTTOM_THRESHOLD_PX = 40px of max)
 *   - falls through to scrollToBottom when no saved value exists
 *   - falls through to scrollToBottom when the saved value is 0
 *   - persists the scroll position when the user scrolls up
 *   - uses a per-task key (different chat IDs have different scroll
 *     positions)
 *   - flushes the pending save on unmount
 *
 * jsdom setup notes:
 *   - HTMLElement.prototype.scrollTo is NOT implemented in jsdom.
 *     The chatViewWorktree.spec.ts polyfill is a no-op — but for
 *     THESE tests we need scrollTo to actually update scrollTop,
 *     so this spec installs its own polyfill that mirrors the
 *     browser behavior.
 *   - scrollHeight / clientHeight are not laid out in jsdom. The
 *     tests override them via Object.defineProperty to simulate
 *     a known geometry after the VirtualScroller has mounted.
 *   - The VirtualScroller measures items via ResizeObserver +
 *     a 100ms setTimeout(measureItems). The `waitForInitialLoad`
 *     helper waits 250ms to be safe.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

// jsdom 29 does NOT implement HTMLElement.prototype.scrollTo. The
// VirtualScroller's scrollToBottom / scrollToPosition call this
// method on the container. We polyfill a real implementation that
// mirrors the browser behavior (sets scrollTop from the options
// argument) so we can observe the scroll position changes in the
// test assertions.
if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: (arg: unknown) => void } } }
  ).HTMLElement.prototype.scrollTo = function (arg: unknown) {
    if (typeof arg === 'number') {
      ;(this as HTMLElement).scrollTop = arg
      return
    }
    if (arg && typeof arg === 'object' && 'top' in arg) {
      const top = (arg as { top?: number }).top
      if (typeof top === 'number') {
        ;(this as HTMLElement).scrollTop = top
      }
    }
  }
}

// jsdom does NOT lay out elements. scrollHeight and clientHeight
// default to 0 on every element. ChatView's loadChatHistory fires
// scrollToPosition BEFORE the test gets a chance to override the
// geometry on the container instance, so the scroll sees max=0 and
// no-ops. Override the getter on the prototype so every element
// reports known values from mount onwards. Tests that need a
// different geometry override this with their own defineProperty.
Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    return 20000
  },
})
Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return 800
  },
})

function makeStubClient(initial: SseState): SseClient {
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

function installApiMocks(): void {
  // getChatHistory returns 100 user-role messages so the chat is
  // scrollable. The VirtualScroller's @total-count + 200px default
  // item height gives a scrollHeight of 20,000px against an 800px
  // container (clientHeight) — enough room to test "scrollTop in
  // the middle" without hitting the "near bottom" branch.
  const messages = Array.from({ length: 100 }, (_, i) => ({
    id: `msg_${i}`,
    role: 'user' as const,
    content: `Message ${i}`,
    created_at: i,
    image_url: '',
    finish_reason: '',
  }))
   
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    messages: messages as any,
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
     
    max_total_tokens: 0,
     
    max_capacity_total_tokens: 0,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
     
    session_name: '',
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
     
    branch: '',
    has_changes: false,
    is_clean: true,
     
    current: '',
    status: 'clean',
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getNalarConfig').mockResolvedValue({
    profiles: {},
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  // The onMounted chain is async: loadChatHistory → connectSse →
  // startGitStatusPoll → getQueuedMessages → loadProfiles (sync).
  // Wait for the VirtualScroller's `isStreaming` ref (set after
  // SSE connect) + several ticks. Tests that depend on the
  // initial-load scroll branch fire next.
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  return wrapper
}

/**
 * Configure the VirtualScroller container's scrollHeight and
 * clientHeight to simulate a known geometry. Without this, jsdom
 * reports 0 for both and the "max <= 0" branch skips any scroll
 * restoration. The VirtualScroller's own measurement loop uses
 * defaultItemHeight (200px) × items.length = the natural
 * scrollHeight, so we override it after mount to a known value.
 *
 * `scrollHeight` should be > `clientHeight` for restore() to
 * return a non-null value.
 */
function findScrollerContainer(wrapper: VueWrapper): HTMLElement | null {
  // The VirtualScroller renders a `<div class="virtual-scroller">`
  // container. Find it via the wrapper's HTML. If it's missing,
  // the test is racing the initial mount — return null and let the
  // caller wait.
  const el = wrapper.find('.virtual-scroller')
  return el.exists() ? (el.element as HTMLElement) : null
}

async function waitForInitialLoad(wrapper: VueWrapper): Promise<void> {
  // The initial-load branch awaits rAF × 2 (one inside
  // loadChatHistory, one for VirtualScroller's measureItems). Plus
  // the VirtualScroller's 100ms measureItems delay. A 500ms total
  // wait covers all cases with margin.
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 25))
    const container = findScrollerContainer(wrapper)
    if (container && container.scrollHeight > container.clientHeight) return
  }
}

describe('ChatView — scroll position persistence', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => {
          store[k] = String(v)
        },
        removeItem: (k: string) => {
          delete store[k]
        },
        clear: () => {
          for (const k in store) delete store[k]
        },
        key: () => null,
        length: 0,
      } as Storage)
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

  it('restores the saved scroll position on mount (the common case)', async () => {
    // Pre-seed: user closed while at scrollTop = 840 (in the middle
    // of a scrollable chat). The prototype-level scrollHeight=20000,
    // clientHeight=800 (max=19200) means 840 is in the middle —
    // well clear of the "near bottom" boundary (BOTTOM_THRESHOLD_PX=40).
    localStorage.setItem('chat-scroll-task_test', '840')
    installApiMocks()

    wrapper = await mountChatView('task_test')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()
    expect(container!.scrollTop).toBe(840)
    expect(container!.scrollTop).not.toBe(container!.scrollHeight - container!.clientHeight)
  })

  it('falls through to scrollToBottom when the saved position is "near bottom"', async () => {
    // scrollHeight - clientHeight = 19200 (the max). saved = 19200
    // → distance from bottom = 0 → "still at bottom" → restore
    // returns null → ChatView calls scrollToBottom.
    localStorage.setItem('chat-scroll-task_nearbottom', '19200')
    installApiMocks()

    wrapper = await mountChatView('task_nearbottom')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()
    const max = container!.scrollHeight - container!.clientHeight
    expect(container!.scrollTop).toBe(max)
  })

  it('falls through to scrollToBottom when no saved value exists', async () => {
    installApiMocks()

    wrapper = await mountChatView('task_fresh')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()
    const max = container!.scrollHeight - container!.clientHeight
    expect(container!.scrollTop).toBe(max)
  })

  it('falls through to scrollToBottom when the saved value is 0', async () => {
    localStorage.setItem('chat-scroll-task_zero', '0')
    installApiMocks()

    wrapper = await mountChatView('task_zero')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()
    const max = container!.scrollHeight - container!.clientHeight
    expect(container!.scrollTop).toBe(max)
  })

  it('persists the scroll position when the user scrolls up before closing', async () => {
    installApiMocks()

    wrapper = await mountChatView('task_save')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()

    // Simulate the user scrolling up to the middle.
    container!.scrollTop = 450
    container!.dispatchEvent(new Event('scrollend'))

    // The composable should have persisted 450 synchronously.
    expect(localStorage.getItem('chat-scroll-task_save')).toBe('450')

    wrapper?.unmount()
    wrapper = null
  })

  it('uses a per-task key (different tasks have different scroll positions)', async () => {
    localStorage.setItem('chat-scroll-task_A', '100')
    localStorage.setItem('chat-scroll-task_B', '1500')
    installApiMocks()

    // Mount task A — should restore to 100.
    wrapper = await mountChatView('task_A')
    await waitForInitialLoad(wrapper)
    const containerA = findScrollerContainer(wrapper)
    expect(containerA).not.toBeNull()
    expect(containerA!.scrollTop).toBe(100)
    wrapper.unmount()
    wrapper = null

    // Mount task B — should restore to 1500.
    wrapper = await mountChatView('task_B')
    await waitForInitialLoad(wrapper)
    const containerB = findScrollerContainer(wrapper)
    expect(containerB).not.toBeNull()
    expect(containerB!.scrollTop).toBe(1500)
  })

  it('flushes the pending scroll save on unmount', async () => {
    installApiMocks()

    wrapper = await mountChatView('task_flush')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()

    // Simulate a debounced scroll save (debounce timer not advanced).
    container!.scrollTop = 350
    container!.dispatchEvent(new Event('scroll'))

    // Unmount before the debounce fires. The composable's
    // onBeforeUnmount flushes pending writes synchronously.
    wrapper.unmount()
    wrapper = null

    expect(localStorage.getItem('chat-scroll-task_flush')).toBe('350')
  })
})