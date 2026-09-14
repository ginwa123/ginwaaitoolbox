import { flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { __setBrowserBridgeForTests, __setBrowserPaneForTests } from '../helpers/browserBridge'
import { openExternal } from '../helpers/openExternal'
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
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_openexternal' }),
    writable: true,
    configurable: true,
  })
}

describe('openExternal', () => {
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

  it('lands in the browser tab with the pane — no window, no window.open — when the pane is available', async () => {
    const shown: unknown[] = []
    const opened: unknown[] = []
    __setBrowserPaneForTests({
      show: async (tabId: string, url: string) => {
        shown.push([tabId, url])
        return { ok: true, visible: true }
      },
      hide: async () => ({ ok: true, visible: false }),
      status: async () => ({ supported: true, visible: true }),
    })
    __setBrowserBridgeForTests({
      open: async (tabId: string, url: string) => {
        opened.push([tabId, url])
        return { ok: true, alive: 1 }
      },
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    const spy = vi.spyOn(window, 'open').mockImplementation(() => null)
    const tabs = useTabsStore()
    openExternal('https://example.com')
    await flushPromises()

    expect(tabs.activeTab?.kind).toBe('browser')
    expect(tabs.activeTab?.query.url).toBe('https://example.com')
    expect(shown).toEqual([[tabs.activeTab?.id, 'https://example.com']])
    expect(opened).toHaveLength(0)
    expect(spy).not.toHaveBeenCalled()
  })

  it('creates and activates a browser tab and opens the window once', async () => {
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
    openExternal('https://example.com')
    await flushPromises()

    expect(tabs.activeTab?.kind).toBe('browser')
    expect(tabs.activeTab?.query.url).toBe('https://example.com')
    expect(opened).toHaveLength(1)
  })

  it('does not open a second window when one is already alive', async () => {
    const opened: unknown[] = []
    __setBrowserBridgeForTests({
      open: async (tabId: string, url: string) => {
        opened.push([tabId, url])
        return { ok: true, alive: 1 }
      },
      status: async () => ({ alive: 1 }),
      close: async () => ({ ok: true }),
    })
    openExternal('https://example.com')
    await flushPromises()
    expect(opened).toHaveLength(0)
  })

  it('sends blob: and javascript: to window.open with no tab and no bridge call', async () => {
    const opened: unknown[] = []
    __setBrowserBridgeForTests({
      open: async (tabId: string, url: string) => {
        opened.push([tabId, url])
        return { ok: true, alive: 1 }
      },
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    const spy = vi.spyOn(window, 'open').mockImplementation(() => null)
    const tabs = useTabsStore()
    const count = tabs.tabCount

    openExternal('blob:https://example.com/uuid')
    await flushPromises()
    openExternal('javascript:alert(1)')
    await flushPromises()

    expect(spy).toHaveBeenCalledWith('blob:https://example.com/uuid', '_blank', 'noopener')
    expect(spy).toHaveBeenCalledWith('javascript:alert(1)', '_blank', 'noopener')
    expect(tabs.tabCount).toBe(count)
    expect(opened).toHaveLength(0)
  })

  it('uses the fixed external id with no tab when tab mode is off', async () => {
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
    tabs.setEnabled(false)
    openExternal('https://example.com')
    await flushPromises()

    expect(tabs.tabCount).toBe(1)
    expect(opened).toEqual([['external', 'https://example.com']])
  })

  it('falls back to window.open when the bridge is absent and never throws', async () => {
    __setBrowserBridgeForTests(null)
    const spy = vi.spyOn(window, 'open').mockImplementation(() => null)
    expect(() => openExternal('https://example.com')).not.toThrow()
    await flushPromises()
    expect(spy).toHaveBeenCalledWith('https://example.com', '_blank', 'noopener')
  })
})
