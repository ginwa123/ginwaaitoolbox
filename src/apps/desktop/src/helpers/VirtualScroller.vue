<script setup lang="ts" generic="T">
import { ref, computed, onMounted, onUnmounted, nextTick, watch } from 'vue'

import { computeLoadMoreThreshold } from './virtualScrollerThreshold'

const props = withDefaults(
  defineProps<{
    /**
     * The full list of items to virtualize. The scroller only mounts the
     * items currently visible in the viewport (plus a small buffer above
     * and below), so passing thousands of items is fine — the DOM stays
     * small. Each item is rendered via the default scoped slot, receiving
     * `{ item, index }` so you can render whatever you need.
     *
     * Indexing is significant: the scroller uses the item's index in this
     * array as its key and as the height-measurement key. **Avoid splicing
     * items into the middle of the array at runtime** unless you also call
     * `beginPreserve`/`endPreserve` to keep the visible range stable.
     * Appending to the end (e.g. chat messages, log lines) and prepending
     * to the start (e.g. paginated history, with `beginPreserve`/
     * `endPreserve`) are both well-supported.
     */
    items: T[]
    /**
     * Total number of items that exist on the server / in the source of
     * truth, if known. Used to decide whether `loadMore` should still
     * fire when the user nears the edge.
     *
     * - Default `0` means "unknown / unbounded" — `loadMore` is allowed
     *   to fire whenever the user is within `loadMoreThreshold` of the
     *   load edge. The parent is responsible for stopping it (e.g. by
     *   checking a `hasMore` flag in its handler).
     * - Set this to the real total when you know it (e.g. `data.total`
     *   from your API) to let the scroller stop firing `loadMore` on
     *   its own once `items.length >= totalCount`.
     */
    totalCount?: number
    /**
     * Number of extra items to render **on each side** (above AND below)
     * the visible viewport. So `buffer=20` means 20 items above + 20
     * items below + the visible items themselves.
     *
     * Worked example with `defaultItemHeight=200`, `containerHeight=800`:
     *   - buffer=0  → 4 items in the DOM  (4 visible, no overscan)
     *   - buffer=5  → 14 items in the DOM (4 visible + 5 above + 5 below)
     *   - buffer=20 → 44 items in the DOM (4 visible + 20 above + 20 below)
     *
     * A larger buffer means smoother scrolling (fewer "pop in" moments
     * as the user scrolls) at the cost of more DOM nodes. The default
     * of 5 is a good balance for most text/list UIs. For tall items
     * (chat bubbles, cards with images) you may want to lower this;
     * for short uniform items (log lines, search results) you can
     * raise it.
     *
     * To read the live rendered count from the parent, use the
     * `renderedCount` exposed on the component instance (see
     * `defineExpose` below) or the `scrollInfo` object.
     */
    buffer?: number
    /**
     * Estimated height in pixels for an item whose real height hasn't
     * been measured yet. The scroller uses this to size the top/bottom
     * spacers before measurement completes, which affects the initial
     * `scrollHeight` and therefore the initial scroll position.
     *
     * Pick a value close to your **median** real item height:
     * - Too small → the initial render undershoots `scrollHeight`, so
     *   after measurement the user appears scrolled up by the difference
     *   (the spacers grew). Usually fine if you "stick to bottom" — see
     *   the chat viewer for an example using a MutationObserver on the
     *   spacers to re-stick after measurement.
     * - Too large → the initial render overshoots `scrollHeight`; the
     *   browser clamps `scrollTop` to the real bottom, so the user
     *   lands correctly but the spacers briefly show extra blank space
     *   that snaps away.
     *
     * Default 100px suits most text rows. Chat bubbles with avatars and
     * markdown often want 150-250px.
     */
    defaultItemHeight?: number
    /**
     * Distance in pixels from the load edge at which the scroller emits
     * `loadMore`. If `loadMoreAtTop` is `true` (paginating older items
     * by prepending), this is measured from the top of the scrollable
     * area; otherwise from the bottom.
     *
     * Acts as the **absolute floor** for the effective threshold. The
     * actual threshold used in the `loadMore` check is
     * `max(loadMoreThreshold, containerHeight * loadMoreThresholdRatio)`,
     * so the scroller fires `loadMore` when the user is within EITHER
     * the floor OR the proportional distance of the load edge —
     * whichever is larger.
     *
     * Default 200px keeps the trigger safe on small viewports and during
     * the 0×0 initial-mount flicker. Raise it (e.g. 400-600px) for very
     * slow APIs that need a longer fetch head-start.
     *
     * The emit is debounced (~200ms) and is suppressed while
     * `beginPreserve`/`endPreserve` is in flight, so a single
     * scroll-to-edge gesture won't fire `loadMore` multiple times.
     */
    loadMoreThreshold?: number
    /**
     * Proportion of the container's visible height (`clientHeight`) that
     * the effective threshold should track. Combined with
     * `loadMoreThreshold` as `effective = max(loadMoreThreshold,
     * containerHeight * loadMoreThresholdRatio)`.
     *
     * Default `0.5` means "fire `loadMore` when the user is within half
     * a screen of the load edge" — the same heuristic used by Slack,
     * Discord, and iMessage. On a 1000 px viewport this gives a 500 px
     * effective threshold; on a 600 px viewport, 300 px. The absolute
     * `loadMoreThreshold` floor (200 px) protects tiny viewports where
     * the proportional value would be smaller.
     *
     * Set to `0` to opt out of the proportional mode entirely
     * (floor only). The threshold is computed in
     * `computeLoadMoreThreshold` (a pure helper, unit-tested).
     */
    loadMoreThresholdRatio?: number
    /**
     * If `true`, the scroller emits `loadMore` when the user scrolls
     * within `loadMoreThreshold` of the **top** — use this when you're
     * prepending older items (chat history, activity feeds, logs).
     * `loadMoreAtTop` should be paired with `beginPreserve`/`endPreserve`
     * in the parent so the user's scroll position doesn't jump when the
     * new items are inserted at index 0.
     *
     * If `false` (the default), the scroller emits `loadMore` when the
     * user scrolls within `loadMoreThreshold` of the **bottom** — use
     * this for "load more on demand" patterns where new content is
     * appended past the visible area.
     */
    loadMoreAtTop?: boolean
  }>(),
  {
    totalCount: 0,
    buffer: 5,
    defaultItemHeight: 100,
    loadMoreThreshold: 200,
    loadMoreThresholdRatio: 0.5,
    loadMoreAtTop: false,
  },
)

