import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi, afterEach } from 'vitest'
import { nextTick } from 'vue'

import BrowserTabView from '../components/browser/BrowserTabView.vue'
import { __setBrowserBridgeForTests } from '../helpers/browserBridge'
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
  })

  afterEach(() => {
    __setBrowserBridgeForTests(null)
    vi.restoreAllMocks()
  })

  it('navigates a blank tab on Enter and opens the window via the bridge', async () => {
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

  it('shows no window open on mount and never auto-spawns', async () => {
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
    tabs.openBrowserTab('https://example.com')
    const wrapper = mount(BrowserTabView)
    await flushPromises()
    await nextTick()

    expect(wrapper.find('[data-testid="browser-window-status"]').text()).toBe('no window open')
    expect(wrapper.find('[data-testid="browser-open-window"]').text()).toBe('Open browser window')
    expect(opened).toHaveLength(0)
  })

  it('follows the status: clicking opens, the label flips, a repeat click still calls the bridge', async () => {
    let live = false
    const opened: unknown[] = []
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
    expect(wrapper.find('[data-testid="browser-open-window"]').text()).toBe('Open browser window')

    await wrapper.find('[data-testid="browser-open-window"]').trigger('click')
    await flushPromises()
    await nextTick()
    expect(opened).toHaveLength(1)
    expect(wrapper.find('[data-testid="browser-window-status"]').text()).toBe('1 window open')
    expect(wrapper.find('[data-testid="browser-open-window"]').text()).toBe('Open another window')

    // a repeat click with a live window still calls the bridge (the shell decides)
    await wrapper.find('[data-testid="browser-open-window"]').trigger('click')
    await flushPromises()
    expect(opened).toHaveLength(2)
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
