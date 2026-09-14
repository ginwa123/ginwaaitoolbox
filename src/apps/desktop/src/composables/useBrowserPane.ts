/**
 * The single owner of the in-app browser pane intent.
 *
 * Watches the active tab (id, kind, url) and the strip's `enabled` flag:
 *
 * - active tab is a `browser` tab with a non-empty `query.url` → ask the
 *   shell to show the pane for that tab; `paneVisible` follows the reply's
 *   `visible` (so `ok:false` / `available:false` leaves it false).
 * - anything else (chat tab, blank browser tab, strip disabled) → ask the
 *   shell to hide; `paneVisible` is false. When the previously shown tab is
 *   gone from the store it was CLOSED (the store's close path already
 *   destroyed the view), so no hide is sent for it.
 *
 * Rect reporting: the shell overlays the page at window coordinates the SPA
 * reports — the SPA viewport IS the window, so the browser tab body's
 * `getBoundingClientRect()` already is in window coordinates. The tab body
 * registers itself via `setPaneHost`; the rect travels on the first show (as
 * `nalarBrowserPaneShow` args) and on later layout changes through a
 * `ResizeObserver` on that element plus a window `resize` listener, coalesced
 * with `requestAnimationFrame` and sent via `nalarBrowserPaneRect` only when
 * the numbers changed. No polling, no intervals.
 *
 * No polling, no intervals — it reacts to tab changes and layout events
 * only. Async replies are guarded two ways: a generation counter drops
 * replies from a drive that a newer drive has superseded, and the tab id/url
 * captured by the call is compared with the current value before assigning,
 * so a stale reply can never flip the state. A repeat show for the same tab
 * id + URL with no hide in between is skipped (the shell ignores an
 * unchanged URL, and re-entering the tab must not reload the page).
 *
 * Hides on unmount. Never throws.
 */
import { onUnmounted, ref, watch, type Ref } from 'vue'

import {
  hideBrowserPane,
  rectBrowserPane,
  showBrowserPane,
  type BrowserPaneRect,
} from '../helpers/browserBridge'
import { useTabsStore } from '../stores/tabs'

export interface BrowserPaneApi {
  paneVisible: Ref<boolean>
  setPaneHost: (el: Element | null) => void
}

/** Injection key AppLayout provides and BrowserTabView consumes. */
export const BrowserPaneKey: unique symbol = Symbol('browserPane')