const emit = defineEmits<{
  loadMore: []
  /**
   * Fired when one of the scroller's internal guards prevented
   * `loadMore` from being emitted — i.e. the user WAS within the
   * load edge but the scroller still chose not to emit (because
   * `isPreservingScroll`, `!hasMore`, `!isScrollable`, or
   * `items.length === 0`). Lets the parent log "user reached top,
   * but lazy load was blocked by X" so the "why didn't it load?"
   * question is answerable from the logs.
   *
   * The `guard` payload is a short identifier — see the emit sites
   * in `onScroll` below for the full list. NOT emitted when the
   * user simply isn't near the edge (that's normal scrolling, not
   * a suppression).
   */
  loadMoreSuppressed: [guard: string]
  /**
   * Fired on every scroll event. `target` is the actual DOM element
   * that dispatched the event — guaranteed non-null by the browser
   * for the lifetime of the event handler. Parents should prefer
   * `target` over walking the component's `containerRef` ref chain:
   * the ref chain is null during mount/remount races (chat switch,
   * initial mount before Vue binds the template ref, v-if toggle),
   * but `target` is always live for the duration of the handler.
   *
   * The component-level `containerRef` is still exposed for the
   * initial-load, scroll-to-bottom, and other controlled paths that
   * don't have an event to extract the element from.
   */
  scroll: [scrollTop: number, direction: 'up' | 'down', target: HTMLElement]
  /**
   * Fired whenever the scroller's `isScrollable` computed value
   * CHANGES (not on every re-evaluation — only when the boolean
   * flips from one value to the other). The parent uses this to
   * show/hide UI affordances (e.g. a "Load more messages" button)
   * that only make sense when the user has no other way to reach
   * older content. The event-based pattern is used instead of
   * exposing `isScrollable` via the template ref because
   * component-instance proxies do not establish reactive
   * dependencies on inner ref values when accessed through
   * `childRef.value.someRef.value` — the parent would not
   * re-render on changes. With this event, the parent maintains
   * a plain `ref<boolean>` that the template can react to.
   */
  scrollabilityChange: [scrollable: boolean]
}>()

