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
import ChatView from '../components/views/ChatView.vue'
import PreviewSidePanel from '../components/preview/PreviewSidePanel.vue'
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
    is_git_repo: true,
    branch: 'main',
    has_changes: false,
    is_clean: true,
    current: 'main',
    status: 'clean',
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
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

    // Default to 'side' mode for these tests — the existing tests in
    // this file predate the 2026-08-06 default flip to 'inline' and
    // were written assuming the side panel is the default. The NEW
    // 'inline mode' describe block sets 'inline' explicitly.
    localStorage.setItem('nalar-preview-display-mode', 'side')

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

  // Regression test for the "auto-open is opt-in" change (2026-07-12):
  // The preview side panel used to auto-open whenever a NEW
  // `show_preview` tool message arrived in the chat. This was
  // disruptive — the panel slid open mid-message and crowded the
  // chat. The new behavior keeps the panel COLLAPSED by default;
  // it only opens when the user explicitly clicks a `show_preview`
  // bubble (via `openPreviewForMessage`). This test verifies that
  // injecting N previews back-to-back leaves the panel in the
  // collapsed state throughout.
  it('does NOT auto-open the preview side panel when new show_preview messages arrive', async () => {
    installChatViewMocks()
    wrapper = await mountChatView('session_bubble_noauto')

    const vm = wrapper!.vm as unknown as {
      messages: unknown[]
      previewPanelCollapsed: boolean
      previewPanelDismissed: boolean
    }

    // Initial state: panel defaults to COLLAPSED (was the bug — used
    // to default to expanded).
    expect(vm.previewPanelCollapsed).toBe(true)
    expect(vm.previewPanelDismissed).toBe(false)

    // Inject the first show_preview message — panel still collapsed.
    vm.messages = [makeShowPreviewMessage('msg-noauto-1')]
    await nextTick()
    await nextTick()
    expect(vm.previewPanelCollapsed).toBe(true)

    // Inject a second show_preview message — panel still collapsed
    // (the watcher that used to flip it to false is gone).
    vm.messages.push(makeShowPreviewMessage('msg-noauto-2'))
    await nextTick()
    await nextTick()
    expect(vm.previewPanelCollapsed).toBe(true)

    // Inject a third — same. Verifies the watcher does NOT trigger
    // even when the array length grows multiple times in a session.
    vm.messages.push(makeShowPreviewMessage('msg-noauto-3'))
    await nextTick()
    await nextTick()
    expect(vm.previewPanelCollapsed).toBe(true)
  })

  // Regression test for the "user click still opens" half of the
  // opt-in policy (companion to the noauto test above). The
  // `openPreviewForMessage` click handler is the ONLY path that
  // un-collapses the panel; new previews arriving in the chat
  // don't, but the user can still pop the panel open by clicking
  // a `show_preview` bubble. This test verifies that.
  it('still opens the panel when the user explicitly clicks a show_preview bubble', async () => {
    installChatViewMocks()
    wrapper = await mountChatView('session_bubble_clickopens')

    const vm = wrapper!.vm as unknown as {
      messages: unknown[]
      previewPanelCollapsed: boolean
      previewPanelDismissed: boolean
      previewToShowId: string | null
    }

    // Inject a show_preview message. The panel starts collapsed
    // (verified by the test above); the click handler is the only
    // way to open it.
    vm.messages = [makeShowPreviewMessage('msg-clickopens-1')]
    await nextTick()
    await nextTick()
    expect(vm.previewPanelCollapsed).toBe(true)

    // User clicks the bubble — panel un-collapses and focusId
    // is set to the clicked message id.
    const card = wrapper!.find('[data-testid="show-preview-card-msg-clickopens-1"]')
    expect(card.exists()).toBe(true)
    await card.trigger('click')
    await nextTick()

    expect(vm.previewPanelCollapsed).toBe(false)
    expect(vm.previewPanelDismissed).toBe(false)
    expect(vm.previewToShowId).toBe('msg-clickopens-1')
  })

  // ─── Display mode (user-controlled sidebar/inline toggle, 2026-08-06) ──
  //
  // The user flips between 'side' (PreviewSidePanel — current default)
  // and 'inline' (rich content renders inside chat bubble). When the
  // mode is 'inline':
  //   - ChatView auto-dismisses the side panel.
  //   - A floating "Open preview panel" button appears at top-right.
  // Clicking that button flips the mode back to 'side' and
  // re-shows the panel.
  describe('Preview display mode (sidebar/inline toggle)', () => {
    it('hides the side panel when localStorage is set to "inline" on mount', async () => {
      // Set inline mode BEFORE mount so the composable reads it.
      localStorage.setItem('nalar-preview-display-mode', 'inline')

      installChatViewMocks()
      wrapper = await mountChatView('session_inline_init')

      const vm = wrapper!.vm as unknown as { messages: unknown[] }
      vm.messages = [makeShowPreviewMessage('msg-inline-init-1')]
      await nextTick()
      await nextTick()

      // Side panel must NOT be in the DOM (v-if="!previewPanelDismissed").
      expect(wrapper!.find('[data-testid="preview-side-panel"]').exists()).toBe(false)
    })

    it('shows the floating restore button when mode is "inline" AND there is at least one preview', async () => {
      localStorage.setItem('nalar-preview-display-mode', 'inline')

      installChatViewMocks()
      wrapper = await mountChatView('session_inline_restore')

      const vm = wrapper!.vm as unknown as { messages: unknown[] }
      vm.messages = [makeShowPreviewMessage('msg-inline-restore-1')]
      await nextTick()
      await nextTick()

      expect(wrapper!.find('[data-testid="restore-preview-panel-button"]').exists()).toBe(true)
    })

    it('does NOT show the restore button in "side" mode (default)', async () => {
      installChatViewMocks()
      wrapper = await mountChatView('session_side_no_restore')

      const vm = wrapper!.vm as unknown as { messages: unknown[] }
      vm.messages = [makeShowPreviewMessage('msg-side-no-restore-1')]
      await nextTick()
      await nextTick()

      expect(wrapper!.find('[data-testid="restore-preview-panel-button"]').exists()).toBe(false)
    })

    it('does NOT show the restore button in inline mode when there are zero previews', async () => {
      localStorage.setItem('nalar-preview-display-mode', 'inline')

      installChatViewMocks()
      wrapper = await mountChatView('session_inline_no_previews')

      const vm = wrapper!.vm as unknown as { messages: unknown[] }
      vm.messages = [] // No show_preview messages.
      await nextTick()
      await nextTick()

      expect(wrapper!.find('[data-testid="restore-preview-panel-button"]').exists()).toBe(false)
    })

    it('clicking the restore button flips mode to "side" AND re-shows the panel', async () => {
      localStorage.setItem('nalar-preview-display-mode', 'inline')

      installChatViewMocks()
      wrapper = await mountChatView('session_inline_click_restore')

      const vm = wrapper!.vm as unknown as { messages: unknown[] }
      vm.messages = [makeShowPreviewMessage('msg-inline-click-restore-1')]
      await nextTick()
      await nextTick()

      // Sanity: starting state — panel hidden, restore button visible.
      expect(wrapper!.find('[data-testid="preview-side-panel"]').exists()).toBe(false)
      const restoreBtn = wrapper!.find('[data-testid="restore-preview-panel-button"]')
      expect(restoreBtn.exists()).toBe(true)

      await restoreBtn.trigger('click')
      await nextTick()
      await nextTick()

      // Mode flipped, panel re-mounted, restore button gone.
      expect(localStorage.getItem('nalar-preview-display-mode')).toBe('side')
      expect(wrapper!.find('[data-testid="preview-side-panel"]').exists()).toBe(true)
      expect(wrapper!.find('[data-testid="restore-preview-panel-button"]').exists()).toBe(false)
    })

    it('ShowPreview card renders content inline when mode is "inline"', async () => {
      localStorage.setItem('nalar-preview-display-mode', 'inline')

      installChatViewMocks()
      wrapper = await mountChatView('session_inline_render')

      const vm = wrapper!.vm as unknown as { messages: unknown[] }
      vm.messages = [makeShowPreviewMessage('msg-inline-render-1')]
      await nextTick()
      await nextTick()

      // The card itself renders as before, but the rich content body
      // is now mounted inside it (data-testid="show-preview-inline-content").
      const inlineContent = wrapper!.find('[data-testid="show-preview-inline-content"]')
      expect(inlineContent.exists()).toBe(true)
    })
  })
})
