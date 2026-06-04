<script setup lang="ts" generic="T">
import { ref, computed, onMounted, onUnmounted, nextTick, watch } from 'vue'

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
     * Number of extra items to render above and below the visible viewport.
     * A larger buffer means smoother scrolling (fewer "pop in" moments as
     * the user scrolls) at the cost of more DOM nodes. The default of 5
     * is a good balance for most text/list UIs. For tall items (chat
     * bubbles, cards with images) you may want to lower this; for short
     * uniform items (log lines, search results) you can raise it.
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
     * Default 200px gives the parent a comfortable window to fetch and
     * prepend the next page before the user actually reaches the edge.
     * Lower it if your API is very fast and you want to start prepending
     * later (less wasted work); raise it if your API is slow and you
     * want to start prepending earlier (smoother scroll).
     *
     * The emit is debounced (~200ms) and is suppressed while
     * `beginPreserve`/`endPreserve` is in flight, so a single
     * scroll-to-edge gesture won't fire `loadMore` multiple times.
     */
    loadMoreThreshold?: number
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
  scroll: [scrollTop: number, direction: 'up' | 'down']
}>()

const containerRef = ref<HTMLElement | null>(null)
const scrollTop = ref(0)
const lastScrollTop = ref(0)
const containerHeight = ref(0)
const itemHeights = ref<Map<number, number>>(new Map())
const accumulatedHeights = ref<number[]>([0])
const isPreservingScroll = ref(false)
const forceRenderUpTo = ref(-1)

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

watch(() => props.items.length, updateAccumulatedHeights)

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
  while (endIndex < len && acc < viewBottom + 200) {
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

const scrollInfo = computed(() => ({
  scrollTop: scrollTop.value,
  visibleStart: visibleRange.value.start,
  visibleEnd: visibleRange.value.end,
  totalItems: props.items.length,
  direction: scrollTop.value > lastScrollTop.value ? ('down' as const) : ('up' as const),
}))

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
    if (h > 0 && itemHeights.value.get(realIndex) !== h) {
      itemHeights.value.set(realIndex, h)
      changed = true
    }
  }
  if (changed) updateAccumulatedHeights()
}

let loadMoreDebounce: ReturnType<typeof setTimeout> | null = null
let measureDebounce: ReturnType<typeof setTimeout> | null = null

const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const st = target.scrollTop
  const dir = st > lastScrollTop.value ? 'down' : 'up'
  scrollTop.value = st
  lastScrollTop.value = st
  emit('scroll', st, dir as 'up' | 'down')

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
    if (props.loadMoreAtTop) {
      if (st < props.loadMoreThreshold && props.items.length > 0) {
        emit('loadMore')
      } else if (st < props.loadMoreThreshold && props.items.length === 0) {
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
      if (bottom < props.loadMoreThreshold && props.items.length > 0) {
        emit('loadMore')
      } else if (bottom < props.loadMoreThreshold && props.items.length === 0) {
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
  scrollToItem,
  beginPreserve,
  endPreserve,
  preserveScrollPosition: endPreserve, // legacy alias
  scrollInfo,
  containerRef,
  isPreservingScroll,
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
  min-height: 100px;
}
.virtual-scroller-content {
  display: flex;
  flex-direction: column;
}
</style>