const containerRef = ref<HTMLElement | null>(null)
const scrollTop = ref(0)
const lastScrollTop = ref(0)
const containerHeight = ref(0)
const itemHeights = ref<Map<number, number>>(new Map())
const accumulatedHeights = ref<number[]>([0])
const isPreservingScroll = ref(false)
const forceRenderUpTo = ref(-1)

/**
 * Whether the container's content currently overflows its visible area
 * (i.e. `scrollHeight > clientHeight`). Exposed to the parent so it
 * can decide whether to show UI affordances (e.g. a "Load more"
 * button) that only make sense when the user can't trigger the
 * scroll-driven `loadMore` event because the container has no
 * scrollbar.
 *
 * Implemented as a `computed` (not a `ref` populated by a DOM read)
 * so it stays in sync with the underlying reactive data. The previous
 * ref-based version read `containerRef.value.scrollHeight` from a
 * `ResizeObserver` / `measureItems` / mount-time trigger, but those
 * triggers do NOT fire when the content inside the container grows
 * (e.g. during streaming, after pagination, or on first item
 * measurement) — only when the *observed element itself* resizes.
 * Result: `isScrollable` would get stuck at its initial-mount value
 * (typically `false` from the 0×0 flicker), and the parent's "Load
 * more" button would never hide even when the chat became scrollable.
 * See docs/plans/2026-06-04-chat-lazy-load-button.md §4.3.
 *
 * The estimate uses `defaultItemHeight` for unmeasured items, so it
 * can be slightly off in the milliseconds before `measureItems` runs
 * — that's a soft UX hint, not a precise measurement, and an
 * over-estimate is harmless (button hides for a frame, then re-shows
 * once measurement catches up). An under-estimate could hide the
 * button when the user needs it; in practice the default of 200px
 * matches most chat bubbles closely.
 */
const isScrollable = computed(() => {
  const totalContentHeight = accumulatedHeights.value[props.items.length] ?? 0
  return totalContentHeight > containerHeight.value
})

/**
 * Effective distance (in px) from the load edge at which the scroller
 * emits `loadMore`. Recomputed whenever the container's height changes
 * (via the `containerHeight` ref, which is updated in `onScroll`).
 *
 * Combines the absolute `loadMoreThreshold` floor (default 200 px) with
 * the proportional `loadMoreThresholdRatio` (default 0.5, i.e. half a
 * screen). Exposed on the instance so the parent can read it for
 * logging ("effective threshold was 500 px when loadMore fired") and
 * so the integration tests can assert against a single value rather
 * than duplicating the max() logic.
 */
const effectiveLoadMoreThreshold = computed(() =>
  computeLoadMoreThreshold(
    props.loadMoreThreshold,
    props.loadMoreThresholdRatio,
    containerHeight.value,
  ),
)

// Push the isScrollable value to the parent via an event whenever it
// changes. `immediate: true` ensures the parent gets the initial
// value on mount — otherwise the parent's local ref would start at
// its default (`false`) and the event would only fire on the FIRST
// actual value change. (Vue 3's `watch` on a computed does fire
// `immediate` with the current value at setup time, which is what
// we want here.) This is more reliable than letting the parent read
// the computed through the template ref — see the
// `scrollabilityChange` emit doc for the reason.
watch(isScrollable, (scrollable) => {
  emit('scrollabilityChange', scrollable)
}, { immediate: true })

let _anchorOffsetTopBefore = 0
let _pendingNewItemsCount = 0

const updateAccumulatedHeights = () => {
  const h: number[] = [0]
  let sum = 0
  for (let i = 0; i < props.items.length; i++) {
    sum += itemHeights.value.get(i) ?? props.defaultItemHeight
    h.push(sum)
  }
  accumulatedHeights.value = h
}

