/**
 * The single owner of the in-app browser pane intent.
 *
 * Watches the active tab (id, kind, url) and the strip's `enabled` flag:
 *
 * - active tab is a `browser` tab with a non-empty `query.url` → ask the
 *   shell to show the pane for that tab; `paneVisible` follows the reply's
 *   `visible` (so `ok:false` / `available:false` leaves it false).
 * - anything else (chat tab, blank browser tab, strip disabled) → ask the
 *   shell to hide; `paneVisible` is false.
 *
 * No polling, no intervals — it reacts to tab changes only. Async replies
 * are guarded two ways: a generation counter drops replies from a drive that
 * a newer drive has superseded, and the tab id/url captured by the call is
 * compared with the current value before assigning, so a stale reply can
 * never flip the state. A repeat show for the same tab id + URL with no
 * hide in between is skipped (the shell ignores an unchanged URL, and
 * re-entering the tab must not reload the page).
 *
 * Hides on unmount. Never throws.
 */
import { onUnmounted, ref, watch, type Ref } from 'vue'

import { hideBrowserPane, showBrowserPane } from '../helpers/browserBridge'
import { useTabsStore } from '../stores/tabs'

export function useBrowserPane(): { paneVisible: Ref<boolean> } {
  const tabsStore = useTabsStore()
  const paneVisible = ref(false)

  // Generation of the latest drive: a reply from an older generation is
  // stale and must not assign. Bumped on every drive and on unmount.
  let generation = 0
  // The last (tabId, url) a show was requested for with no hide since.
  let lastShownKey = ''

  function currentTarget(): { tabId: string; url: string } | null {
    const active = tabsStore.activeTab
    const url = typeof active?.query.url === 'string' ? active.query.url : ''
    if (!tabsStore.enabled || !active || active.kind !== 'browser' || !url) return null
    return { tabId: active.id, url }
  }

  async function drive(): Promise<void> {
    const myGeneration = (generation += 1)
    const target = currentTarget()
    if (!target) {
      lastShownKey = ''
      try {
        await hideBrowserPane()
      } catch {
        // The bridge never throws, but the state update below must run anyway.
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
    let visible = false
    try {
      const result = await showBrowserPane(target.tabId, target.url)
      visible = result.visible === true
    } catch {
      visible = false
    }
    if (myGeneration !== generation) return
    // The tab may have moved on while the shell answered: only the reply
    // for the CURRENT tab may assign.
    const now = currentTarget()
    if (!now || now.tabId !== target.tabId || now.url !== target.url) return
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
    stop()
    paneVisible.value = false
    try {
      void hideBrowserPane()
    } catch {
      // Teardown must never throw.
    }
  })

  return { paneVisible }
}
