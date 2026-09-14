import { beforeEach, describe, expect, it, vi } from 'vitest'

import {
  __resetBrowserBridgeForTests,
  __resetBrowserPaneForTests,
  __setBrowserBridgeForTests,
  __setBrowserPaneForTests,
  browserBridgeAvailable,
  browserPaneAvailable,
  browserPaneStatus,
  browserStatus,
  closeBrowserPane,
  closeBrowserWindow,
  hideBrowserPane,
  openBrowserWindow,
  rectBrowserPane,
  showBrowserPane,
  type NalarBrowserLike,
  type NalarBrowserPaneLike,
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
    __setBrowserPaneForTests(null)
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

function recordingPaneStub(): NalarBrowserPaneLike & {
  calls: { show: unknown[]; hide: number; status: number }
} {
  const calls = { show: [] as unknown[], hide: 0, status: 0 }
  return {
    calls,
    show: async (tabId: string, url: string) => {
      calls.show.push([tabId, url])
      return { ok: true, visible: true }
    },
    hide: async () => {
      calls.hide += 1
      return { ok: true, visible: false }
    },
    status: async () => {
      calls.status += 1
      return { supported: true, visible: true }
    },
  }
}

describe('browserPane', () => {
  beforeEach(() => {
    __setBrowserBridgeForTests(null)
    __setBrowserPaneForTests(null)
  })

  it('passes show args through and reports the payload shape', async () => {
    const stub = recordingPaneStub()
    __setBrowserPaneForTests(stub)
    expect(browserPaneAvailable()).toBe(true)

    const shown = await showBrowserPane('tab_1', 'https://example.com')
    expect(shown).toEqual({ available: true, ok: true, visible: true, error: undefined })
    expect(stub.calls.show).toEqual([['tab_1', 'https://example.com']])

    const hidden = await hideBrowserPane()
    expect(hidden).toEqual({ available: true, ok: true, visible: false })
    expect(stub.calls.hide).toBe(1)

    const st = await browserPaneStatus()
    expect(st).toEqual({ available: true, supported: true, visible: true })
    expect(stub.calls.status).toBe(1)
  })

  it('reports ok:false and supported:false honestly', async () => {
    __setBrowserPaneForTests({
      show: async () => ({ ok: false, visible: false, error: 'no container' }),
      hide: async () => ({ ok: false, visible: false }),
      status: async () => ({ supported: false, visible: false }),
    })
    await expect(showBrowserPane('tab_1', 'https://example.com')).resolves.toEqual({
      available: true,
      ok: false,
      visible: false,
      error: 'no container',
    })
    await expect(hideBrowserPane()).resolves.toEqual({
      available: true,
      ok: false,
      visible: false,
    })
    // A shell that answers but does not support the pane is present but
    // unsupported — not absent.
    await expect(browserPaneStatus()).resolves.toEqual({
      available: true,
      supported: false,
      visible: false,
    })
  })

  it('degrades when the pane is absent and never throws', async () => {
    __setBrowserPaneForTests(null)
    expect(browserPaneAvailable()).toBe(false)
    await expect(showBrowserPane('tab_1', 'https://example.com')).resolves.toEqual({
      available: false,
      ok: false,
      visible: false,
    })
    await expect(hideBrowserPane()).resolves.toEqual({
      available: false,
      ok: false,
      visible: false,
    })
    await expect(browserPaneStatus()).resolves.toEqual({
      available: false,
      supported: false,
      visible: false,
    })
  })

  it('reads the flat pane globals the shell actually binds', async () => {
    const scope = globalThis as unknown as Record<string, unknown>
    const calls: unknown[] = []
    __resetBrowserPaneForTests()
    scope.nalarBrowserPaneShow = async (tabId: string, url: string) => {
      calls.push(['show', tabId, url])
      return { ok: true, visible: true }
    }
    scope.nalarBrowserPaneHide = async () => {
      calls.push(['hide'])
      return { ok: true, visible: false }
    }
    scope.nalarBrowserPaneStatus = async () => {
      calls.push(['status'])
      return { supported: true, visible: true }
    }
    try {
      expect(browserPaneAvailable()).toBe(true)
      await expect(showBrowserPane('tab_9', 'https://example.com')).resolves.toEqual({
        available: true,
        ok: true,
        visible: true,
        error: undefined,
      })
      await expect(hideBrowserPane()).resolves.toEqual({
        available: true,
        ok: true,
        visible: false,
      })
      await expect(browserPaneStatus()).resolves.toEqual({
        available: true,
        supported: true,
        visible: true,
      })
      expect(calls).toEqual([['show', 'tab_9', 'https://example.com'], ['hide'], ['status']])
    } finally {
      delete scope.nalarBrowserPaneShow
      delete scope.nalarBrowserPaneHide
      delete scope.nalarBrowserPaneStatus
    }
  })

  it('needs all three flat pane globals to call the pane present', async () => {
    const scope = globalThis as unknown as Record<string, unknown>
    __resetBrowserPaneForTests()
    scope.nalarBrowserPaneShow = async () => ({ ok: true, visible: true })
    try {
      // A half-installed shell must read as absent, not as "show exists".
      expect(browserPaneAvailable()).toBe(false)
      await expect(browserPaneStatus()).resolves.toEqual({
        available: false,
        supported: false,
        visible: false,
      })
    } finally {
      delete scope.nalarBrowserPaneShow
    }
  })

  it('degrades when the pane rejects, with no unhandled rejection', async () => {
    __setBrowserPaneForTests({
      show: async () => {
        throw new Error('shell gone')
      },
      hide: async () => {
        throw new Error('shell gone')
      },
      status: async () => {
        throw new Error('shell gone')
      },
    })
    await expect(showBrowserPane('tab_1', 'https://example.com')).resolves.toEqual({
      available: true,
      ok: false,
      visible: false,
    })
    await expect(hideBrowserPane()).resolves.toEqual({
      available: true,
      ok: false,
      visible: false,
    })
    await expect(browserPaneStatus()).resolves.toEqual({
      available: true,
      supported: false,
      visible: false,
    })
  })

  it('a shell with the process bridge but no pane reports the pane as unavailable', async () => {
    // macOS today: the window triple exists, the pane triple does not.
    __setBrowserBridgeForTests({
      open: async () => ({ ok: true, alive: 1 }),
      status: async () => ({ alive: 0 }),
      close: async () => ({ ok: true }),
    })
    __setBrowserPaneForTests(null)
    expect(browserBridgeAvailable()).toBe(true)
    expect(browserPaneAvailable()).toBe(false)
    await expect(showBrowserPane('tab_1', 'https://example.com')).resolves.toEqual({
      available: false,
      ok: false,
      visible: false,
    })
  })

  it('forwards the rect on show when the caller has one', async () => {
    const seen: unknown[] = []
    __setBrowserPaneForTests({
      show: async (...args: unknown[]) => {
        seen.push(args)
        return { ok: true, visible: true }
      },
      hide: async () => ({ ok: true, visible: false }),
      status: async () => ({ supported: true, visible: true }),
    })
    await expect(
      showBrowserPane('tab_1', 'https://example.com', { x: 10, y: 20, width: 300, height: 200 }),
    ).resolves.toEqual({ available: true, ok: true, visible: true, error: undefined })
    expect(seen).toEqual([['tab_1', 'https://example.com', 10, 20, 300, 200]])
  })

  it('moves/resizes the pane without navigating', async () => {
    const seen: unknown[] = []
    __setBrowserPaneForTests({
      show: async () => ({ ok: true, visible: true }),
      hide: async () => ({ ok: true, visible: false }),
      status: async () => ({ supported: true, visible: true }),
      rect: async (x: number, y: number, width: number, height: number) => {
        seen.push([x, y, width, height])
        return { ok: true, visible: true }
      },
    })
    await expect(rectBrowserPane({ x: 12, y: 34, width: 500, height: 400 })).resolves.toEqual({
      available: true,
      ok: true,
    })
    expect(seen).toEqual([[12, 34, 500, 400]])
  })

  it('destroys the pane view on close', async () => {
    let closed = 0
    __setBrowserPaneForTests({
      show: async () => ({ ok: true, visible: true }),
      hide: async () => ({ ok: true, visible: false }),
      status: async () => ({ supported: true, visible: true }),
      close: async () => {
        closed += 1
        return { ok: true, visible: false }
      },
    })
    await expect(closeBrowserPane()).resolves.toEqual({ available: true, ok: true })
    expect(closed).toBe(1)
  })

  it('degrades rect/close when the pane is absent and never throws', async () => {
    __setBrowserPaneForTests(null)
    await expect(rectBrowserPane({ x: 0, y: 0, width: 10, height: 10 })).resolves.toEqual({
      available: false,
      ok: false,
    })
    await expect(closeBrowserPane()).resolves.toEqual({ available: false, ok: false })
  })

  it('degrades rect/close on an older shell whose triple has neither', async () => {
    // The pre-rect shell: show/hide/status exist, rect/close do not. The
    // pane still counts as present; only the new calls report ok:false.
    __setBrowserPaneForTests({
      show: async () => ({ ok: true, visible: true }),
      hide: async () => ({ ok: true, visible: false }),
      status: async () => ({ supported: true, visible: true }),
    })
    expect(browserPaneAvailable()).toBe(true)
    await expect(rectBrowserPane({ x: 0, y: 0, width: 10, height: 10 })).resolves.toEqual({
      available: true,
      ok: false,
    })
    await expect(closeBrowserPane()).resolves.toEqual({ available: true, ok: false })
  })

  it('degrades when rect/close reject, with no unhandled rejection', async () => {
    __setBrowserPaneForTests({
      show: async () => ({ ok: true, visible: true }),
      hide: async () => ({ ok: true, visible: false }),
      status: async () => ({ supported: true, visible: true }),
      rect: async () => {
        throw new Error('shell gone')
      },
      close: async () => {
        throw new Error('shell gone')
      },
    })
    await expect(rectBrowserPane({ x: 0, y: 0, width: 10, height: 10 })).resolves.toEqual({
      available: true,
      ok: false,
    })
    await expect(closeBrowserPane()).resolves.toEqual({ available: true, ok: false })
  })

  it('reads the flat rect/close pane globals the shell actually binds', async () => {
    const scope = globalThis as unknown as Record<string, unknown>
    const calls: unknown[] = []
    __resetBrowserPaneForTests()
    scope.nalarBrowserPaneShow = async () => ({ ok: true, visible: true })
    scope.nalarBrowserPaneHide = async () => ({ ok: true, visible: false })
    scope.nalarBrowserPaneStatus = async () => ({ supported: true, visible: true })
    scope.nalarBrowserPaneRect = async (x: unknown, y: unknown, width: unknown, height: unknown) => {
      calls.push(['rect', x, y, width, height])
      return { ok: true, visible: true }
    }
    scope.nalarBrowserPaneClose = async () => {
      calls.push(['close'])
      return { ok: true, visible: false }
    }
    try {
      expect(browserPaneAvailable()).toBe(true)
      await expect(rectBrowserPane({ x: 1, y: 2, width: 3, height: 4 })).resolves.toEqual({
        available: true,
        ok: true,
      })
      await expect(closeBrowserPane()).resolves.toEqual({ available: true, ok: true })
      expect(calls).toEqual([
        ['rect', 1, 2, 3, 4],
        ['close'],
      ])
    } finally {
      delete scope.nalarBrowserPaneShow
      delete scope.nalarBrowserPaneHide
      delete scope.nalarBrowserPaneStatus
      delete scope.nalarBrowserPaneRect
      delete scope.nalarBrowserPaneClose
    }
  })
})