// CRITICAL: `{ immediate: true }` is required here. Without it,
// `updateAccumulatedHeights` only runs when `props.items.length`
// *changes* — but on initial mount the items are already present
// (the parent populates them before rendering this child), so the
// length never "changes" during the watch's lifetime. Result:
// `accumulatedHeights` stays at the initial `[0]`, the computed
// `isScrollable` reads `accumulatedHeights[items.length]` which is
// `undefined ?? 0 = 0`, `0 > containerHeight` is `false`, and the
// parent's "Load more messages" button shows in scrollable chats
// (user reported: "i still see a scroll" / button still visible).
// `immediate: true` makes the watcher run synchronously during
// setup, populating `accumulatedHeights` with default-height
// estimates before the first render. After ~150ms (the mount
// setTimeout + the `itemHeights` deep-watch debounce) the real
// measurements replace the estimates, and `isScrollable` reflects
// reality. Symptom was traced via the dev-tools scroll logger
// showing `clientHeight: 0`-like behavior — the container was
// fine, `accumulatedHeights` was empty.
watch(() => props.items.length, updateAccumulatedHeights, { immediate: true })

let heightDebounce: ReturnType<typeof setTimeout> | null = null
watch(
  itemHeights,
  () => {
    if (heightDebounce) clearTimeout(heightDebounce)
    heightDebounce = setTimeout(updateAccumulatedHeights, 50)
  },
  { deep: true },
)

const findStartIndex = (): number => {
  const h = accumulatedHeights.value
  if (h.length <= 1) return 0
  let lo = 0,
    hi = h.length - 1
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if ((h[mid] ?? 0) <= scrollTop.value) lo = mid + 1
    else hi = mid
  }
  return Math.max(0, lo - 1)
}

const visibleRange = computed(() => {
  const len = props.items.length
  if (len === 0) return { start: 0, end: 0, topSpacer: 0, bottomSpacer: 0 }

  const startIndex = findStartIndex()
  const viewBottom = scrollTop.value + containerHeight.value
  let acc = accumulatedHeights.value[startIndex] ?? 0
  let endIndex = startIndex
  while (endIndex < len && acc < viewBottom) {
    acc += itemHeights.value.get(endIndex) ?? props.defaultItemHeight
    endIndex++
  }

  let start = Math.max(0, startIndex - props.buffer)
  let end = Math.min(len, endIndex + props.buffer)

  if (forceRenderUpTo.value >= 0) {
    start = 0
    end = Math.max(end, forceRenderUpTo.value + 1)
  }

  const topSpacer = accumulatedHeights.value[start] ?? 0
  const bottomSpacer = (accumulatedHeights.value[len] ?? 0) - (accumulatedHeights.value[end] ?? 0)
  return { start, end, topSpacer, bottomSpacer }
})

const visibleItems = computed(() => {
  const { start, end } = visibleRange.value
  const result: { item: T; index: number }[] = []
  for (let i = start; i < end; i++) {
    const item = props.items[i]
    if (item !== undefined) result.push({ item, index: i })
  }
  return result
})

/**
 * Live count of items currently rendered in the DOM (i.e. the
 * length of `visibleItems`). Exposed so the parent can verify the
 * buffer contract and log "rendered N items" diagnostics without
 * opening dev-tools.
 *
 * Equals `end - start` from `visibleRange`, which is:
 *   - In the middle of the list: `2 * buffer + visibleCount`
 *   - At the top/bottom edges: clamped to whatever the list allows
 *
 * Recomputed automatically on every scroll, every measurement, and
 * every `items` length change.
 */
const renderedCount = computed(() => {
  const { start, end } = visibleRange.value
  return Math.max(0, end - start)
})

/**
 * The {start, end} range of items currently rendered. Exposed as
 * a single object so the parent can read both fields in one
 * reactive read (avoiding the start-vs-end skew that would happen
 * if they were two separate computeds and a scroll fired between
 * reads).
 */
const effectiveRange = computed(() => {
  const { start, end } = visibleRange.value
  return { start, end }
})

const scrollInfo = computed(() => ({
  scrollTop: scrollTop.value,
  visibleStart: visibleRange.value.start,
  visibleEnd: visibleRange.value.end,
  totalItems: props.items.length,
  direction: scrollTop.value > lastScrollTop.value ? ('down' as const) : ('up' as const),
}))

