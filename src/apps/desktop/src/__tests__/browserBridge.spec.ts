import { beforeEach, describe, expect, it, vi } from 'vitest'

import {
  __resetBrowserBridgeForTests,
  __setBrowserBridgeForTests,
  browserBridgeAvailable,
  browserStatus,
  closeBrowserWindow,
  openBrowserWindow,
  type NalarBrowserLike,
} from '../helpers/browserBridge'

function recordingStub(): NalarBrowserLike & {
  calls: { open: unknown[]; status: unknown[]; close: unknown[] }
} {
  const calls = { open: [] as unknown[], status: [] as unknown[], close: [] as unknown[] }
  return {
    calls,
    open: vi.fn(async (tabId: string, url: string) => {
      calls.open.push([tabId, url])
      return { ok: true, alive: 1 }
    }),
    status: vi.fn(async (tabId: string) => {
      calls.status.push([tabId])
      return { alive: 1 }
    }),
    close: vi.fn(async (tabId: string) => {
      calls.close.push([tabId])
      return { ok: true }
    }),
  }
}

describe('browserBridge', () => {
  beforeEach(() => {
    __setBrowserBridgeForTests(null)
  })

  it('passes open args through and reports the payload shape', async () => {
    const stub = recordingStub()
    __setBrowserBridgeForTests(stub)
    expect(browserBridgeAvailable()).toBe(true)

    const opened = await openBrowserWindow('tab_1', 'https://example.com')
    expect(opened).toEqual({ available: true, ok: true, error: undefined })
    expect(stub.calls.open).toEqual([['tab_1', 'https://example.com']])

    const st = await browserStatus('tab_1')
    expect(st).toEqual({ available: true, alive: true })
    expect(stub.calls.status).toEqual([['tab_1']])

    await closeBrowserWindow('tab_1')
    expect(stub.calls.close).toEqual([['tab_1']])
  })

  it('maps status alive:0 to alive:false', async () => {
    __setBrowserBridgeForTests({
      open: async () => ({ ok: true, alive: 0 }),
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    await expect(browserStatus('tab_x')).resolves.toEqual({ available: true, alive: false })
  })

  it('degrades when the bridge is absent and never throws', async () => {
    __setBrowserBridgeForTests(null)
    expect(browserBridgeAvailable()).toBe(false)
    await expect(openBrowserWindow('tab_1', 'https://example.com')).resolves.toEqual({
      available: false,
      ok: false,
    })
    await expect(browserStatus('tab_1')).resolves.toEqual({ available: false, alive: false })
    await expect(closeBrowserWindow('tab_1')).resolves.toBeUndefined()
  })

  it('reads the flat globals the shell actually binds', async () => {
    // The vendored glue sets `window[name]` verbatim (there is no namespace
    // walking), so the shell binds nalarBrowserOpen/Status/Close. Binding
    // "nalarBrowser.open" created `window["nalarBrowser.open"]` and left
    // window.nalarBrowser undefined — the shipped bug this test locks out.
    const scope = globalThis as unknown as Record<string, unknown>
    const calls: unknown[] = []
    __resetBrowserBridgeForTests()
    scope.nalarBrowserOpen = async (tabId: string, url: string) => {
      calls.push(['open', tabId, url])
      return { ok: true, alive: 1 }
    }
    scope.nalarBrowserStatus = async (tabId: string) => {
      calls.push(['status', tabId])
      return { alive: 1 }
    }
    scope.nalarBrowserClose = async (tabId: string) => {
      calls.push(['close', tabId])
      return { ok: true }
    }
    try {
      expect(browserBridgeAvailable()).toBe(true)
      await expect(openBrowserWindow('tab_9', 'https://example.com')).resolves.toEqual({
        available: true,
        ok: true,
        error: undefined,
      })
      await expect(browserStatus('tab_9')).resolves.toEqual({ available: true, alive: true })
      await closeBrowserWindow('tab_9')
      expect(calls).toEqual([
        ['open', 'tab_9', 'https://example.com'],
        ['status', 'tab_9'],
        ['close', 'tab_9'],
      ])
    } finally {
      delete scope.nalarBrowserOpen
      delete scope.nalarBrowserStatus
      delete scope.nalarBrowserClose
    }
  })

  it('needs all three flat globals to call the bridge present', async () => {
    const scope = globalThis as unknown as Record<string, unknown>
    __resetBrowserBridgeForTests()
    scope.nalarBrowserOpen = async () => ({ ok: true, alive: 1 })
    try {
      // A half-installed shell must read as absent, not as "open exists".
      expect(browserBridgeAvailable()).toBe(false)
      await expect(browserStatus('tab_1')).resolves.toEqual({ available: false, alive: false })
    } finally {
      delete scope.nalarBrowserOpen
    }
  })

  it('degrades when the bridge rejects, with no unhandled rejection', async () => {
    __setBrowserBridgeForTests({
      open: async () => {
        throw new Error('shell gone')
      },
      status: async () => {
        throw new Error('shell gone')
      },
      close: async () => {
        throw new Error('shell gone')
      },
    })
    await expect(openBrowserWindow('tab_1', 'https://example.com')).resolves.toEqual({
      available: true,
      ok: false,
    })
    await expect(browserStatus('tab_1')).resolves.toEqual({ available: true, alive: false })
    await expect(closeBrowserWindow('tab_1')).resolves.toBeUndefined()
  })
})
