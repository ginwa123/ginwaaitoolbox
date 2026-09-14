/**
 * Thin typed wrapper over the shell's `webview_bind` bridge.
 *
 * The shell (a Zig process) binds three **flat** globals on the APP window:
 *
 *   window.nalarBrowserOpen(tabId, url) → { ok, alive, error? }
 *   window.nalarBrowserStatus(tabId)    → { alive } (0 or 1)
 *   window.nalarBrowserClose(tabId)     → { ok }
 *
 * WHY FLAT: the vendored glue (`vendor/webview/webview.h`,
 * `Webview_.prototype.onBind`) does `window[name] = …` with the name VERBATIM —
 * there is no namespace walking — so binding `"nalarBrowser.open"` creates the
 * property `window["nalarBrowser.open"]` and leaves `window.nalarBrowser`
 * undefined. That shipped once: the shell looked wired but the SPA could never
 * reach it, and the button silently did nothing. The rule is locked by
 * `__tests__/webviewBindGlue.spec.ts`, which executes the real glue.
 *
 * This module is the single seam and presents the object shape
 * (`nalarBrowser.open/status/close`), accepting either spelling.
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

/** The globals the shell actually binds, plus the object shape if present. */
export interface NalarBrowserGlobals {
  nalarBrowserOpen?: NalarBrowserLike['open']
  nalarBrowserStatus?: NalarBrowserLike['status']
  nalarBrowserClose?: NalarBrowserLike['close']
  nalarBrowser?: NalarBrowserLike
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

/** Test seam: stub the object-shaped bridge; `null` means "no bridge at all". */
export function __setBrowserBridgeForTests(bridge: NalarBrowserLike | null): void {
  testOverride = bridge
}

/** Test seam: drop the override and go back to reading the real globals. */
export function __resetBrowserBridgeForTests(): void {
  testOverride = undefined
}

function globalsOf(): NalarBrowserGlobals[] {
  const root = globalThis as NalarBrowserGlobals & { window?: NalarBrowserGlobals }
  // `window` and `globalThis` are the same object in a page; a non-browser host
  // (or a test) may define only one of them.
  return root.window ? [root.window, root] : [root]
}

function bridgeFromGlobals(): NalarBrowserLike | null {
  for (const scope of globalsOf()) {
    if (scope.nalarBrowser) return scope.nalarBrowser
    const open = scope.nalarBrowserOpen
    const status = scope.nalarBrowserStatus
    const close = scope.nalarBrowserClose
    if (open && status && close) return { open, status, close }
  }
  return null
}

function readBridge(): NalarBrowserLike | null {
  if (testOverride !== undefined) return testOverride
  try {
    return bridgeFromGlobals()
  } catch {
    return null
  }
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