export function useBrowserPane(): BrowserPaneApi {
  const tabsStore = useTabsStore()
  const paneVisible = ref(false)

  // Generation of the latest drive: a reply from an older generation is
  // stale and must not assign. Bumped on every drive and on unmount.
  let generation = 0
  // The last (tabId, url) a show was requested for with no hide since.
  let lastShownKey = ''
  // The tab id of that show. When it is gone from the store the tab was
  // closed (not merely left) — the store destroyed the view, so the
  // trailing drive skips the hide.
  let lastShownTabId = ''
  // The tab body element the shell should cover. Registered by the tab
  // body; null until it mounts (or when there is no browser tab body).
  let host: Element | null = null
  // The last rect reported to the shell (via show args or rectBrowserPane).
  // Null until the pane is up with known numbers.
  let lastReported: BrowserPaneRect | null = null
  let observer: ResizeObserver | null = null
  let rafId = 0
  let resizeListening = false

  function currentTarget(): { tabId: string; url: string } | null {
    const active = tabsStore.activeTab
    const url = typeof active?.query.url === 'string' ? active.query.url : ''
    if (!tabsStore.enabled || !active || active.kind !== 'browser' || !url) return null
    return { tabId: active.id, url }
  }

  function readRect(): BrowserPaneRect | null {
    const el = host
    if (!el) return null
    try {
      const box = el.getBoundingClientRect()
      // Integers: the shell works in whole CSS px, and rounding keeps a
      // sub-pixel layout jitter from looking like a move.
      return {
        x: Math.round(box.x),
        y: Math.round(box.y),
        width: Math.round(box.width),
        height: Math.round(box.height),
      }
    } catch {
      return null
    }
  }

  function sameRect(a: BrowserPaneRect, b: BrowserPaneRect): boolean {
    return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height
  }

  function scheduleRectSync(): void {
    if (rafId !== 0) return
    try {
      const raf = globalThis.requestAnimationFrame
      if (typeof raf !== 'function') {
        // No frame scheduler (an env without rAF): sync inline. Still no
        // polling — this only runs on layout events and host handoffs, and
        // syncRect itself skips unchanged numbers.
        void syncRect()
        return
      }
      rafId = raf(() => {
        rafId = 0
        void syncRect()
      })
    } catch {
      rafId = 0
    }
  }

  async function syncRect(): Promise<void> {
    if (!paneVisible.value || !lastShownKey) return
    const rect = readRect()
    if (!rect) return
    if (lastReported && sameRect(lastReported, rect)) return
    lastReported = rect
    try {
      await rectBrowserPane(rect)
    } catch {
      // The bridge never throws, but the numbers are already recorded.
    }
  }

  function onWindowResize(): void {
    scheduleRectSync()
  }

  /**
   * Register (or release with null) the tab body element the shell covers.
   * Attaches the ResizeObserver + window resize listener on first host and
   * schedules a sync — the pane may already be up with stale numbers.
   * Never throws: a ref handoff must not break rendering.
   */
  function setPaneHost(el: Element | null): void {
    host = el
    try {
      if (observer) {
        observer.disconnect()
        observer = null
      }
      if (el && typeof ResizeObserver !== 'undefined') {
        observer = new ResizeObserver(() => {
          scheduleRectSync()
        })
        observer.observe(el)
      }
    } catch {
      observer = null
    }
    try {
      if (el && !resizeListening && typeof window !== 'undefined') {
        window.addEventListener('resize', onWindowResize)
        resizeListening = true
      }
    } catch {
      // Teardown below still runs; the observer path already covers layout.
    }
    scheduleRectSync()
  }

  async function drive(): Promise<void> {
    const myGeneration = (generation += 1)
    const target = currentTarget()
    if (!target) {
      const closedTabId = lastShownTabId
      lastShownKey = ''
      lastShownTabId = ''
      lastReported = null
      const tabGone =
        closedTabId !== '' && !tabsStore.tabs.some((tab) => tab.id === closedTabId)
      if (!tabGone) {
        try {
          await hideBrowserPane()
        } catch {
          // The bridge never throws, but the state update below must run anyway.
        }
      }
      if (myGeneration !== generation) return
      paneVisible.value = false
      return
    }
    const key = `${target.tabId}\n${target.url}`
    if (key === lastShownKey) {
      // Same tab, same URL, no hide since — the pane already shows it.
      if (myGeneration !== generation) return
      return
    }
    lastShownKey = key
    lastShownTabId = target.tabId
    // Let the tab body register its host (it mounts in the same pass as the
    // layout) before the first show, so the show carries the real rect.
    await Promise.resolve()
    if (myGeneration !== generation) return
    const rect = readRect()
    let visible = false
    try {
      const result = await showBrowserPane(target.tabId, target.url, rect ?? undefined)
      visible = result.visible === true
    } catch {
      visible = false
    }
    if (myGeneration !== generation) return
    // The tab may have moved on while the shell answered: only the reply
    // for the CURRENT tab may assign.
    const now = currentTarget()
    if (!now || now.tabId !== target.tabId || now.url !== target.url) return
    lastReported = visible && rect ? rect : null
    paneVisible.value = visible
    // The host arrived mid-flight (show went out without numbers while the
    // pane is now up): report them now rather than waiting for a resize.
    if (visible && !rect) scheduleRectSync()
  }

  const stop = watch(
    () => {
      const active = tabsStore.activeTab
      const url = typeof active?.query.url === 'string' ? active.query.url : ''
      return [tabsStore.enabled, active?.id, active?.kind, url] as const
    },
    () => {
      void drive()
    },
    { immediate: true },
  )

  onUnmounted(() => {
    generation += 1
    lastShownKey = ''
    lastShownTabId = ''
    lastReported = null
    stop()
    if (rafId !== 0) {
      try {
        globalThis.cancelAnimationFrame(rafId)
      } catch {
        // Teardown must never throw.
      }
      rafId = 0
    }
    if (observer) {
      try {
        observer.disconnect()
      } catch {
        // Teardown must never throw.
      }
      observer = null
    }
    if (resizeListening) {
      try {
        window.removeEventListener('resize', onWindowResize)
      } catch {
        // Teardown must never throw.
      }
      resizeListening = false
    }
    host = null
    paneVisible.value = false
    try {
      void hideBrowserPane()
    } catch {
      // Teardown must never throw.
    }
  })

  return { paneVisible, setPaneHost }
}
