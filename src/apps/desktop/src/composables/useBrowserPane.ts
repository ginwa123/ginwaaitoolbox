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
 * the numbers changed.
 *
 * A show is NEVER sent without numbers: the shell cannot place the pane, and
 * a rect-less show is refused. The tab body mounts in the same Vue flush as
 * the tab switch that reveals it, so `drive` awaits `nextTick()` and, if the
 * host still is not registered, holds the show until `setPaneHost` arrives
 * (browserBridge.ts's `showBrowserPane` is skipped entirely in that window).
 *
 * No polling, no intervals — it reacts to tab changes and layout events
 * only. Async replies are guarded two ways: a generation counter drops
 * replies from a drive that a newer drive has superseded, and the tab id/url
 * captured by the call is compared with the current value before assigning,
 * so a stale reply can never flip the state.
 *
 * Hides on unmount. Never throws.
 */
import { nextTick, onUnmounted, ref, watch, type Ref } from 'vue'

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

  // A show was requested while the host element was not registered yet; the
  // host's arrival retries it (see `drive`).
  let pendingShow = false
  // Bounded retries for that race: ~20 frames, then it waits for a tab change.
  let pendingRetries = 0

  /** Retry a held show on the next frame, at most ~20 times (no polling). */
  function schedulePendingRetry(): void {
    if (pendingRetries >= 20) return
    pendingRetries += 1
    try {
      const raf = globalThis.requestAnimationFrame
      if (typeof raf === 'function') {
        raf(() => {
          void drive()
        })
        return
      }
      globalThis.setTimeout(() => {
        void drive()
      }, 16)
    } catch {
      // No scheduler: the host registration path still retries.
    }
  }

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
      // The app's `<main>` starts at the WINDOW TOP: the 36px tab strip is its
      // first child. Reporting `<main>` as-is put the pane over the strip itself
      // (the pane's own chrome bar landed where the tabs should be — "why does it
      // take the tab's space"). Start BELOW the strip so tabs stay visible and
      // clickable; with the strip hidden/absent, fall back to `<main>`'s top.
      const strip = document.querySelector('[data-testid="tab-bar"]')
      const stripBox = strip ? strip.getBoundingClientRect() : null
      const top =
        stripBox && stripBox.height > 0 && stripBox.bottom <= box.bottom ? stripBox.bottom : box.top
      const height = Math.max(0, box.bottom - top)
      // A collapsed/hidden element measures 0: that is "no numbers yet", not a
      // rect. Reporting zeros is how the pane once covered the WHOLE app (tab
      // strip included, so the user could not switch back): the shell then has
      // nothing to allocate, and GtkOverlay's default is the full window.
      if (box.width < 1 || height < 1) return null
      // Integers: the shell works in whole CSS px, and rounding keeps a
      // sub-pixel layout jitter from looking like a move.
      return {
        x: Math.round(box.x),
        y: Math.round(top),
        width: Math.round(box.width),
        height: Math.round(height),
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
    if (el && pendingShow) {
      // The show that was held because there were no numbers can go out now.
      pendingShow = false
      void drive()
    }
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
      const tabGone = closedTabId !== '' && !tabsStore.tabs.some((tab) => tab.id === closedTabId)
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
    // The tab body mounts in the SAME Vue flush as the tab switch, so wait for
    // that flush (a bare microtask can beat it) and then, if the host still is
    // not registered, hold the show: the shell cannot place the pane without
    // numbers, and a 2-arg show is refused (the bug the human hit — the pane
    // stayed hidden with no error).
    await nextTick()
    if (myGeneration !== generation) return
    const rect = readRect()
    if (!rect) {
      // Keep `lastShownKey` unset so the host registration retries us, and retry
      // a bounded number of frames ourselves: the tab becoming active, the
      // layout giving `<main>` a box, and the pane being requested are three
      // async steps, so a single attempt can lose the race. Bounded, not a poll.
      lastShownKey = ''
      pendingShow = true
      schedulePendingRetry()
      return
    }
    pendingRetries = 0
    let visible = false
    try {
      const result = await showBrowserPane(target.tabId, target.url, rect)
      visible = result.visible === true
    } catch {
      visible = false
    }
    if (myGeneration !== generation) return
    // The tab may have moved on while the shell answered: only the reply
    // for the CURRENT tab may assign.
    const now = currentTarget()
    if (!now || now.tabId !== target.tabId || now.url !== target.url) return
    lastReported = visible ? rect : null
    paneVisible.value = visible
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
