import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, nextTick, type Ref } from 'vue'

import { useBrowserPane } from '../composables/useBrowserPane'
import {
  __setBrowserBridgeForTests,
  __setBrowserPaneForTests,
  type NalarBrowserPaneLike,
} from '../helpers/browserBridge'
import { __resetWindowIdForTests } from '../helpers/windowId'
import { useTabsStore } from '../stores/tabs'
import { makeLocalStorageStub } from './helpers'

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  Object.defineProperty(globalThis, 'sessionStorage', {
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_browserpane' }),
    writable: true,
    configurable: true,
  })
}

function recordingPaneStub(): NalarBrowserPaneLike & {
  showCalls: unknown[]
  hideCalls: number
} {
  const stub = {
    showCalls: [] as unknown[],
    hideCalls: 0,
    show: async (tabId: string, url: string) => {
      stub.showCalls.push([tabId, url])
      return { ok: true, visible: true }
    },
    hide: async () => {
      stub.hideCalls += 1
      return { ok: true, visible: false }
    },
    status: async () => ({ supported: true, visible: true }),
  }
  return stub
}

function mountPane(): { wrapper: ReturnType<typeof mount>; paneVisible: Ref<boolean> } {
  let exposed!: Ref<boolean>
  const Host = defineComponent({
    setup() {
      const { paneVisible } = useBrowserPane()
      exposed = paneVisible
      return () => h('div')
    },
  })
  const wrapper = mount(Host)
  return { wrapper, paneVisible: exposed }
}

async function settle(): Promise<void> {
  await flushPromises()
  await nextTick()
  await flushPromises()
  await nextTick()
}

describe('useBrowserPane', () => {
  beforeEach(() => {
    installStorage()
    __resetWindowIdForTests()
    setActivePinia(createPinia())
    __setBrowserBridgeForTests(null)
    __setBrowserPaneForTests(null)
  })

  afterEach(() => {
    __setBrowserBridgeForTests(null)
    __setBrowserPaneForTests(null)
    vi.restoreAllMocks()
  })

  it('shows the pane when a browser tab with a URL is active', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab('https://example.com')

    const { paneVisible } = mountPane()
    await settle()

    expect(pane.showCalls).toEqual([[tab.id, 'https://example.com']])
    expect(paneVisible.value).toBe(true)
  })

  it('hides the pane on a chat tab', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible } = mountPane()
    await settle()
    expect(paneVisible.value).toBe(true)

    tabs.open({ path: '/app', query: { view: 'chat', session: 's_1' } })
    expect(tabs.activeTab?.kind).toBe('chat')
    await settle()

    expect(pane.hideCalls).toBe(1)
    expect(paneVisible.value).toBe(false)
    wrapper.unmount()
  })

  it('hides the pane when the strip is disabled', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible } = mountPane()
    await settle()
    expect(paneVisible.value).toBe(true)

    tabs.setEnabled(false)
    await settle()

    expect(pane.hideCalls).toBe(1)
    expect(paneVisible.value).toBe(false)
    wrapper.unmount()
  })

  it('does not reload on re-activation: one show call across two activations', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible } = mountPane()
    await settle()
    expect(pane.showCalls).toHaveLength(1)

    // Re-activating the same tab changes nothing the watcher reads …
    tabs.activate(tab.id)
    await settle()
    // … and neither does re-navigating it to the URL it already has.
    tabs.navigateBrowserTab(tab.id, 'https://example.com')
    await settle()

    expect(pane.showCalls).toEqual([[tab.id, 'https://example.com']])
    expect(paneVisible.value).toBe(true)
    wrapper.unmount()
  })

  it('a stale async reply never flips the state', async () => {
    let resolveShow!: (value: { ok: boolean; visible: boolean }) => void
    const pane = recordingPaneStub()
    pane.show = () =>
      new Promise<{ ok: boolean; visible: boolean }>((resolve) => {
        resolveShow = resolve
      })
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible } = mountPane()
    await settle()
    // The show is still in flight: nothing assigned yet.
    expect(paneVisible.value).toBe(false)

    // Leave for a chat tab while the first show is pending.
    tabs.open({ path: '/app', query: { view: 'chat', session: 's_1' } })
    await settle()
    expect(paneVisible.value).toBe(false)

    // The stale show finally answers "visible" — it must not win.
    resolveShow({ ok: true, visible: true })
    await settle()

    expect(paneVisible.value).toBe(false)
    wrapper.unmount()
  })

  it('stays hidden and never throws when the pane is absent', async () => {
    __setBrowserPaneForTests(null)
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible } = mountPane()
    await settle()

    expect(paneVisible.value).toBe(false)
    wrapper.unmount()
    await settle()
  })

  it('hides on unmount', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const { wrapper } = mountPane()
    await settle()
    expect(pane.hideCalls).toBe(0)

    wrapper.unmount()
    await settle()

    expect(pane.hideCalls).toBe(1)
  })
})
