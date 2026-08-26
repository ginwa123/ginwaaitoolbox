<script setup lang="ts" generic="T">
import { ref, computed, onMounted, onUnmounted, nextTick, watch } from 'vue'

import { computeLoadMoreThreshold } from './virtualScrollerThreshold'
import { computeAnchorCompensation, type AnchorMeasurement } from './virtualScrollerScrollAnchor'
import { quantizePx, AdaptiveItemHeightEstimator } from './virtualScrollerPerf'

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
    /**
     * Stable identity function for items (2026-08-26 stable-keys fix).
     * Returns a string that uniquely identifies the item's CONTENT —
     * e.g. a DB id — and survives position changes in the array.
     *
     * WHY: the height cache was keyed by ARRAY INDEX. ChatView renders
     * `messageGroups`, a computed that re-merges/re-filters on every
     * SSE event — so a group count change (thinking-only row dropped,
     * tool row arriving, streaming row swapped) SHIFTS every later
     * index. The stored height for index k then described a different
     * row: a 40px tool-card height landed on a 2000px markdown message
     * and vice versa. The sizer became the sum of mismatched heights →
     * wildly too tall → stick-to-bottom landed in blank space (the
     * "sizer 16034px vs real content 13720px" DevTools evidence).
     *
     * With `itemKey`, heights are keyed by identity: a row keeps its
     * own measured height wherever it moves. Index shifts become
     * harmless. Also used as the v-for key so Vue reuses the correct
     * DOM node per item (less re-render flicker during streaming).
     *
     * Default: `String(index)` — index-keyed, the historical behavior.
     * Consumers with stable ids (ChatView: `group.messages[0].id`)
     * SHOULD pass this prop.
     */
    itemKey?: (item: T, index: number) => string
  }>(),
  {
    totalCount: 0,
    buffer: 5,
    defaultItemHeight: 100,
    loadMoreThreshold: 200,
    loadMoreThresholdRatio: 0.5,
    loadMoreAtTop: false,
    itemKey: undefined,
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
   *
   * `isProgrammatic` (4th arg, 2026-08-25 append-gap fix): true when
   * this scroll event was caused by the scroller's OWN scrollTop
   * write — the anchor-compensation inside `measureItems()` (and the
   * `endPreserve` restoration). Assigning `.scrollTop` fires a real
   * native `scroll` event that is otherwise indistinguishable from a
   * user gesture. ChatView's `handleVirtualScroll` uses this to keep
   * `userScrolledUp` honest: a compensation write that happens to
   * move scrollTop DOWN (measured height < estimate — common when
   * streamed markdown settles shorter) must NOT flip `isAtBottom`
   * to false, or the auto-stick disengages and every later SSE
   * chunk's contentShift hits the `spacer-resize-skip` guard — the
   * "gap below the last message grows forever" symptom.
   */
  scroll: [scrollTop: number, direction: 'up' | 'down', target: HTMLElement, isProgrammatic: boolean]
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
  /**
   * Fired whenever the scroller's content positioning values change —
   * i.e. when `topSpacer`, `bottomSpacer`, or the total content height
   * changes as a result of scrolling, measurement, or item-list updates.
   *
   * P2 (task_1787551495337_9): with transform-based positioning there
   * are no spacer DIVs whose `style.height` mutations a parent
   * MutationObserver could watch (ChatView's previous stick-to-bottom
   * signal). This event is the explicit replacement: parents that need
   * to react to "the virtual layout moved" (re-stick to bottom after
   * measurement drift, etc.) listen here instead.
   *
   * Payload: `{ topSpacer, bottomSpacer, total }` in px.
   */
  contentShift: [shift: { topSpacer: number; bottomSpacer: number; total: number }]
}>()

const containerRef = ref<HTMLElement | null>(null)
// Content-div ref: its ref callback measures the REAL rendered height
// after every render (feeds the sizer clamp — see sizerHeight above).
const contentRef = ref<HTMLElement | null>(null)
const scrollTop = ref(0)
const lastScrollTop = ref(0)
const containerHeight = ref(0)
// Heights keyed by STABLE ID (itemKey(item)), not array index — see the
// itemKey prop JSDoc for the index-shift corruption this prevents.
const itemHeights = ref<Map<string, number>>(new Map())
const accumulatedHeights = ref<number[]>([0])
const isPreservingScroll = ref(false)
const forceRenderUpTo = ref(-1)

