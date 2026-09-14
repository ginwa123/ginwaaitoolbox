/**
 * Thin typed wrapper over the shell's `webview_bind` bridge.
 *
 * The shell (a Zig process) binds exactly three JS globals on the APP window:
 * - `window.nalarBrowser.open(tabId, url)` → `{ ok, alive, error? }`
 * - `window.nalarBrowser.status(tabId)` → `{ alive }` (0 or 1)
 * - `window.nalarBrowser.close(tabId)` → `{ ok }`
 *
 * When the bridge is absent (vitest, a plain-browser dev session at 5173, an
 * older shell) every call resolves to a documented "unavailable" result and
 * NEVER throws — the UI degrades to "Open in system browser".
 */

export interface NalarBrowserLike {
  open: (tabId: string, url: string) => Promise<{ ok: boolean; alive: number; error?: string }>
  status: (tabId: string) => Promise<{ alive: number }>
  close: (tabId: string) => Promise<{ ok: boolean }>
}

export interface BrowserBridgeStatus {
  available: boolean
  alive: boolean
}

export interface BrowserBridgeOpenResult {
  available: boolean
  ok: boolean
  error?: string
}

let testOverride: NalarBrowserLike | null | undefined

/** Test seam: stub the bridge without touching `window`. */
export function __setBrowserBridgeForTests(bridge: NalarBrowserLike | null): void {
  testOverride = bridge
}

function readBridge(): NalarBrowserLike | null {
  if (testOverride !== undefined) return testOverride
  try {
    const fromWindow = (globalThis as unknown as { window?: { nalarBrowser?: NalarBrowserLike } })
      .window?.nalarBrowser
    if (fromWindow) return fromWindow
    const fromGlobal = (globalThis as unknown as { nalarBrowser?: NalarBrowserLike }).nalarBrowser
    if (fromGlobal) return fromGlobal
  } catch {
    return null
  }
  return null
}

export function browserBridgeAvailable(): boolean {
  return readBridge() !== null
}

export async function openBrowserWindow(
  tabId: string,
  url: string,
): Promise<BrowserBridgeOpenResult> {
  const bridge = readBridge()
  if (!bridge) return { available: false, ok: false }
  try {
    const result = await bridge.open(tabId, url)
    return { available: true, ok: result.ok === true, error: result.error }
  } catch {
    return { available: true, ok: false }
  }
}

export async function browserStatus(tabId: string): Promise<BrowserBridgeStatus> {
  const bridge = readBridge()
  if (!bridge) return { available: false, alive: false }
  try {
    const result = await bridge.status(tabId)
    return { available: true, alive: result.alive === 1 }
  } catch {
    return { available: true, alive: false }
  }
}

export async function closeBrowserWindow(tabId: string): Promise<void> {
  const bridge = readBridge()
  if (!bridge) return
  try {
    await bridge.close(tabId)
  } catch {
    // The strip must never wait on — or throw because of — the shell.
  }
}
