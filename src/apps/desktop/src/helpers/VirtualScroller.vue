<script setup lang="ts" generic="T">
import { ref, computed, onMounted, onUnmounted, nextTick, watch } from 'vue'

const props = withDefaults(
  defineProps<{
    items: T[]
    totalCount?: number
    buffer?: number
    defaultItemHeight?: number
    loadMoreThreshold?: number
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
    if (isPreservingScroll.value) return
    const hasMore = props.totalCount === 0 || props.items.length < props.totalCount
    if (!hasMore) return
    if (props.loadMoreAtTop) {
      if (st < props.loadMoreThreshold && props.items.length > 0) emit('loadMore')
    } else {
      const bottom = target.scrollHeight - st - target.clientHeight
      if (bottom < props.loadMoreThreshold && props.items.length > 0) emit('loadMore')
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
  height: 100%;
}
.virtual-scroller-content {
  display: flex;
  flex-direction: column;
}
</style>
