import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi, afterEach } from 'vitest'
import { nextTick } from 'vue'

import BrowserTabView from '../components/browser/BrowserTabView.vue'
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
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_browserview' }),
    writable: true,
    configurable: true,
  })
}

describe('BrowserTabView', () => {
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

  function recordingPaneStub(visible: boolean): NalarBrowserPaneLike & { shown: unknown[] } {
    const stub = {
      shown: [] as unknown[],
      show: async (tabId: string, url: string) => {
        stub.shown.push([tabId, url])
        return { ok: true, visible }
      },
      hide: async () => ({ ok: true, visible: false }),
      status: async () => ({ supported: true, visible }),
    }
    return stub
  }

  it('navigates a blank tab on Enter and drives the pane when it is available', async () => {
    const pane = recordingPaneStub(true)
    __setBrowserPaneForTests(pane)
    __setBrowserBridgeForTests({
      open: async () => ({ ok: true, alive: 1 }),
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab()
    const wrapper = mount(BrowserTabView)
    await flushPromises()

    await wrapper.find('[data-testid="browser-address"]').setValue('example.com')
    await wrapper.find('[data-testid="browser-address"]').trigger('keydown.enter')
    await flushPromises()
    await nextTick()

    expect(tabs.activeTab?.query.url).toBe('https://example.com')
    // The pane shows the page: no window spawn, no system browser.
    expect(pane.shown).toEqual([[tab.id, 'https://example.com']])
    expect(openSpy).not.toHaveBeenCalled()
    expect(wrapper.emitted('navigate')).toHaveLength(1)
  })

  it('navigates a blank tab on Enter and opens the window when the pane is missing', async () => {
    const opened: unknown[] = []
    __setBrowserPaneForTests(null)
    __setBrowserBridgeForTests({
      open: async (tabId: string, url: string) => {
        opened.push([tabId, url])
        return { ok: true, alive: 1 }
      },
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    const tabs = useTabsStore()
    const tab = tabs.openBrowserTab()
    const wrapper = mount(BrowserTabView)
    await flushPromises()

    await wrapper.find('[data-testid="browser-address"]').setValue('example.com')
    await wrapper.find('[data-testid="browser-address"]').trigger('keydown.enter')
    await flushPromises()
    await nextTick()

    expect(tabs.activeTab?.query.url).toBe('https://example.com')
    expect(opened).toEqual([[tab.id, 'https://example.com']])
    expect(wrapper.emitted('navigate')).toHaveLength(1)
  })

  it('refuses a javascript: address with an inline error and spawns nothing', async () => {
    const opened: unknown[] = []
    __setBrowserBridgeForTests({
      open: async (tabId: string, url: string) => {
        opened.push([tabId, url])
        return { ok: true, alive: 1 }
      },
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    const tabs = useTabsStore()
    tabs.openBrowserTab()
    const wrapper = mount(BrowserTabView)
    await flushPromises()

    await wrapper.find('[data-testid="browser-address"]').setValue('javascript:alert(1)')
    await wrapper.find('[data-testid="browser-address-open"]').trigger('click')
    await flushPromises()
    await nextTick()

    expect(wrapper.find('[data-testid="browser-address-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="browser-address-error"]').text()).toContain('javascript:')
    expect(opened).toHaveLength(0)
    expect(tabs.activeTab?.query.url).toBeUndefined()
    expect(wrapper.emitted('navigate')).toBeUndefined()
  })

  it('shows the pane note — and no window affordance — when the pane is available', async () => {
    const pane = recordingPaneStub(true)
    __setBrowserPaneForTests(pane)
    __setBrowserBridgeForTests({
      open: async () => ({ ok: true, alive: 1 }),
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const wrapper = mount(BrowserTabView)
    await flushPromises()
    await nextTick()

    expect(wrapper.find('[data-testid="browser-pane-note"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="browser-pane-note"]').text()).toContain(
      'Showing in the pane below',
    )
    expect(wrapper.find('[data-testid="browser-window-status"]').text()).toBe('pane visible')
    // Q3: no separate-window affordance anywhere in the UI.
    expect(wrapper.find('[data-testid="browser-open-window"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="browser-open-fallback"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="browser-bridge-missing"]').exists()).toBe(false)
    // The card itself never spawns: showing is the composable's job.
    expect(pane.shown).toHaveLength(0)
  })

  it('offers the window fallback when the pane is missing but the bridge exists', async () => {
    const opened: unknown[] = []
    let live = false
    __setBrowserPaneForTests(null)
    __setBrowserBridgeForTests({
      open: async (tabId: string, url: string) => {
        opened.push([tabId, url])
        live = true
        return { ok: true, alive: 1 }
      },
      status: async () => ({ alive: live ? 1 : 0 }),
      close: async () => ({ ok: true }),
    })
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const wrapper = mount(BrowserTabView)
    await flushPromises()
    await nextTick()

    expect(wrapper.find('[data-testid="browser-pane-note"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="browser-open-window"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="browser-window-status"]').text()).toBe('no window open')
    const fallback = wrapper.find('[data-testid="browser-open-fallback"]')
    expect(fallback.text()).toBe('Open browser window')

    await fallback.trigger('click')
    await flushPromises()
    await nextTick()
    expect(opened).toHaveLength(1)
    expect(wrapper.find('[data-testid="browser-window-status"]').text()).toBe('1 window open')
  })

  it('falls back to the system browser — and says why — when there is no bridge', async () => {
    // A plain-browser dev session (or an older shell) has no bridge at all.
    // The system-browser action must still DO something and must explain
    // itself; this is the "cannot click?" report from the human's manual check.
    __setBrowserBridgeForTests(null)
    __setBrowserPaneForTests(null)
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const spy = vi.spyOn(window, 'open').mockImplementation(() => null)
    const wrapper = mount(BrowserTabView)
    await flushPromises()
    await nextTick()

    expect(wrapper.find('[data-testid="browser-bridge-missing"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="browser-open-window"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="browser-open-fallback"]').exists()).toBe(false)
    const primary = wrapper.find('[data-testid="browser-open-system"]')
    expect(primary.text()).toBe('Open in system browser')

    await primary.trigger('click')
    expect(spy).toHaveBeenCalledWith('https://example.com', '_blank', 'noopener')
  })

  it('hands a blank-tab address to the system browser when there is no bridge', async () => {
    __setBrowserBridgeForTests(null)
    const tabs = useTabsStore()
    tabs.openBrowserTab()
    const spy = vi.spyOn(window, 'open').mockImplementation(() => null)
    const wrapper = mount(BrowserTabView)
    await flushPromises()

    await wrapper.find('[data-testid="browser-address"]').setValue('example.com')
    await wrapper.find('[data-testid="browser-address"]').trigger('keydown.enter')
    await flushPromises()

    // The tab still records the address …
    expect(tabs.activeTab?.query.url).toBe('https://example.com')
    // … and the user gets the page instead of nothing.
    expect(spy).toHaveBeenCalledWith('https://example.com', '_blank', 'noopener')
  })

  it('opens the url in the system browser from the secondary button', async () => {
    __setBrowserBridgeForTests({
      open: async () => ({ ok: true, alive: 1 }),
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    const tabs = useTabsStore()
    tabs.openBrowserTab('https://example.com')
    const spy = vi.spyOn(window, 'open').mockImplementation(() => null)
    const wrapper = mount(BrowserTabView)
    await flushPromises()

    await wrapper.find('[data-testid="browser-open-system"]').trigger('click')
    expect(spy).toHaveBeenCalledWith('https://example.com', '_blank', 'noopener')
  })
})