// Hysteresis dead-band for `measureItems()`: only update a stored
// height when the new measurement differs by more than this many
// pixels. Smaller deltas are sub-pixel rounding noise from the
// browser's layout (Chromium rounds sub-pixel offsets). Writing
// them anyway was the trigger for the scroll-ratcheting bug
// (docs/plans/2026-06-10-scroll-ratcheting-fix.md): a 1-2 px
// fluctuation cycled through updateAccumulatedHeights → topSpacer
// mutation → browser scroll-anchoring → scrollTop ratchet, with
// scrollTop and scrollHeight oscillating in lockstep while
// distanceFromBottom stayed constant. 4 px is large enough to
// absorb the noise floor and small enough to admit any real
// layout change (image load, content expansion, streaming).
const HYSTERESIS_PX = 4

const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  const children = content.children
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    const realIndex = visibleRange.value.start + i
    const h = el.offsetHeight
    if (h > 0) {
      const prev = itemHeights.value.get(realIndex)
      // First measurement (prev === undefined) always writes. On
      // subsequent measurements, skip unless the delta exceeds the
      // dead-band. Without this, 1-2 px sub-pixel noise from the
      // browser's layout causes the spacer to mutate on every
      // scroll/resize debounce cycle, which is the ratcheting
      // symptom in docs/plans/2026-06-10-scroll-ratcheting-fix.md.
      if (prev === undefined || Math.abs(h - prev) > HYSTERESIS_PX) {
        itemHeights.value.set(realIndex, h)
        changed = true
      }
    }
  }
  if (changed) updateAccumulatedHeights()
}

let loadMoreDebounce: ReturnType<typeof setTimeout> | null = null
let measureDebounce: ReturnType<typeof setTimeout> | null = null

const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  // Keep `containerHeight.value` in sync with the live DOM reading.
  // The `ResizeObserver` (line 516) only fires when the container's
  // *size* changes — it does NOT fire for scroll-only events. Between
  // the first `loadMore` and the next one, `endPreserve` does
  // `containerRef.value.scrollTop = newST` to restore the user's view,
  // which fires a scroll event but not a resize, and a layout reflow
  // during the prepend can briefly shrink the container below its
  // settled height. Either path leaves the cached `containerHeight.value`
  // stale, and the `effectiveLoadMoreThreshold` computed then silently
  // falls back to its 200 px absolute floor — which is the "ratio only
  // works on the first load" symptom. Reading `target.clientHeight`
  // here on every scroll event keeps the ref in sync. Vue's `ref` does
  // an internal equality check, so this is a no-op when the value
  // didn't change.
  containerHeight.value = target.clientHeight
  const st = target.scrollTop
  const dir = st > lastScrollTop.value ? 'down' : 'up'
  scrollTop.value = st
  lastScrollTop.value = st
  emit('scroll', st, dir as 'up' | 'down', target)

  if (loadMoreDebounce) clearTimeout(loadMoreDebounce)
  loadMoreDebounce = setTimeout(() => {
    if (isPreservingScroll.value) {
      // Don't log here — the parent is mid-preserve, suppression is
      // expected. The parent will log its own preserve-start/end
      // events that bracket this window.
      return
    }
    const hasMore = props.totalCount === 0 || props.items.length < props.totalCount
    if (!hasMore) {
      emit('loadMoreSuppressed', 'no-more-items')
      return
    }
    // Defensive guard: if the container isn't actually scrollable
    // (scrollHeight ≤ clientHeight, i.e. content fits in viewport),
    // `st < loadMoreThreshold` is trivially true because `st` is 0
    // and there's nothing to scroll. Emitting `loadMore` here would
    // cause the parent to fetch a page and prepend it, which is the
    // exact "flicker" users see when a chat's container reads as
    // 0×0 during an SSE stream. The check uses the container's
    // own dimensions — no parent layout assumptions.
    const isScrollable = target.scrollHeight > target.clientHeight
    if (!isScrollable) {
      emit('loadMoreSuppressed', 'not-scrollable')
      return
    }
    const threshold = effectiveLoadMoreThreshold.value
    if (props.loadMoreAtTop) {
      if (st < threshold && props.items.length > 0) {
        emit('loadMore')
      } else if (st < threshold && props.items.length === 0) {
        // User is near the top but there are no items yet — nothing
        // to "load more of". This is the "empty list, scrolled to
        // top" case (rare; usually we wouldn't be at the top of
        // an empty list, but guard it).
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the top yet — normal scrolling,
      // not a suppression. Don't emit.
    } else {
      const bottom = target.scrollHeight - st - target.clientHeight
      if (bottom < threshold && props.items.length > 0) {
        emit('loadMore')
      } else if (bottom < threshold && props.items.length === 0) {
        emit('loadMoreSuppressed', 'no-items')
      }
      // else: user is just not near the bottom yet
    }
  }, 200)

  if (measureDebounce) clearTimeout(measureDebounce)
  measureDebounce = setTimeout(measureItems, 50)
}

