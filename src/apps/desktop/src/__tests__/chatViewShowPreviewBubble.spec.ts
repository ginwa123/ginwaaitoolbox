/**
 * Tests for inline `show_preview` rendering in ChatView.
 *
 * show_preview tool messages render inline via <ShowPreview> —
 * there is no side panel. These tests verify the card renders and
 * the side-panel elements are gone.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

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

function makeShowPreviewMessage(id: string) {
  return {
    id,
    role: 'tool',
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
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await nextTick()
  return wrapper
}

describe('ChatView show_preview inline rendering', () => {
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

  it('renders show_preview tool messages inline via <ShowPreview>', async () => {
    installChatViewMocks()
    wrapper = await mountChatView('session_bubble_render')

    const vm = wrapper!.vm as unknown as { messages: unknown[] }
    vm.messages = [makeShowPreviewMessage('msg-sp-1')]
    await nextTick()
    await nextTick()

    const card = wrapper!.find('[data-testid="show-preview-card-msg-sp-1"]')
    expect(card.exists()).toBe(true)
    // Inline content is visible without any click.
    expect(
      wrapper!.find('[data-testid="show-preview-inline-content"]').exists(),
    ).toBe(true)
  })

  it('has no side panel and no restore button', async () => {
    installChatViewMocks()
    wrapper = await mountChatView('session_no_panel')

    const vm = wrapper!.vm as unknown as { messages: unknown[] }
    vm.messages = [makeShowPreviewMessage('msg-sp-2')]
    await nextTick()
    await nextTick()

    expect(
      wrapper!.find('[data-testid="preview-side-panel"]').exists(),
    ).toBe(false)
    expect(
      wrapper!.find('[data-testid="restore-preview-panel-button"]').exists(),
    ).toBe(false)
    expect(
      wrapper!.find('[data-testid="preview-display-mode-toggle"]').exists(),
    ).toBe(false)
  })
})