/**
 * Stable identity for the item at `index`. Falls back to the index
 * string when no `itemKey` prop is supplied (historical behavior).
 */
const keyOf = (index: number): string => {
  const item = props.items[index]
  if (item === undefined) return `#${index}`
  return props.itemKey ? props.itemKey(item, index) : `#${index}`
}

// ── Programmatic-scroll tracking (2026-08-25 append-gap fix) ────────────────
//
// The scroller writes `containerRef.scrollTop` itself in two places:
// the anchor-compensation inside `measureItems()` and the restoration
// in `endPreserve()`. Assigning `.scrollTop` fires a REAL native
// `scroll` event — indistinguishable from a user gesture by the time
// it reaches `onScroll`. Without a flag, ChatView's
// `handleVirtualScroll` reads a downward compensation write (measured
// height < estimate) as `userScrolledUp = true`, flips `isAtBottom`
// to false, and the auto-stick disengages for the rest of the stream
// — every later contentShift hits the `spacer-resize-skip` guard and
// the gap below the last message grows with each chunk.
//
// Same counter pattern as scrollLogger.markProgrammatic (which only
// labels LOG lines — it has no influence on the stick decision).
// `pendingProgrammaticScrolls` is bumped BEFORE the write and consumed
// by the very next `onScroll`, which forwards the flag on the `scroll`
// emit. The 100ms reset timer is the same leak-guard scrollLogger
// uses (scroll event never fires because scrollTop didn't change).
let pendingProgrammaticScrolls = 0
let programmaticResetTimer: ReturnType<typeof setTimeout> | null = null
const markProgrammaticScroll = (): void => {
  pendingProgrammaticScrolls += 1
  if (programmaticResetTimer) clearTimeout(programmaticResetTimer)
  programmaticResetTimer = setTimeout(() => {
    pendingProgrammaticScrolls = 0
  }, 100)
}
const consumeProgrammaticScroll = (): boolean => {
  if (pendingProgrammaticScrolls > 0) {
    pendingProgrammaticScrolls -= 1
    return true
  }
  return false
}

// ── P1 perf: adaptive item-height estimation (task_1787551495337_9) ─────────
//
// `props.defaultItemHeight` is a static guess; real chat bubbles are almost
// always taller, so unmeasured items were systematically under-estimated and
// every measurement pass triggered anchor compensation. The estimator learns
// the running MEDIAN of measured heights (robust against one giant code-block
// message) and supplies far better estimates for never-measured items → fewer
// wrong spacers → fewer compensation shifts → smoother scroll.
//
// Reset when the items array is swapped for a different list (length → 0 or
// identity change via the items-length watcher below) so one chat's height
// profile doesn't bleed into another's.
const heightEstimator = new AdaptiveItemHeightEstimator({
  seed: props.defaultItemHeight,
  maxSamples: 64,
})

// Highest index that has a real measured height. The learned median is
// only trusted for items AT OR BEFORE this index (history the user has
// actually scrolled through). Items AFTER it — the growing tail during
// SSE streaming — fall back to the static `defaultItemHeight` prop.
//
// WHY (gap-below-last-message bug, reported after P1+P2): the median of
// a chat's history is much taller than a freshly-appended streaming
// bubble. Estimating the tail at the median made the sizer extend past
// the real content, and stick-to-bottom (scrollTop = scrollHeight) put
// the viewport in that empty over-estimated region — a large blank gap
// below the last message. The old static 64px default never showed this
// because it UNDER-estimated (content overflowed the estimate instead).
let maxMeasuredIndex = -1

/**
 * Estimated height for an item with no stored measurement. Feeds the
 * prefix-sum builder and the visible-range scan.
 *
 * - Index ≤ maxMeasuredIndex (history): learned median — representative
 *   of what the user has scrolled through.
 * - Index > maxMeasuredIndex (tail): static prop — deliberately a
 *   conservative UNDER-estimate so the sizer never extends past real
 *   content (no scrollable gap below the last message).
 */
