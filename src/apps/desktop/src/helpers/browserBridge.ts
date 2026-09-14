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

/**
 * The pane globals the shell installs on the APP window (Linux only for now):
 *
 *   window.nalarBrowserPaneShow(tabId, url, x, y, width, height) → { ok, visible, rect, error? }
 *   window.nalarBrowserPaneRect(x, y, width, height)             → { ok, visible, rect }
 *   window.nalarBrowserPaneHide()                                → { ok, visible, rect }
 *   window.nalarBrowserPaneClose()                               → { ok, visible, rect }
 *   window.nalarBrowserPaneStatus()                              → { supported, visible, uri_len, rect }
 *
 * x/y/width/height are window coordinates in CSS px (1:1 with GTK logical
 * px); the shell clamps them. Show places the pane at the reported rect;
 * Rect moves/resizes it without navigating; Hide leaves the tab (the page
 * SURVIVES); Close destroys the view when the tab is closed (nothing keeps
 * running in the background).
 *
 * Same flat-name rule as the window triple above: `window[name]` is written
 * verbatim by the vendored glue, so these are separate globals, not a
 * namespace. Off Linux / in a plain-browser dev session / in an older shell
 * (which only has the show/hide/status triple) the newer ones are
 * `undefined` — a normal state the UI falls back from, never throws.
 */
export interface BrowserPaneRect {
  x: number
  y: number
  width: number
  height: number
}

export interface NalarBrowserPaneLike {
  show: (
    tabId: string,
    url: string,
    x?: number,
    y?: number,
    width?: number,
    height?: number,
  ) => Promise<{ ok: boolean; visible: boolean; error?: string }>
  hide: () => Promise<{ ok: boolean; visible: boolean }>
  status: () => Promise<{ supported: boolean; visible: boolean }>
  /** Move/resize only, no navigation. Absent on older shells — optional. */
  rect?: (x: number, y: number, width: number, height: number) => Promise<{
    ok: boolean
    visible: boolean
  }>
  /** Destroy the view (tab closed). Absent on older shells — optional. */
  close?: () => Promise<{ ok: boolean; visible: boolean }>
}

