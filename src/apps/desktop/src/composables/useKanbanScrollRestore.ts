import { onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue'

/**
 * Persists a horizontally-scrolling container's `scrollLeft` to
 * `localStorage` across component mounts.
 *
 * Use for horizontally-scrolled boards (e.g. the kanban columns
 * row) whose component may unmount and remount when the surrounding
 * layout flips — e.g. the kanban toggling between a full-bleed
 * standalone branch and a 3-column "kanban | chat" branch in
 * `AppLayout.vue`. Vue 3 does NOT reuse the component instance
 * across v-else-if branches at different DOM parents, so without
 * this composable the remounted container starts at `scrollLeft = 0`
 * and the user loses their scroll context.
 *
 * Behavior:
 *   - **On mount**: reads the saved `scrollLeft` from `localStorage`,
 *     awaits two `requestAnimationFrame` ticks so the columns have
 *     widths, then applies `scrollLeft = min(saved, scrollWidth -
 *     clientWidth)`. Skips when the saved value is 0 or the
 *     container has nothing to scroll (max <= 0).
 *   - **On `scrollend`** (fast path, ~100 ms after the user stops
 *     scrolling — supported in all modern browsers including the
 *     nalar Electron 27+ runtime): writes the current `scrollLeft`
 *     synchronously and cancels any pending debounced write.
 *   - **On `scroll`** (fallback path for environments without
 *     `scrollend`): schedules a debounced 250 ms write via
 *     `setTimeout`. Each new scroll event resets the timer so a
 *     60-Hz scroll stream produces one write per scroll-stop.
 *   - **On unmount**: flushes any pending debounced write so a
 *     fast scroll → click → remount cycle doesn't lose the latest
 *     position, then removes the scroll/scrollend listeners.
 *
 * Storage key convention: `kanban-scroll-<itemId>` (caller composes
 * with the item id). The key is accepted as either a plain `string`
 * or a `Ref<string>` so it can be computed from props reactively.
 *
 * Edge cases:
 *   - `localStorage` access is wrapped in `try/catch` so private-mode
 *     or quota-exceeded failures don't throw. The in-memory restore
 *     still works for the current session; only reload persistence
 *     is lost.
 *   - The composable exposes nothing — it's purely side-effecting
 *     (writes to `localStorage` + sets `container.scrollLeft`).
 *     Easy to test: state is `localStorage[key]` + `element.scrollLeft`.
 *
 * NOT for vertical scrolling inside a `VirtualScroller` — that
 * already has its own `beginPreserve` / `endPreserve` mechanism
 * (`helpers/VirtualScroller.vue`). This composable is for plain
 * overflow-scrolled regions that may unmount.
 */
export function useKanbanScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
): void {
  // Make a reactive local ref so a dynamic storage key (computed
  // from props) updates without re-registering listeners.
  const keyRef = ref(typeof storageKey === 'string' ? storageKey : '')

  if (typeof storageKey !== 'string') {
    watch(
      storageKey,
      (v) => {
        keyRef.value = v
      },
      { immediate: true },
    )
  }

  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  const readSavedScrollLeft = (): number => {
    try {
      const raw = localStorage.getItem(keyRef.value)
      if (raw === null) return 0
      const parsed = parseInt(raw, 10)
      return Number.isNaN(parsed) || parsed < 0 ? 0 : parsed
    } catch {
      // localStorage may throw in disabled / private-mode.
      return 0
    }
  }

  const writeScrollLeft = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch {
      // localStorage may throw in disabled / private-mode /
      // quota-exceeded scenarios. The in-memory restore on the
      // next mount still works; only cross-reload persistence
      // is lost. Silently ignore.
    }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    const el = containerRef.value
    if (el) writeScrollLeft(el.scrollLeft)
  }

  const scheduleWrite = (): void => {
    const el = containerRef.value
    if (!el) return
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      const e = containerRef.value
      if (e) writeScrollLeft(e.scrollLeft)
    }, 250)
  }

  const handleScroll = (): void => scheduleWrite()
  const handleScrollEnd = (): void => {
    // scrollend is the fast path — cancel the debounced write and
    // commit immediately.
    flushPending()
    const el = containerRef.value
    if (el) writeScrollLeft(el.scrollLeft)
  }

  onMounted(async () => {
    // Wait two animation frames so the columns have widths. A
    // single rAF isn't enough: Vue mounts the DOM, then React-style
    // effects (useLayoutEffect-like) may still settle, and the
    // browser may need a second frame to fully compute
    // scrollWidth. Two is the minimum that consistently produces
    // correct geometry in jsdom-less browsers (Chrome / Firefox).
    await new Promise<void>((r) => requestAnimationFrame(() => r()))
    await new Promise<void>((r) => requestAnimationFrame(() => r()))

    const el = containerRef.value
    if (!el) return

    // Attach listeners FIRST (regardless of whether there's a
    // saved value to restore). The user might scroll from
    // scratch — without an attached listener we'd never
    // establish the first saved value.
    //
    // Passive scroll listener for the debounced fallback write.
    el.addEventListener('scroll', handleScroll, { passive: true })

    // scrollend is the fast path. Feature-detect by trying to set
    // `onscrollend` (returns `undefined` if the property doesn't
    // exist; assigning to a missing property silently creates it
    // in jsdom, so we additionally check `'onscrollend' in el` to
    // be safe in test environments).
    const supportsScrollEnd =
      'onscrollend' in el ||
      typeof (el as unknown as { onscrollend?: unknown }).onscrollend !==
        'undefined'
    if (supportsScrollEnd) {
      el.addEventListener('scrollend', handleScrollEnd, { passive: true })
    }
    // else: the debounced `scroll` handler covers this case. Each
    // scroll event schedules a 250 ms write, so even without
    // scrollend the position is saved ~250 ms after the user
    // stops scrolling.

    // Now restore from the previous session's saved scrollLeft.
    // Clamp to (scrollWidth - clientWidth) — the new container
    // may be narrower than the last session's, e.g. when the
    // kanban toggled from full-bleed to the 3-column layout.
    const saved = readSavedScrollLeft()
    if (saved <= 0) return // nothing to restore (initial state)

    const max = el.scrollWidth - el.clientWidth
    if (max <= 0) return // column row fits in viewport — nothing to scroll
    const clamped = Math.min(saved, max)
    el.scrollLeft = clamped
  })

  onBeforeUnmount(() => {
    flushPending()
    const el = containerRef.value
    if (!el) return
    el.removeEventListener('scroll', handleScroll)
    el.removeEventListener('scrollend', handleScrollEnd)
  })
}