const estimateHeight = (index: number): number => {
  const stored = itemHeights.value.get(keyOf(index))
  if (stored !== undefined) return stored
  return index <= maxMeasuredIndex
    ? heightEstimator.estimate()
    : props.defaultItemHeight
}

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
    sum += estimateHeight(i)
    h.push(sum)
  }
  accumulatedHeights.value = h
}

// ── Render-level sizer clamp (2026-08-26 blank-viewport fix) ─────────────────
//
// The model total (Σ stored/estimated heights) can overshoot the real
// content — the browser then lets the user scroll into the phantom
// region below the last message (the "big gap / blank viewport"
// symptom, sizer 29389px vs real ~13720px). This computed clamps the
// RENDERED sizer height to the real content bottom whenever the
// rendered window includes the LAST item (every tail item is in the
// DOM, so the real bottom is directly measurable).
//
// CRITICAL SAFETY PROPERTY: this NEVER writes the height model — it
// only clamps the style binding. The model stays the source of truth
// for positioning (topSpacer/visibleRange); the clamp only trims the
// scrollable void. Because it is a pure function of reactive state
// (no DOM writes, no scrollTop writes), it CANNOT oscillate — the
// failure mode that killed the earlier tail clamp.
//
// `realContentHeight` is measured in the template ref callback below
// (after each render, before paint) and stored non-reactively; the
// reactive trigger is `renderTick`, bumped by that callback.
const modelTotal = computed(() => accumulatedHeights.value[props.items.length] ?? 0)
let realContentHeight = 0
const renderTick = ref(0)
// Ref callback: runs after every commit of the content div (mount +
// each patch that reuses the element). Measure the real rendered
// height and bump the tick so sizerHeight re-evaluates. Guarded
// against no-op bumps (same height → no reactive write → no loop).
const onContentRef = (el: unknown) => {
  const h = el ? (el as HTMLElement).offsetHeight : 0
  if (h > 0 && h !== realContentHeight) {
    realContentHeight = h
    renderTick.value++
  }
}
const sizerHeight = computed(() => {
  void renderTick.value // re-evaluate after each measured render
  const range = visibleRange.value
  if (range.end < props.items.length || realContentHeight <= 0) return modelTotal.value
  const realTotal = range.topSpacer + realContentHeight
  // Only clamp overshoot; never inflate past the model (undershoot is
  // handled by the normal measure path — content grows into it).
  const overshoot = modelTotal.value - realTotal
  return overshoot > HYSTERESIS_PX ? realTotal : modelTotal.value
})

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
watch(
  () => props.items.length,
  (newLen, oldLen) => {
    // A collapse to 0 means the list was swapped (chat switch) — forget
    // the previous chat's height profile so its median doesn't pollute
    // the new chat's estimates.
    if (newLen === 0 && (oldLen ?? 0) > 0) {
      heightEstimator.reset()
      maxMeasuredIndex = -1
    }
    updateAccumulatedHeights()
  },
  { immediate: true },
)

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
    acc += estimateHeight(endIndex)
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

// ── P2: contentShift emit (task_1787551495337_9) ─────────────────────────────
//
// Transform-based positioning has no spacer DIVs whose style mutations a
// parent MutationObserver could watch. This watcher is the explicit
// replacement signal: it fires whenever the virtual layout's geometry
// changes (scroll-driven window shift, measurement update, item-list
// change). ChatView listens to re-stick to bottom after measurement drift.
watch(
  () => ({
    topSpacer: visibleRange.value.topSpacer,
    bottomSpacer: visibleRange.value.bottomSpacer,
    total: accumulatedHeights.value[props.items.length] ?? 0,
  }),
  (shift) => {
    emit('contentShift', shift)
  },
  // immediate: the parent gets the initial geometry on mount — same
  // convention as the scrollabilityChange watcher above. Without it a
  // never-scrolled list would never emit, and ChatView's re-stick logic
  // would miss the initial measurement drift.
  { immediate: true },
)

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

