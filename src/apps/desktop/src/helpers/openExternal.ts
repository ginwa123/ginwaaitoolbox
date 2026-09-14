/**
 * Open an `http(s)` URL in a browser tab (+ the in-app pane when the shell
 * offers it); anything else falls through to `window.open` unchanged.
 *
 * - Tab mode on, pane available: focus/create the browser tab (deduping by
 *   URL), re-apply the tab target to the URL, and show the pane — no window
 *   is spawned and `window.open` is never called.
 * - Tab mode on, pane unavailable: focus/create the browser tab and spawn a
 *   window only when none is alive for that tab (the invisible automatic
 *   fallback). When the bridge is unavailable, degrade to `window.open`.
 * - Tab mode off: no tab is created; the fixed bridge id `'external'` is
 *   used with the same re-use rule, else `window.open`.
 * - Non-http(s) (`blob:`, `javascript:`, `data:`, relative) → `window.open`
 *   unchanged.
 *
 * Never throws (synchronously or otherwise) — callers are click handlers.
 */
import router from '../router'
import { withTabParam } from './tabTarget'
import { isHttpUrl } from './browserUrl'
import {
  browserPaneAvailable,
  browserStatus,
  openBrowserWindow,
  showBrowserPane,
} from './browserBridge'
import { useTabsStore } from '../stores/tabs'

function systemOpen(url: string): void {
  try {
    window.open(url, '_blank', 'noopener')
  } catch {
    /* popup blocked / no window — never throw out of a click handler */
  }
}

async function run(url: string): Promise<void> {
  try {
    if (!isHttpUrl(url)) {
      systemOpen(url)
      return
    }
    const tabsStore = useTabsStore()
    if (!tabsStore.enabled) {
      const st = await browserStatus('external')
      if (!st.available) {
        systemOpen(url)
        return
      }
      if (!st.alive) await openBrowserWindow('external', url)
      return
    }
    const tab = tabsStore.openBrowserTab(url)
    try {
      await router.replace({ path: tab.path, query: withTabParam(tab.query, tab.id) })
    } catch {
      /* tests / early boot — the tab is still created and activated */
    }
    if (browserPaneAvailable()) {
      // The page lands in the browser tab with the pane — never a window.
      try {
        await showBrowserPane(tab.id, url)
      } catch {
        /* the bridge never throws; the tab is still created and activated */
      }
      return
    }
    const st = await browserStatus(tab.id)
    if (!st.available) {
      systemOpen(url)
      return
    }
    if (!st.alive) await openBrowserWindow(tab.id, url)
  } catch {
    /* never throw out of a click handler */
  }
}

export function openExternal(url: string): void {
  void run(url)
}