/**
 * PHASE 1 — call BEFORE mutating items array.
 * Reads anchor (old item[0]) offsetTop while it is still in the DOM.
 */
const beginPreserve = (newItemsCount: number) => {
  if (!containerRef.value || newItemsCount <= 0) return
  isPreservingScroll.value = true
  _pendingNewItemsCount = newItemsCount

  const content = containerRef.value.querySelector('.virtual-scroller-content')
  const anchorEl = content
    ? (content.querySelector('[data-vs-index="0"]') as HTMLElement | null)
    : null

  _anchorOffsetTopBefore = anchorEl ? anchorEl.offsetTop : 0
  console.log('[beginPreserve] anchorEl found:', !!anchorEl, 'offsetTop:', _anchorOffsetTopBefore)
}

/**
 * PHASE 2 — call AFTER items array has been mutated.
 * Expands render window, waits for layout, sets scrollTop once accurately.
 */
const endPreserve = async () => {
  if (!containerRef.value || _pendingNewItemsCount <= 0) {
    isPreservingScroll.value = false
    return
  }

  const n = _pendingNewItemsCount
  forceRenderUpTo.value = n - 1

  await nextTick()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))

  measureItems()
  updateAccumulatedHeights()

  // Try to find anchor at its new index
  const content = containerRef.value!.querySelector('.virtual-scroller-content')
  const anchorEl = content
    ? (content.querySelector(`[data-vs-index="${n}"]`) as HTMLElement | null)
    : null

  if (anchorEl) {
    const newST = anchorEl.offsetTop
    console.log('[endPreserve] strategy A — anchorEl.offsetTop:', newST)
    containerRef.value!.scrollTop = newST
    scrollTop.value = newST
    lastScrollTop.value = newST
  } else {
    // Fallback: sum measured heights of new items
    let sum = 0
    for (let i = 0; i < n; i++) sum += itemHeights.value.get(i) ?? props.defaultItemHeight
    console.log('[endPreserve] strategy B — sum:', sum)
    containerRef.value!.scrollTop = sum
    scrollTop.value = sum
    lastScrollTop.value = sum
  }

  forceRenderUpTo.value = -1
  isPreservingScroll.value = false
  _pendingNewItemsCount = 0
  console.log('[endPreserve] END scrollTop:', containerRef.value!.scrollTop)
}

const scrollToIndex = (index: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  containerRef.value.scrollTo({
    top: accumulatedHeights.value[index] ?? index * props.defaultItemHeight,
    behavior,
  })
}
const scrollToTop = (behavior: ScrollBehavior = 'auto') =>
  containerRef.value?.scrollTo({ top: 0, behavior })
const scrollToBottom = (behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  containerRef.value.scrollTo({
    top: Math.max(0, containerRef.value.scrollHeight - containerHeight.value),
    behavior,
  })
}
const scrollToPosition = (scrollTop: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  const clientHeight = containerRef.value.clientHeight
  const max = containerRef.value.scrollHeight - clientHeight
  if (max <= 0) return
  const clamped = Math.max(0, Math.min(scrollTop, max))
  containerRef.value.scrollTo({ top: clamped, behavior })
}
const scrollToItem = (index: number, behavior: ScrollBehavior = 'auto') =>
  scrollToIndex(index, behavior)

