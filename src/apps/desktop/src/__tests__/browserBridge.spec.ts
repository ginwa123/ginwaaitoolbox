import { beforeEach, describe, expect, it, vi } from 'vitest'

import {
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