// Rate-limit for the tail-exact clamp (freeze guard 2). See the clamp
// comment in measureItems below.
let lastTailClampAt = 0

const measureItems = () => {
  if (!containerRef.value) return
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  if (!content) return
  let changed = false
  // ── Scroll-anchor compensation (2026-08-23, chatview-scroll-jump-fix) ──
  //
  // Writing real heights over estimates for items ABOVE the viewport
  // mutates the spacers without moving scrollTop — content under the
  // viewport teleports by Σ(real − estimate). That is the "long chats
  // jump while scrolling" bug (task_1787496087806_6; log evidence:
  // adjacent samples sh=31443 → sh=36416 with top advancing only half
  // as much). Capture the pre-measure anchor + scrollTop so the writes
  // below can be compensated after `updateAccumulatedHeights()`.
  //
  // The anchor is the first VISIBLE index (not a DOM node): stable even
  // if the anchor item unmounts between frames, and jsdom-testable.
  const anchorIndex = findStartIndex()
  const prevScrollTop = containerRef.value.scrollTop
  const pendingMeasurements: AnchorMeasurement[] = []
  const children = content.children
  // ── P1 perf: batched height writes (task_1787551495337_9) ──────────────
  //
  // All measurements are collected into `pendingWrites` and applied to the
  // reactive Map in ONE synchronous block. The deep watcher on itemHeights
  // debounces its rebuild (50ms), so N writes inside one batch collapse to
  // ONE timer + ONE prefix-sum rebuild instead of N timer resets that each
  // would have re-scanned the full list. The Map itself is only made
  // reactive-mutable once per batch.
  //
  // NOTE: the child→index mapping reads each child's `data-vs-index`
  // attribute, NOT `visibleRange.value.start + i`. The computed range can
  // update synchronously while the DOM still shows the previous window
  // (render is scheduled to a later microtask); mapping via the live
  // computed would attribute old children's heights to the wrong indices.
  // The attribute is stamped by the renderer at mount time and always
  // matches the node it decorates.
  const pendingWrites: Array<[string, number, number]> = []
  for (let i = 0; i < children.length; i++) {
    const el = children[i] as HTMLElement
    const realIndex = visibleRange.value.start + i
    const h = el.offsetHeight
    if (h > 0) {
      // P1 perf: quantize to integer px. Fractional offsetHeights under
      // sub-pixel layout re-quantize differently between our prefix sums
      // and the browser's layout → ±1px spacer drift → micro-jitter.
      const heightPx = quantizePx(h)
      // Stable-key lookup: the height belongs to the ITEM (via its
      // itemKey), not the array slot — immune to index shifts from
      // messageGroups regrouping (the sizer-corruption bug).
      const key = keyOf(realIndex)
      const prev = itemHeights.value.get(key)
      // First measurement (prev === undefined) always writes. On
      // subsequent measurements, skip unless the delta exceeds the
      // dead-band. Without this, 1-2 px sub-pixel noise from the
      // browser's layout causes the spacer to mutate on every
      // scroll/resize debounce cycle, which is the ratcheting
      // symptom in docs/plans/2026-06-10-scroll-ratcheting-fix.md.
      if (prev === undefined || Math.abs(heightPx - prev) > HYSTERESIS_PX) {
        pendingMeasurements.push({ index: realIndex, newHeight: heightPx, oldHeight: prev })
        pendingWrites.push([key, heightPx, realIndex])
        changed = true
      }
    }
  }
  if (!changed) return
  for (const [key, heightPx, realIndex] of pendingWrites) {
    itemHeights.value.set(key, heightPx)
    // Feed the adaptive estimator so future unmeasured items inherit a
    // realistic median instead of the static prop guess.
    heightEstimator.observe(heightPx)
    // Track the measurement frontier: the learned median is only
    // trusted for items at or before this index (see estimateHeight).
    if (realIndex > maxMeasuredIndex) maxMeasuredIndex = realIndex
  }
  updateAccumulatedHeights()

  // NOTE (2026-08-25): a "tail-exact clamp" (force-write rendered tail
  // heights + shrink the sizer to the real content bottom when the
  // window shows the last item) was tried here and REMOVED. It caused
  // an oscillation loop — clamp shrinks sizer → window shifts → next
  // pass reads different heights → sizer grows → shifts again — which
  // the user experienced as app freezes and bouncing text during SSE
  // streams. Product decision (user): gaps below the last message are
  // ACCEPTABLE; bouncing is NOT. The anchor compensation above already
  // keeps scrolled-up reading stable; the remeasure() calls in ChatView
  // keep the at-bottom case tight without any clamping.

  // ── Apply the anchor compensation ────────────────────────────────────
  //
  // Only writes for indices strictly ABOVE the anchor shift content
  // under the viewport (the anchor item's own top edge sits at the
  // topSpacer boundary — its height change moves its bottom edge, not
  // its top). Visible-window growth is real content (streaming text,
  // image load) and must flow through uncompensated.
  //
  // Skipped while `isPreservingScroll`: `endPreserve` owns scroll
  // restoration during prepends and sets scrollTop from its own anchor
  // element; compensating here would double-adjust.
  const result = computeAnchorCompensation({
    anchorIndex,
    prevScrollTop,
    defaultItemHeight: props.defaultItemHeight,
    measurements: pendingMeasurements,
  })
  if (result.shiftPx !== 0 && !isPreservingScroll.value) {
    // Mark BEFORE the write: assigning .scrollTop fires a native scroll
    // event that onScroll must label as programmatic (see the counter
    // comment above — without this, a downward compensation is misread
    // as "user scrolled up" and disengages ChatView's auto-stick).
    markProgrammaticScroll()
    containerRef.value.scrollTop = result.newScrollTop
    scrollTop.value = result.newScrollTop
    lastScrollTop.value = result.newScrollTop
  }
}

