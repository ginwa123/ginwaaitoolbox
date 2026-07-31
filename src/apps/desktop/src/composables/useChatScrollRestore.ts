import { onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue'

/**
 * Persists a vertically-scrolling container's `scrollTop` to
 * `localStorage` across component mounts, with a chat-specific
 * "near bottom" detection: if the saved position is within
 * `BOTTOM_THRESHOLD_PX` of the current `scrollHeight - clientHeight`,
 * `restore()` returns `null` so the caller falls through to
 * `scrollToBottom` instead of restoring a stale bottom edge (which
 * could be missing a few messages that arrived during the close
 * window).
 *
 * Why this exists:
 *   ChatView uses `:key="task-<id>"` in the surrounding
 *   `v-if/v-else-if` chain in AppLayout.vue. Vue 3 does NOT reuse
 *   component instances across keys at different DOM parents, so
 *   closing + reopening a chat (even the same chat) tears down and
 *   recreates ChatView. Without this composable, the new instance's
 *   scrollTop resets to 0 and the user loses their reading position.
 *
 *   The horizontal sibling `useKanbanScrollRestore` already solves
 *   this for the kanban board's columns row. This composable
 *   mirrors that pattern but for the chat's vertical scroll + the
 *   "near bottom" branch that the kanban does not need.
 *
 * Behavior:
 *   - **On mount**: reads the saved `scrollTop` from `localStorage`,
 *     waits for `scrollHeight > clientHeight` (the VirtualScroller's
 *     item measurement) or a 500 ms safety net, then attaches
 *     scroll + scrollend listeners. Exposes `restore()` (returns
 *     the saved value, or `null` if at-bottom / not set / not
 *     scrollable) and `restorePosition(value)` (clamps + applies).
 *   - **On `scrollend`** (fast path): writes the current `scrollTop`
 *     synchronously and cancels any pending debounced write.
 *   - **On `scroll`** (fallback path): schedules a debounced 250 ms
 *     write via `setTimeout`. Each new scroll event resets the
 *     timer so a 60-Hz scroll stream produces one write per
 *     scroll-stop.
 *   - **On unmount**: flushes any pending debounced write so a fast
 *     scroll → click → remount cycle doesn't lose the latest
 *     position, then removes the scroll + scrollend listeners.
 *
 * Storage key convention: caller composes the full key (e.g.
 * `chat-scroll-<taskId>`). The key is accepted as either a plain
 * `string` or a `Ref<string>` so it can be computed from props
 * reactively.
 *
 * Edge cases:
 *   - `localStorage` access is wrapped in `try/catch` so
 *     private-mode / quota-exceeded failures don't throw. The
 *     in-memory restore still works for the current session; only
 *     reload persistence is lost.
 *   - The composable swallows `localStorage.setItem` throws so
 *     private-mode browsers don't surface errors.
 *   - The composable does NOT save on programmatic scrolls
 *     differently from user scrolls (no flag). The `scrollTop`
 *     value is what the user sees regardless of who moved it; the
 *     "near bottom" branch in `restore()` covers the case where
 *     the user was at the bottom when they closed.
 *
 * NOT for vertical scrolling inside a `VirtualScroller`'s
 * `beginPreserve`/`endPreserve` window — that flow has its own
 * anchor-tracking mechanism. This composable is for the persistent
 * across-mount case.
 */

const BOTTOM_THRESHOLD_PX = 40

export function useChatScrollRestore(
  containerRef: Ref<HTMLElement | null>,
  storageKey: Ref<string> | string,
): {
  restore: () => number | null
  restorePosition: (value: number) => void
} {
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

  // Captured on mount so restore() can return it synchronously
  // after the parent awaits its own rAF × 2 (matching the existing
  // kanban composable's contract). Reads the raw saved value (no
  // "near bottom" gating here — that's restore()'s job, computed
  // against the CURRENT container geometry which is only known
  // after the VirtualScroller has measured items).
  let savedScrollTop: number | null = null
  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  const readSaved = (): number | null => {
    try {
      const raw = localStorage.getItem(keyRef.value)
      if (raw === null) return null
      const parsed = parseInt(raw, 10)
      return Number.isNaN(parsed) || parsed < 0 ? null : parsed
    } catch {
      return null
    }
  }

  const writeSaved = (value: number): void => {
    try {
      localStorage.setItem(keyRef.value, String(value))
    } catch {
      // private-mode / quota-exceeded — silent.
    }
  }

  const flushPending = (): void => {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer)
      debounceTimer = null
    }
    const el = containerRef.value
    if (el) writeSaved(el.scrollTop)
  }

  const scheduleWrite = (): void => {
    const el = containerRef.value
    if (!el) return
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      const e = containerRef.value
      if (e) writeSaved(e.scrollTop)
    }, 250)
  }

  const handleScroll = (): void => scheduleWrite()
  const handleScrollEnd = (): void => {
    flushPending()
    const el = containerRef.value
    if (el) writeSaved(el.scrollTop)
  }

  onMounted(async () => {
    // Read the saved value EARLY so restore() can return it after
    // the VirtualScroller has measured items. Chat items are
    // async-measured (the scroller does a 50-100ms measure pass
    // after mount), so we wait for `scrollHeight > clientHeight`
    // OR a 500 ms safety net, whichever comes first.
    savedScrollTop = readSaved()

    const waitForScrollable = async (): Promise<void> => {
      const start = Date.now()
      while (Date.now() - start < 500) {
        const el = containerRef.value
        if (el && el.scrollHeight > el.clientHeight) return
        await new Promise<void>((r) => setTimeout(r, 16))
      }
    }
    await waitForScrollable()

    const el = containerRef.value
    if (!el) return

    // Attach listeners regardless of saved value (user might scroll
    // from scratch — without a listener the first saved value
    // would never land in localStorage).
    el.addEventListener('scroll', handleScroll, { passive: true })
    if ('onscrollend' in el) {
      el.addEventListener('scrollend', handleScrollEnd, { passive: true })
    }
  })

  onBeforeUnmount(() => {
    flushPending()
    const el = containerRef.value
    if (el) {
      el.removeEventListener('scroll', handleScroll)
      el.removeEventListener('scrollend', handleScrollEnd)
    }
  })

  const restore = (): number | null => {
    if (savedScrollTop === null) return null
    if (savedScrollTop <= 0) return null
    const el = containerRef.value
    if (!el) return null
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return null
    // "Near bottom" branch: if the saved position is within
    // BOTTOM_THRESHOLD_PX of the max, treat as "still at bottom"
    // → let the caller fall through to scrollToBottom.
    if (savedScrollTop >= max - BOTTOM_THRESHOLD_PX) return null
    return savedScrollTop
  }

  const restorePosition = (value: number): void => {
    const el = containerRef.value
    if (!el) return
    const max = el.scrollHeight - el.clientHeight
    if (max <= 0) return
    const clamped = Math.max(0, Math.min(value, max))
    el.scrollTop = clamped
  }

  return { restore, restorePosition }
}