/** The globals the shell actually binds, plus the object shape if present. */
export interface NalarBrowserGlobals {
  nalarBrowserOpen?: NalarBrowserLike['open']
  nalarBrowserStatus?: NalarBrowserLike['status']
  nalarBrowserClose?: NalarBrowserLike['close']
  nalarBrowser?: NalarBrowserLike
  nalarBrowserPaneShow?: NalarBrowserPaneLike['show']
  nalarBrowserPaneHide?: NalarBrowserPaneLike['hide']
  nalarBrowserPaneStatus?: NalarBrowserPaneLike['status']
  nalarBrowserPaneRect?: NalarBrowserPaneLike['rect']
  nalarBrowserPaneClose?: NalarBrowserPaneLike['close']
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

export interface BrowserPaneShowResult {
  available: boolean
  ok: boolean
  visible: boolean
  error?: string
}

export interface BrowserPaneHideResult {
  available: boolean
  ok: boolean
  visible: boolean
}

export interface BrowserPaneStatus {
  available: boolean
  supported: boolean
  visible: boolean
}

export interface BrowserPaneRectResult {
  available: boolean
  ok: boolean
}

export interface BrowserPaneCloseResult {
  available: boolean
  ok: boolean
}

let testOverride: NalarBrowserLike | null | undefined
let paneTestOverride: NalarBrowserPaneLike | null | undefined

/** Test seam: stub the object-shaped bridge; `null` means "no bridge at all". */
export function __setBrowserBridgeForTests(bridge: NalarBrowserLike | null): void {
  testOverride = bridge
}

/** Test seam: drop the override and go back to reading the real globals. */
export function __resetBrowserBridgeForTests(): void {
  testOverride = undefined
}

/**
 * Test seam: stub the pane triple; `null` means "no pane at all".
 *
 * Independent from the window-bridge override: a shell can have the process
 * bridge without the pane (macOS today), so each half is stubbed separately.
 */
export function __setBrowserPaneForTests(pane: NalarBrowserPaneLike | null): void {
  paneTestOverride = pane
}

/** Test seam: drop the pane override and go back to reading the real globals. */
export function __resetBrowserPaneForTests(): void {
  paneTestOverride = undefined
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

function paneFromGlobals(): NalarBrowserPaneLike | null {
  for (const scope of globalsOf()) {
    const show = scope.nalarBrowserPaneShow
    const hide = scope.nalarBrowserPaneHide
    const status = scope.nalarBrowserPaneStatus
    // Presence is the show/hide/status triple: an older shell has exactly
    // that, and still counts as a pane (rect/close degrade below).
    if (show && hide && status) {
      const pane: NalarBrowserPaneLike = { show, hide, status }
      if (scope.nalarBrowserPaneRect) pane.rect = scope.nalarBrowserPaneRect
      if (scope.nalarBrowserPaneClose) pane.close = scope.nalarBrowserPaneClose
      return pane
    }
  }
  return null
}

function readPane(): NalarBrowserPaneLike | null {
  if (paneTestOverride !== undefined) return paneTestOverride
  try {
    return paneFromGlobals()
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

export function browserPaneAvailable(): boolean {
  return readPane() !== null
}

export async function showBrowserPane(
  tabId: string,
  url: string,
  rect?: BrowserPaneRect,
): Promise<BrowserPaneShowResult> {
  const pane = readPane()
  if (!pane) return { available: false, ok: false, visible: false }
  try {
    // The rect travels only when the caller has one: older stubs (and the
    // older shell) take exactly (tabId, url), and the shell clamps whatever
    // coordinates it receives.
    const result = rect
      ? await pane.show(tabId, url, rect.x, rect.y, rect.width, rect.height)
      : await pane.show(tabId, url)
    return {
      available: true,
      ok: result.ok === true,
      visible: result.visible === true,
      error: result.error,
    }
  } catch {
    return { available: true, ok: false, visible: false }
  }
}

export async function hideBrowserPane(): Promise<BrowserPaneHideResult> {
  const pane = readPane()
  if (!pane) return { available: false, ok: false, visible: false }
  try {
    const result = await pane.hide()
    return { available: true, ok: result.ok === true, visible: result.visible === true }
  } catch {
    return { available: true, ok: false, visible: false }
  }
}

/**
 * Move/resize the pane without navigating. Degrades to
 * `{ available:false }` with no pane at all, and to `{ available:true,
 * ok:false }` on an older shell whose triple has no rect global — either
 * way it never throws.
 */
export async function rectBrowserPane(rect: BrowserPaneRect): Promise<BrowserPaneRectResult> {
  const pane = readPane()
  if (!pane) return { available: false, ok: false }
  if (!pane.rect) return { available: true, ok: false }
  try {
    const result = await pane.rect(rect.x, rect.y, rect.width, rect.height)
    return { available: true, ok: result.ok === true }
  } catch {
    return { available: true, ok: false }
  }
}

/**
 * Destroy the pane view (the tab was closed — nothing may keep running).
 * Same degrade contract as rectBrowserPane: absent pane, or an older shell
 * without the close global, resolves to ok:false and never throws.
 */
export async function closeBrowserPane(): Promise<BrowserPaneCloseResult> {
  const pane = readPane()
  if (!pane) return { available: false, ok: false }
  if (!pane.close) return { available: true, ok: false }
  try {
    const result = await pane.close()
    return { available: true, ok: result.ok === true }
  } catch {
    return { available: true, ok: false }
  }
}

export async function browserPaneStatus(): Promise<BrowserPaneStatus> {
  const pane = readPane()
  if (!pane) return { available: false, supported: false, visible: false }
  try {
    const result = await pane.status()
    // `supported:false` is reported honestly: a shell that answers at all but
    // does not support the pane (a platform before its patch) is "present but
    // unsupported", not absent.
    return {
      available: true,
      supported: result.supported === true,
      visible: result.visible === true,
    }
  } catch {
    return { available: true, supported: false, visible: false }
  }
}
