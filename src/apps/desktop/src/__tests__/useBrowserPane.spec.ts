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
  rectCalls: unknown[]
  closeCalls: number
} {
  const stub = {
    showCalls: [] as unknown[],
    hideCalls: 0,
    rectCalls: [] as unknown[],
    closeCalls: 0,
    show: async (tabId: string, url: string, ...rest: unknown[]) => {
      stub.showCalls.push([tabId, url, ...rest])
      return { ok: true, visible: true }
    },
    hide: async () => {
      stub.hideCalls += 1
      return { ok: true, visible: false }
    },
    status: async () => ({ supported: true, visible: true }),
    rect: async (x: number, y: number, width: number, height: number) => {
      stub.rectCalls.push([x, y, width, height])
      return { ok: true, visible: true }
    },
    close: async () => {
      stub.closeCalls += 1
      return { ok: true, visible: false }
    },
  }
  return stub
}

function mountPane(): {
  wrapper: ReturnType<typeof mount>
  paneVisible: Ref<boolean>
  setPaneHost: (el: Element | null) => void
} {
  let exposed!: Ref<boolean>
  let setHost!: (el: Element | null) => void
  const Host = defineComponent({
    setup() {
      const { paneVisible, setPaneHost } = useBrowserPane()
      exposed = paneVisible
      setHost = setPaneHost
      return () => h('div')
    },
  })
  const wrapper = mount(Host)
  return { wrapper, paneVisible: exposed, setPaneHost: setHost }
}

/** A fake tab body element reporting `box` (mutate `box` to move it). */
function stubElement(box: { x: number; y: number; width: number; height: number }): Element {
  return {
    getBoundingClientRect: () => ({
      ...box,
      top: box.y,
      left: box.x,
      right: box.x + box.width,
      bottom: box.y + box.height,
      toJSON: () => ({}),
    }),
  } as unknown as Element
}

// requestAnimationFrame, captured: layout events schedule a frame, and the
// test runs it explicitly — no real timers, no cross-test leakage.
const pendingFrames = new Map<number, FrameRequestCallback>()
let nextFrameId = 0

async function runRaf(): Promise<void> {
  const callbacks = [...pendingFrames.values()]
  pendingFrames.clear()
  for (const callback of callbacks) callback(0)
  await settle()
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
    pendingFrames.clear()
    nextFrameId = 0
    vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback): number => {
      nextFrameId += 1
      pendingFrames.set(nextFrameId, callback)
      return nextFrameId
    })
    vi.stubGlobal('cancelAnimationFrame', (id: number): void => {
      pendingFrames.delete(id)
    })
  })

  afterEach(() => {
    __setBrowserBridgeForTests(null)
    __setBrowserPaneForTests(null)
    pendingFrames.clear()
    vi.unstubAllGlobals()
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

  it('carries the tab body rect on the first show', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab('https://example.com')

    const { wrapper, paneVisible, setPaneHost } = mountPane()
    setPaneHost(stubElement({ x: 10, y: 20, width: 300, height: 200 }))
    await settle()

    expect(pane.showCalls).toEqual([[tab.id, 'https://example.com', 10, 20, 300, 200]])
    expect(paneVisible.value).toBe(true)
    wrapper.unmount()
  })

  it('reports layout changes on window resize, only when the numbers changed', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab('https://example.com')
    const { wrapper, setPaneHost } = mountPane()
    const box = { x: 10, y: 20, width: 300, height: 200 }
    setPaneHost(stubElement(box))
    await settle()
    expect(pane.showCalls).toEqual([[tab.id, 'https://example.com', 10, 20, 300, 200]])
    expect(pane.rectCalls).toHaveLength(0)

    // Same numbers: a resize schedules a frame but sends nothing.
    window.dispatchEvent(new window.Event('resize'))
    await runRaf()
    expect(pane.rectCalls).toHaveLength(0)

    // New numbers: one rect call, even across two resizes in one frame.
    box.x = 40
    box.width = 320
    window.dispatchEvent(new window.Event('resize'))
    window.dispatchEvent(new window.Event('resize'))
    await runRaf()
    expect(pane.rectCalls).toEqual([[40, 20, 320, 200]])
    wrapper.unmount()
  })

  it('hides (not closes) when leaving the tab for another one', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible } = mountPane()
    await settle()
    expect(paneVisible.value).toBe(true)

    // Leaving for a chat tab: the page survives, so hide — never close.
    tabs.open({ path: '/app', query: { view: 'chat', session: 's_1' } })
    await settle()

    expect(pane.hideCalls).toBe(1)
    expect(pane.closeCalls).toBe(0)
    expect(paneVisible.value).toBe(false)
    wrapper.unmount()
  })

  it('closes (not hides) the pane when the tab is closed', async () => {
    const pane = recordingPaneStub()
    __setBrowserPaneForTests(pane)
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible } = mountPane()
    await settle()
    expect(paneVisible.value).toBe(true)

    // Removing the tab from the store destroys the view: exactly one close,
    // and no hide for the dead view.
    tabs.close(tab.id)
    await settle()

    expect(pane.closeCalls).toBe(1)
    expect(pane.hideCalls).toBe(0)
    expect(paneVisible.value).toBe(false)
    wrapper.unmount()
  })

  it('never throws without pane globals, even with a host and layout events', async () => {
    __setBrowserPaneForTests(null)
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab('https://example.com')
    const { wrapper, paneVisible, setPaneHost } = mountPane()
    setPaneHost(stubElement({ x: 1, y: 2, width: 3, height: 4 }))
    await settle()
    window.dispatchEvent(new window.Event('resize'))
    await runRaf()
    tabs.close(tab.id)
    await settle()

    expect(paneVisible.value).toBe(false)
    wrapper.unmount()
    await settle()
  })
})
