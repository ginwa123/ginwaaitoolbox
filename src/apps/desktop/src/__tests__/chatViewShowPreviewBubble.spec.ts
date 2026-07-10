/**
 * Tests for the click-to-open behavior on `show_preview` tool
 * message bubbles in ChatView (2026-07-01).
 *
 * Behavior under test:
 *
 *   1. ChatView renders `show_preview` tool messages as a
 *      `<button>` (not a generic expandable `<div>`) with
 *      `data-testid="show-preview-bubble-<msgId>"`.
 *   2. Clicking the button:
 *        - opens the side panel (was collapsed or dismissed → cleared)
 *        - sets the panel's `focusId` to the bubble's message id
 *          (so the panel jumps to that preview's tab)
 *      We verify by reading the component's exposed refs
 *      (`previewPanelDismissed`, `previewPanelCollapsed`, and the
 *      `:focus-id` prop passed to `<PreviewSidePanel>`).
 *   3. Switching chats clears the `focusId` so a stale value from
 *      a previous chat doesn't dictate the new chat's panel state.
 *
 * Why we don't render an expandable body for `show_preview`:
 * The whole point of the side panel is to keep the chat bubble
 * minimal (status + preview id + content_type + length) and let
 * the user inspect the rich content in the right-side panel. A
 * click-to-expand would make the user click twice. The user's
 * mental model: "the bubble is just a bookmark; the panel is the
 * content."
 *
 * Mounting ChatView is heavier than standalone components (sseBus,
 * Pinia, localStorage, gitStatus polling). All of that is stubbed
 * here so the tests focus on the bubble-rendering and click
 * flow. The PREVIOUS existing test in chatViewWorktree.spec.ts
 * already established this stub pattern; we mirror it.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'

import * as api from '../api'
import ChatView from '../components/ChatView.vue'
import PreviewSidePanel from '../components/PreviewSidePanel.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// jsdom 29 (vitest's jsdom in this project) lacks
// `Element.prototype.scrollTo`. Polyfill a no-op so VirtualScroller's
// containerRef.scrollTo(...) calls (fired on every render by
// scrollToBottom) don't throw unhandled rejections polluting the
// log.
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

// Stub SseClient — same as chatViewWorktree.spec.ts:82
function makeStubClient(initial: SseState): SseClient {
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

// Build a minimal `Message`-shaped object the ChatView can render.
// Only the fields the show_preview branch reads are populated.
function makeShowPreviewMessage(id: string) {
  return {
    id,
    role: 'tool',
    // is_output=true is REQUIRED for ChatView's `showPreviewMessages`
    // filter (ChatView.vue:607) to include the message in the
    // preview side panel's `:previews` prop. Without it, the panel
    // hides itself (preview-side-panel v-if="previews.length > 0")
    // and the assertion below on data-testid="preview-side-panel"
    // never sees the element. (Pre-existing bug — this test was
    // failing on main too before the ShowPreview refactor.)
    is_output: true,
    tool_name: 'show_preview',
    content: `<tool><name>show_preview</name><parameters><content_type>markdown</content_type><content># Title</content></parameters><success>true</success><data><show_preview><status>shown</status><preview_id>pv_${id}</preview_id><content_type>markdown</content_type><content_length>7</content_length></show_preview></data></tool>`,
    timestamp: new Date(),
    tool_call_id: `tc_${id}`,
  }
}

function installChatViewMocks() {
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp/test-repo',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  } as any)
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: true,
    branch: 'main',
    has_changes: false,
    is_clean: true,
    current: 'main',
    status: 'clean',
  } as any)
  vi.spyOn(api, 'getNalarConfig').mockResolvedValue({ profiles: {} } as any)
}

async function mountChatView(chatId = 'session_bubble_test') {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  // Wait for the async onMounted chain to settle (loadChatHistory →
  // connectSse → startGitStatusPoll → getQueuedMessages). The
  // isStreaming ref flips synchronously when connectSse registers
  // listeners — that's our "everything's wired" signal.
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await nextTick()
  return wrapper
}

describe('ChatView show_preview bubble click', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
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

  it('renders show_preview tool messages as a clickable card (delegated to <ShowPreview>, not the generic expandable fallback)', async () => {
    installChatViewMocks()
    wrapper = await mountChatView('session_bubble_render')

    // Inject a `show_preview` message into ChatView's `messages` ref.
    const vm = wrapper!.vm as unknown as { messages: unknown[] }
    vm.messages = [makeShowPreviewMessage('msg-sp-1')]
    await nextTick()
    await nextTick()

    // The card has the data-testid derived from the message id.
    const card = wrapper!.find('[data-testid="show-preview-card-msg-sp-1"]')
    expect(card.exists()).toBe(true)
    // It renders as a `<div role="button">` so keyboard users can
    // focus + activate it (Enter / Space). It's NOT the generic
    // expandable <div> fallback and NOT the old raw `<button>`.
    expect(card.attributes('role')).toBe('button')
    expect(card.attributes('tabindex')).toBe('0')

    // Since the injected message is a `show_preview` tool message, the
    // side panel also appears (driven by `showPreviewMessages` =
    // messages.filter(tool_name === 'show_preview')). Its own v-if
    // (`previews.length > 0`) makes it visible as soon as we have
    // one — and the watcher further auto-opens + un-dismisses when
    // a new preview lands.
    expect(wrapper!.find('[data-testid="preview-side-panel"]').exists()).toBe(true)
  })

  it('clicking the bubble passes the matching message id as focusId to PreviewSidePanel', async () => {
    installChatViewMocks()
    wrapper = await mountChatView('session_bubble_click')

    const vm = wrapper!.vm as unknown as {
      messages: unknown[]
      previewToShowId: string | null
      previewPanelDismissed: boolean
      previewPanelCollapsed: boolean
    }
    vm.messages = [makeShowPreviewMessage('msg-sp-2')]
    await nextTick()
    await nextTick()

    // Simulate the user having previously dismissed the panel.
    vm.previewPanelDismissed = true
    vm.previewPanelCollapsed = true
    await nextTick()

    const card = wrapper!.find('[data-testid="show-preview-card-msg-sp-2"]')
    expect(card.exists()).toBe(true)
    await card.trigger('click')
    await nextTick()

    // Panel state should be cleared by the click handler:
    expect(vm.previewPanelDismissed).toBe(false)
    expect(vm.previewPanelCollapsed).toBe(false)
    // And the focusId should equal the message id.
    expect(vm.previewToShowId).toBe('msg-sp-2')
  })

  it('switching chats clears previewToShowId so a stale id does not dictate the new chat', async () => {
    installChatViewMocks()
    wrapper = await mountChatView('session_chat_A')

    const vm = wrapper!.vm as unknown as {
      messages: unknown[]
      previewToShowId: string | null
    }
    vm.messages = [makeShowPreviewMessage('msg-sp-3')]
    await nextTick()

    const card = wrapper!.find('[data-testid="show-preview-card-msg-sp-3"]')
    await card.trigger('click')
    await nextTick()
    expect(vm.previewToShowId).toBe('msg-sp-3')

    // Switch to a different chat — the watcher on props.chatId should
    // reset previewToShowId to null.
    await wrapper!.setProps({ chatId: 'session_chat_B' })
    await nextTick()
    await nextTick()
    expect(vm.previewToShowId).toBeNull()
  })
})