// ── Pre-paint measurement on rendered-range change ───────────────────────────
//
// The debounced measureItems (50ms) compensates at MEASUREMENT time, but
// the jump for a tall item happens at RENDER time: when a new item enters
// the top buffer, Vue renders it in one commit — the topSpacer shrinks by
// its 64px estimate while its real height (e.g. a 3000px long message)
// takes its place — shifting content under the viewport IMMEDIATELY. The
// debounced correction arrives ≤50ms later: a visible down-up bounce.
//
// Fix: re-measure inside `nextTick` whenever the rendered window changes.
// nextTick callbacks drain BEFORE the browser paints, so render +
// measure + compensation collapse into ONE frame — no intermediate paint
// with wrong spacers, nothing to see.
//
// `_inPrePaintMeasure` guards re-entrancy: measureItems mutates
// scrollTop, which fires another scroll event → visibleRange recomputes
// → this watcher would re-run. The guard breaks that cycle; the trailing
// debounce below still catches any range change caused by the correction
// itself (rare — compensation preserves the anchor's screen position).
let _inPrePaintMeasure = false
let _prePaintTrailing: ReturnType<typeof setTimeout> | null = null

watch(effectiveRange, () => {
  if (_inPrePaintMeasure || isPreservingScroll.value) return
  nextTick(() => {
    if (_inPrePaintMeasure || isPreservingScroll.value) return
    _inPrePaintMeasure = true
    try {
      measureItems()
    } finally {
      _inPrePaintMeasure = false
    }
    // Trailing sweep: if the compensation shifted the window again,
    // one more pass settles it (debounced, off the critical path).
    if (_prePaintTrailing) clearTimeout(_prePaintTrailing)
    _prePaintTrailing = setTimeout(() => {
      if (!_inPrePaintMeasure && !isPreservingScroll.value) measureItems()
    }, 50)
  })
})

let loadMoreDebounce: ReturnType<typeof setTimeout> | null = null
let measureDebounce: ReturnType<typeof setTimeout> | null = null

