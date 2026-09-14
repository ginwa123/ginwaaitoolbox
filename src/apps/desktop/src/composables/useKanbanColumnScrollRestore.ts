import { onBeforeUnmount, ref, watch, type Ref } from 'vue'

/**
 * Persists a kanban column body's `scrollTop` to `localStorage` across
 * component mounts.
 *
 * Why this exists:
 *   A kanban column's card list is a `<VirtualScroller>` that owns a
 *   `overflow-y-auto` container. When the surrounding view unmounts — the
 *   tab strip switching from the board tab to a task-chat tab, or (with tab
 *   mode off) the chat replacing the board in the single view — Vue tears the
 *   column down, and the new instance starts at `scrollTop = 0`. The user
 *   loses their place in a long column (the `merged` / `in_review` columns
 *   routinely hold 50+ cards).
 *
 *   The horizontal sibling `useKanbanScrollRestore` already solves this for
 *   the columns ROW; `useChatScrollRestore` solves it for the chat's message
 *   list. This is the third case: vertical scrolling *inside* a column.
 *
 * Why a separate composable rather than a flag on `useKanbanScrollRestore`:
 *   - The element it targets appears LATE. The scroller is behind
 *     `v-if="cardsInColumn.length > 0"`, so on a cold load (tasks still
 *     arriving from the API) the container is null at the column's
 *     `onMounted`. Losing that moment would mean never attaching the
 *     listeners — the position would never be saved in the first place. So
 *     this one WATCHES the ref and wires up whenever the element shows up.
 *   - It restores unconditionally. `useChatScrollRestore` deliberately
 *     refuses to restore a position within 40 px of the bottom (a chat should
 *     land on the newest message); a kanban column scrolled to its last card
 *     should land exactly there.
 *
 * Behavior:
 *   - **On the ref becoming non-null**: attaches `scroll` (passive) and, when
 *     supported, `scrollend`; then restores after two `requestAnimationFrame`
 *     ticks (the scroller needs a paint to size its spacers before an absolute
 *     `scrollTop` can land anywhere but 0), clamping to
 *     `scrollHeight - clientHeight`.
 *   - **On `scroll`**: captures `scrollTop` synchronously (cheap) and schedules
 *     a debounced 250 ms write.
 *   - **On `scrollend`**: writes immediately, cancelling the pending write.
 *   - **On unmount**: flushes the last CAPTURED value — deliberately not a
 *     fresh `el.scrollTop` read. By the time the hook runs the element may
 *     already be detached, and a detached element reports `scrollTop = 0`,
 *     which would overwrite a perfectly good saved position with zero.
 *
 * Storage key convention: `kanban-col-scroll-<itemId>:<columnId>` (the caller
 * composes it). Accepted as a plain `string` or a `Ref<string>` so it can be
 * computed from props reactively.
 *
 * Edge cases:
 *   - `localStorage` access is wrapped in `try/catch`, so private-mode or
 *     quota-exceeded failures don't throw. Only cross-reload persistence is
 *     lost; the in-session value still restores if the element returns.
 *   - A single mounted element is wired exactly once; a remount (the column
 *     going empty and then non-empty again) wires the NEW element and restores
 *     the last saved position, which is the least surprising outcome.
 *   - Exposes nothing — purely side-effecting, so state is just
 *     `localStorage[key]` plus `element.scrollTop`.
 */
export function useKanbanColumnScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
): void {
  const initialKey = typeof storageKey === 'string' ? storageKey : storageKey.value
  const keyRef = ref(initialKey)

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
  let attachedEl: HTMLElement | null = null
  // Last value observed while the element was still attached. The unmount
  // flush writes THIS, never a fresh DOM read (see the doc comment).
  let lastKnownScrollTop: number | null = null

  const readSaved = (): number => {
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

  const write = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch {
      // private-mode / quota-exceeded — cross-reload persistence is lost,
      // the in-session restore still works. Silently ignore.
    }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    if (lastKnownScrollTop !== null) write(lastKnownScrollTop)
  }

  const handleScroll = (): void => {
    const el = containerRef.value
    if (!el) return
    lastKnownScrollTop = el.scrollTop
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      if (lastKnownScrollTop !== null) write(lastKnownScrollTop)
    }, 250)
  }

  const handleScrollEnd = (): void => {
    const el = containerRef.value
    if (el) lastKnownScrollTop = el.scrollTop
    flushPending()
  }

  const detach = (): void => {
    if (!attachedEl) return
    attachedEl.removeEventListener('scroll', handleScroll)
    attachedEl.removeEventListener('scrollend', handleScrollEnd)
    attachedEl = null
  }

  const restoreInto = async (el: HTMLElement): Promise<void> => {
    // Two frames so the VirtualScroller has sized its spacers — a single rAF
    // isn't enough for `scrollHeight` to reflect the measured items.
    await new Promise<void>((r) => requestAnimationFrame(() => r()))
    await new Promise<void>((r) => requestAnimationFrame(() => r()))
    if (containerRef.value !== el) return // swapped out while waiting

    const saved = readSaved()
    if (saved <= 0) return // nothing saved (first visit)
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return // not scrollable yet — nothing to restore
    const clamped = Math.min(saved, max)
    el.scrollTop = clamped
    lastKnownScrollTop = clamped
  }

  watch(
    containerRef,
    (el) => {
      if (!el) {
        detach()
        return
      }
      if (attachedEl === el) return
      detach()
      attachedEl = el

      el.addEventListener('scroll', handleScroll, { passive: true })
      // `scrollend` is the fast path (~100 ms after the user stops). Feature
      // detect with `in` — jsdom silently creates missing properties on
      // assignment, so a bare `if (el.onscrollend)` would lie.
      if ('onscrollend' in el) {
        el.addEventListener('scrollend', handleScrollEnd, { passive: true })
      }
      // else: the debounced `scroll` handler covers it.

      void restoreInto(el)
    },
    // `sync` on purpose: the template ref is assigned during mount, and a
    // post-flush watcher would leave a window where the element exists but no
    // `scroll` listener does yet — a scroll landing in that window would never
    // be saved. The value only ever changes on mount/unmount, so there is no
    // reactive-churn cost to listening synchronously.
    { immediate: true, flush: 'sync' },
  )

  onBeforeUnmount(() => {
    flushPending()
    detach()
  })
}