let ro: ResizeObserver | null = null
onMounted(() => {
  if (containerRef.value) {
    containerHeight.value = containerRef.value.clientHeight
    ro = new ResizeObserver(() => {
      if (containerRef.value) containerHeight.value = containerRef.value.clientHeight
      nextTick(() => setTimeout(measureItems, 50))
    })
    ro.observe(containerRef.value)
  }
  nextTick(() => setTimeout(measureItems, 100))
})
onUnmounted(() => {
  ro?.disconnect()
  if (loadMoreDebounce) clearTimeout(loadMoreDebounce)
  if (measureDebounce) clearTimeout(measureDebounce)
  if (heightDebounce) clearTimeout(heightDebounce)
})

defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  scrollToPosition,
  scrollToItem,
  beginPreserve,
  endPreserve,
  preserveScrollPosition: endPreserve, // legacy alias
  scrollInfo,
  containerRef,
  isPreservingScroll,
  isScrollable,
  effectiveLoadMoreThreshold,
  renderedCount,
  effectiveRange,
})
</script>

<template>
  <div ref="containerRef" class="virtual-scroller" @scroll="onScroll">
    <div class="virtual-scroller-spacer" :style="{ height: visibleRange.topSpacer + 'px' }" />
    <div class="virtual-scroller-content">
      <div v-for="{ item, index } in visibleItems" :key="index" :data-vs-index="index">
        <slot :item="item" :index="index" />
      </div>
    </div>
    <div class="virtual-scroller-spacer" :style="{ height: visibleRange.bottomSpacer + 'px' }" />
  </div>
</template>

<style scoped>
.virtual-scroller {
  overflow-y: auto;
  /*
   * Disable CSS scroll anchoring. The default `overflow-anchor: auto`
   * makes the browser adjust scrollTop by the spacer delta when the
   * topSpacer mutates — which happens every time `measureItems()`
   * re-measures buffer items. That adjustment is the "ratchet" the
   * user sees in the scrollLogger: scrollTop and scrollHeight
   * oscillate in lockstep, distanceFromBottom stays constant.
   * Disabling it preserves the user's scrollTop on spacer changes;
   * any visible re-anchoring is the user's choice (they can scroll
   * a hair to compensate). See
   * docs/plans/2026-06-10-scroll-ratcheting-fix.md.
   */
  overflow-anchor: none;
  /*
   * Use `flex: 1 1 0` instead of `height: 100%` so the scroller
   * participates in the parent's flex layout properly. `height: 100%`
   * requires every ancestor to have a *resolved* height, which isn't
   * guaranteed through a chain of `flex-1` items during the first
   * paint — the scroller then reads as 0×0, which (1) breaks auto-
   * scroll, (2) makes the scroller's own loadMore check fire
   * inappropriately, causing the "flicker" users see during SSE
   * streaming. `flex: 1 1 0` makes the scroller a proper flex item
   * that takes all available space without depending on percentage
   * resolution. `min-height: 0` allows it to shrink below its
   * content size (the default `min-height: auto` would prevent
   * shrinking and break the scroll).
   *
   * `min-height: 100px` is a safety net: if the scroller is ever
   * dropped into a non-flex parent, it still has a visible size.
   */
  flex: 1 1 0;
  min-height: 0;
  /*
   * No explicit min-height: the Tailwind `min-h-0` class on the parent
   * (set by every consumer: ChatsList's chat list div, ChatView's
   * messages wrapper) provides the "shrink below content size" behavior
   * needed for the scroller to participate correctly in a flex column.
   * The previous `min-height: 100px` was a misnamed safety net that
   * caused the scroller to overflow its parent when the parent's
   * available height was less than 100px (e.g. ChatsList with a small
   * `chatsHeight` percentage), making the last visible chat row render
   * ON TOP of the WORKSPACES section header below. The "non-flex
   * parent" case the old comment worried about would already be broken
   * (no height to scroll in) — the 100 px floor just hid the bug
   * behind an even bigger layout collision.
   */
}
.virtual-scroller-content {
  display: flex;
  flex-direction: column;
}
</style>