const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  // Keep `containerHeight.value` in sync with the live DOM reading.
  // The `ResizeObserver` only fires when the container's *size* changes —
  // it does NOT fire for scroll-only events. Between the first `loadMore`
  // and the next one, `endPreserve` does `containerRef.value.scrollTop =
  // newST` to restore the user's view, which fires a scroll event but not
  // a resize, and a layout reflow during the prepend can briefly shrink
  // the container below its settled height. Either path leaves the cached
  // `containerHeight.value` stale, and the `effectiveLoadMoreThreshold`
  // computed then silently falls back to its 200 px absolute floor —
  // which is the "ratio only works on the first load" symptom. Reading
  // `target.clientHeight` here on every scroll event keeps the ref in
  // sync. Vue's `ref` does an internal equality check, so this is a no-op
  // when the value didn't change.
  containerHeight.value = target.clientHeight
  const st = target.scrollTop
  const dir = st > lastScrollTop.value ? 'down' : 'up'
  // NOTE (P1 perf review, task_1787551495337_9): this write stays
  // SYNCHRONOUS. An rAF-deferred variant was tried and reverted: the
  // pre-paint compensation contract (watch effectiveRange → nextTick →
  // measureItems, PR #310) requires the range recompute to begin within
  // the SAME tick as the scroll event; deferring it to the next frame
  // broke that guarantee. Coalescing is already provided by Vue's async
  // render queue — N scroll events between two flushes produce exactly
  // ONE component re-render and ONE visibleRange evaluation.
  scrollTop.value = st
  lastScrollTop.value = st
  // Consume the programmatic flag BEFORE the emit: a markProgrammatic
  // bump (from measureItems' compensation write or endPreserve's
  // restoration) belongs to exactly THIS event — the next one is a
  // fresh gesture (or another marked write).
  const isProgrammatic = consumeProgrammaticScroll()
  emit('scroll', st, dir as 'up' | 'down', target, isProgrammatic)

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

  // NOTE (2026-08-26 stable-keys fix): the old index-shift remap
  // (rebuilding the Map with every key +N) is GONE. Heights are keyed
  // by stable itemKey, so a prepend needs no remap — each item keeps
  // its own height wherever it moves. maxMeasuredIndex still advances
  // (the frontier is index-based: the prepended items are new tail
  // relative to the estimator's trust boundary... actually they are
  // NEW items at the FRONT, so the frontier advances by N to keep
  // pointing at the same physical item).
  if (newItemsCount > 0) {
    maxMeasuredIndex += newItemsCount
    updateAccumulatedHeights()
  }

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
    // Programmatic write — see markProgrammaticScroll's comment.
    markProgrammaticScroll()
    containerRef.value!.scrollTop = newST
    scrollTop.value = newST
    lastScrollTop.value = newST
  } else {
    // Fallback: sum measured heights of new items (key-based lookup)
    let sum = 0
    for (let i = 0; i < n; i++) sum += itemHeights.value.get(keyOf(i)) ?? props.defaultItemHeight
    console.log('[endPreserve] strategy B — sum:', sum)
    markProgrammaticScroll()
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
  // ── Real-bottom target (2026-08-26 blank-viewport fix) ───────────────
  //
  // The sizer height is a MODEL number (Σ stored/estimated heights) and
  // can overshoot the real content — stick-to-bottom computed from it
  // (scrollHeight - clientHeight) landed PAST the last row, in the
  // phantom region: the user's fully-blank-viewport screenshots
  // (sizer 29389px, window translated to 27971px, nothing visible).
  //
  // When the rendered window includes the LAST item, the real content
  // bottom is directly measurable: topSpacer + content.offsetHeight
  // (the content div is a flex column holding exactly the rendered
  // window). Targeting that instead of the model total guarantees the
  // last message is on screen — regardless of any residual model
  // overshoot. READ-ONLY: no sizer writes, no feedback loop (the tail
  // clamp that oscillated was a writer; this is a reader).
  const range = visibleRange.value
  const content = containerRef.value.querySelector('.virtual-scroller-content')
  const contentH = content ? (content as HTMLElement).offsetHeight : 0
  // Guard: a 0-height content div means layout hasn't settled (jsdom,
  // mid-frame) — trusting it would stick to the TOP. Fall through to
  // the model path instead.
  if (range.end >= props.items.length && contentH > 0) {
    const realBottom = range.topSpacer + contentH
    const target = Math.max(0, realBottom - containerHeight.value)
    // Only override when the model actually overshoots; otherwise the
    // plain scrollHeight path is already correct.
    const modelBottom = containerRef.value.scrollHeight - containerHeight.value
    if (modelBottom - target > HYSTERESIS_PX) {
      containerRef.value.scrollTo({ top: target, behavior })
      return
    }
  }
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

/**
 * Full recompute of the height model from the live DOM (2026-08-25
 * append-gap fix). The parent calls this whenever it KNOWS content
 * changed — new message appended, streaming text mutated in place,
 * streaming row swapped for the canonical row. measureItems() reads
 * every rendered child's real offsetHeight, writes the model, rebuilds
 * the sizer, and anchor-compensates — the same pass a scroll event
 * triggers, invoked explicitly at data-mutation time instead of being
 * inferred from DOM observation (the ResizeObserver attempt froze the
 * browser: observe → measure → sizer write → re-observe loop).
 *
 * Call inside nextTick (or later) so the DOM already reflects the
 * mutation — offsetHeight reads need the patched layout.
 */
const remeasure = () => {
  measureItems()
}

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
  if (_prePaintTrailing) clearTimeout(_prePaintTrailing)
  if (programmaticResetTimer) clearTimeout(programmaticResetTimer)
})

defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  scrollToPosition,
  scrollToItem,
  remeasure,
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
    <!--
      P2 (task_1787551495337_9): the two spacer DIVs are replaced by ONE
      sizer sized to the total content height, with the rendered window
      absolutely positioned inside it and moved via `translate3d`.

      Why: mutating a spacer's `height` style invalidates layout for the
      whole scroller on every window shift. A transform is a composited
      change — no layout, no paint of the shifted content — so window
      moves cost a GPU composite instead of a full relayout.

      The sizer keeps `scrollHeight` correct (the browser needs the total
      height to draw a scrollbar and clamp scrollTop); the transform puts
      the visible window at its exact offset within that height.
    -->
    <div class="virtual-scroller-sizer" :style="{ height: sizerHeight + 'px' }">
      <div
        :ref="onContentRef"
        class="virtual-scroller-content"
        :style="{ transform: `translate3d(0px, ${visibleRange.topSpacer}px, 0px)` }"
      >
        <!-- :key is the STABLE itemKey (not the index): Vue reuses the
             correct DOM node per item across index shifts (regrouping,
             prepends) — less re-render flicker, and offsetHeight mocks
             / real heights travel with their item. -->
        <div v-for="{ item, index } in visibleItems" :key="keyOf(index)" :data-vs-index="index">
          <slot :item="item" :index="index" />
        </div>
      </div>
    </div>
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
  /*
   * P2: the content window is absolutely positioned inside the sizer and
   * moved with translate3d (see template comment). `will-change: transform`
   * promotes it to its own compositor layer so window shifts are a GPU
   * composite instead of a layout+paint. The absolute positioning takes
   * the content out of flow — the SIZER is what holds scrollHeight up.
   */
  position: absolute;
  left: 0;
  right: 0;
  top: 0;
  will-change: transform;
}
.virtual-scroller-sizer {
  position: relative;
}
/*
 * P1 perf: CSS containment on item wrappers (task_1787551495337_9).
 *
 * `contain: layout style` tells the browser each item's internals cannot
 * affect layout outside its wrapper box (and vice versa). During a fast
 * scroll the window shift mounts/unmounts whole items; with containment
 * the browser can skip re-laying-out every OTHER item's subtree and only
 * process the changed wrappers. `contain: paint` is deliberately NOT set:
 * chat bubbles legitimately overflow their wrapper (dropdown menus,
 * hover cards, code-block scrollbars) and paint-clipping would cut them
 * off. `content-visibility` is also skipped for now — it defers rendering
 * of offscreen items, but combined with the virtualizer's own windowing
 * it caused blank-flash artifacts in earlier experiments.
 */
.virtual-scroller-content > [data-vs-index] {
  contain: layout style;
}
</style>
