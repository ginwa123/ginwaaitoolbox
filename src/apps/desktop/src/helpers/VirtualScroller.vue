<script setup lang="ts" generic="T">
/**
 * VirtualScroller - Agnostic Virtual Scrolling Component (Variable Height)
 * 
 * Features:
 * - No fixed item height required
 * - Measures actual item heights after render
 * - Uses top/bottom spacers for accurate scrollbar
 * - Slot-based rendering for full flexibility
 * - Supports infinite scroll via onLoadMore callback
 * - Supports loading more at TOP (for chat history pagination)
 * 
 * Usage:
 * <VirtualScroller
 *   :items="myItems"
 *   :buffer="5"
 *   @load-more="fetchMore"
 * >
 *   <template #default="{ item, index }">
 *     <div class="chat-item">{{ item.name }}</div>
 *   </template>
 * </VirtualScroller>
 */

import { ref, computed, onMounted, onUnmounted, nextTick, watch } from 'vue'

// Props
const props = withDefaults(defineProps<{
  items: T[]
  totalCount?: number       // Total items available (from API). If not provided, assumes unlimited.
  buffer?: number           // Extra items to render above/below visible area
  defaultItemHeight?: number // Default height if not measured (pixels)
  loadMoreThreshold?: number
  loadMoreAtTop?: boolean   // Emit loadMore when scrolled near TOP (for chat history)
}>(), {
  totalCount: 0,            // 0 means unknown/unlimited
  buffer: 5,
  defaultItemHeight: 100,
  loadMoreThreshold: 200,
  loadMoreAtTop: false,
})

const emit = defineEmits<{
  loadMore: []
  scroll: [scrollTop: number, direction: 'up' | 'down']
}>()

// Refs
const containerRef = ref<HTMLElement | null>(null)
const scrollTop = ref(0)
const lastScrollTop = ref(0)
const containerHeight = ref(0)
const itemHeights = ref<Map<number, number>>(new Map())
const accumulatedHeights = ref<number[]>([0]) // Cumulative height at each item index
const isPreservingScroll = ref(false)  // Prevents scroll resets during preserveScrollPosition

// Update accumulated heights when items or their heights change
const updateAccumulatedHeights = () => {
  const heights: number[] = [0]
  let sum = 0
  for (let i = 0; i < props.items.length; i++) {
    const height = itemHeights.value.get(i) ?? props.defaultItemHeight
    sum += height
    heights.push(sum)
  }
  accumulatedHeights.value = heights
}

// Calculate total height - ONLY use accumulated heights (actual measured heights)
// Do NOT use totalCount for height calculation - it causes scroll jumping
// because items have variable heights (user messages, assistant messages, tool calls).
// totalCount is only used to know IF there are more items to load, not for scrollbar size.
const totalHeight = computed(() => {
  // Always use accumulated heights for accurate scrollbar
  // This ensures scrollbar is proportional to actual content height
  return accumulatedHeights.value[props.items.length] ?? 0
})

// Watch for item count changes
watch(() => props.items.length, () => {
  updateAccumulatedHeights()
})

// Watch for item heights changes with debounce to prevent flicker during scrolling
let heightUpdateTimeout: ReturnType<typeof setTimeout> | null = null
watch(itemHeights, () => {
  if (heightUpdateTimeout) {
    clearTimeout(heightUpdateTimeout)
  }
  heightUpdateTimeout = setTimeout(() => {
    updateAccumulatedHeights()
  }, 50)
}, { deep: true })

// Find the first visible item index using binary search
const findStartIndex = (): number => {
  const heights = accumulatedHeights.value
  if (heights.length <= 1) return 0
  
  let low = 0
  let high = heights.length - 1
  
  while (low < high) {
    const mid = Math.floor((low + high) / 2)
    const midHeight = heights[mid]
    if (midHeight !== undefined && midHeight <= scrollTop.value) {
      low = mid + 1
    } else {
      high = mid
    }
  }
  
  return Math.max(0, low - 1)
}

// Calculate visible range
const visibleRange = computed(() => {
  if (props.items.length === 0) return { start: 0, end: 0, topSpacer: 0, bottomSpacer: 0 }
  
  const startIndex = findStartIndex()
  
  // Find end index by accumulating heights
  const startHeight = accumulatedHeights.value[startIndex] ?? 0
  let accumulated = startHeight
  let endIndex = startIndex
  const viewHeight = scrollTop.value + containerHeight.value
  
  while (endIndex < props.items.length && accumulated < viewHeight + 200) {
    const height = itemHeights.value.get(endIndex) ?? props.defaultItemHeight
    accumulated += height
    endIndex++
  }
  
  // Apply buffer
  const start = Math.max(0, startIndex - props.buffer)
  const end = Math.min(props.items.length, endIndex + props.buffer)
  
  // Calculate spacers
  const topSpacer = accumulatedHeights.value[start] ?? 0
  const bottomSpacer = (accumulatedHeights.value[props.items.length] ?? 0) - (accumulatedHeights.value[end] ?? 0)
  
  return { start, end, topSpacer, bottomSpacer }
})

// The items to actually render
const visibleItems = computed(() => {
  const range = visibleRange.value
  const items: { item: T; index: number }[] = []
  for (let i = range.start; i < range.end; i++) {
    const item = props.items[i]
    if (item !== undefined) {
      items.push({ item, index: i })
    }
  }
  return items
})

// Scroll info
const scrollInfo = computed(() => ({
  scrollTop: scrollTop.value,
  visibleStart: visibleRange.value.start,
  visibleEnd: visibleRange.value.end,
  totalItems: props.items.length,
  direction: scrollTop.value > lastScrollTop.value ? 'down' as const : 'up' as const,
}))

// Measure item heights after render
const measureItems = () => {
  if (!containerRef.value) return
  
  const contentEl = containerRef.value.querySelector('.virtual-scroller-content')
  if (!contentEl) return
  
  const itemEls = contentEl.children
  for (let i = 0; i < itemEls.length; i++) {
    const el = itemEls[i] as HTMLElement
    const realIndex = visibleRange.value.start + i
    const height = el.offsetHeight
    if (height > 0) {
      const existingHeight = itemHeights.value.get(realIndex)
      if (existingHeight !== height) {
        itemHeights.value.set(realIndex, height)
        updateAccumulatedHeights()
      }
    }
  }
}

// Methods
let loadMoreTimeout: ReturnType<typeof setTimeout> | null = null
let measureTimeout: ReturnType<typeof setTimeout> | null = null

const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const newScrollTop = target.scrollTop
  const direction = newScrollTop > lastScrollTop.value ? 'down' : 'up'
  
  scrollTop.value = newScrollTop
  lastScrollTop.value = newScrollTop

  emit('scroll', newScrollTop, direction)

  // Infinite scroll detection with debounce
  if (loadMoreTimeout) {
    clearTimeout(loadMoreTimeout)
  }
  
  const triggerLoadMore = () => {
    // Only trigger if we know there are more items (totalCount > items.length)
    // or totalCount is 0 (unknown/unlimited)
    const hasMore = props.totalCount === 0 || props.items.length < props.totalCount
    
    if (!hasMore) return  // Don't trigger if we've loaded everything
    
    if (props.loadMoreAtTop) {
      if (newScrollTop < props.loadMoreThreshold && props.items.length > 0) {
        emit('loadMore')
      }
    } else {
      const scrollBottom = target.scrollHeight - target.scrollTop - target.clientHeight
      if (scrollBottom < props.loadMoreThreshold && props.items.length > 0) {
        emit('loadMore')
      }
    }
  }
  
  loadMoreTimeout = setTimeout(triggerLoadMore, 200)
  
  // Debounce item measurement
  if (measureTimeout) {
    clearTimeout(measureTimeout)
  }
  measureTimeout = setTimeout(measureItems, 50)
}

const scrollToIndex = async (index: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  
  const targetScrollTop = accumulatedHeights.value[index] ?? (index * props.defaultItemHeight)
  
  containerRef.value.scrollTo({
    top: targetScrollTop,
    behavior,
  })
}

const scrollToTop = (behavior: ScrollBehavior = 'auto') => {
  if (containerRef.value) {
    containerRef.value.scrollTo({ top: 0, behavior })
  }
}

const scrollToBottom = (behavior: ScrollBehavior = 'auto') => {
  if (containerRef.value) {
    console.log('[VirtualScroller scrollToBottom] scrollHeight:', containerRef.value.scrollHeight, 'clientHeight:', containerHeight.value)
    const maxScroll = containerRef.value.scrollHeight - containerHeight.value
    console.log('[VirtualScroller scrollToBottom] maxScroll:', maxScroll, 'behavior:', behavior)
    containerRef.value.scrollTo({
      top: Math.max(0, maxScroll),
      behavior,
    })
  }
}

// Preserve scroll position when prepending items (for chat history)
// This adjusts scrollTop to account for the new items added at the top
const preserveScrollPosition = (newItemsCount: number) => {
  if (!containerRef.value || newItemsCount <= 0) return
  
  console.log('[preserveScrollPosition] START - newItemsCount:', newItemsCount, 'scrollTop:', scrollTop.value)
  
  // Set flag to prevent watchers from triggering scrollToBottom
  isPreservingScroll.value = true
  
  // PROBLEM: Doing two adjustments causes a visible "jump"
  // SOLUTION: Wait for items to render, measure them, then do ONE adjustment
  
  // First, let Vue render the new items
  nextTick(() => {
    nextTick(() => {
      console.log('[preserveScrollPosition] PASS - measuring items after render')
      
      // Now measure ALL visible items
      measureItems()
      
      // Calculate height of NEW items (indices 0 to newItemsCount-1)
      let newItemsHeight = 0
      for (let i = 0; i < newItemsCount; i++) {
        const measuredHeight = itemHeights.value.get(i)
        newItemsHeight += measuredHeight ?? props.defaultItemHeight
        console.log('[preserveScrollPosition] Item', i, 'height:', measuredHeight ?? 'default')
      }
      
      console.log('[preserveScrollPosition] New items total height:', newItemsHeight)
      
      // Do ONE adjustment - scroll down by the height of new items
      const newScrollTop = scrollTop.value + newItemsHeight
      containerRef.value!.scrollTop = newScrollTop
      lastScrollTop.value = newScrollTop
      scrollTop.value = newScrollTop
      
      console.log('[preserveScrollPosition] Adjusted scrollTop:', newScrollTop)
      
      // Update accumulated heights
      updateAccumulatedHeights()
      
      isPreservingScroll.value = false
      console.log('[preserveScrollPosition] END')
    })
  })
}

// Scroll to a specific item by index while preserving relative position in viewport
const scrollToItem = (targetIndex: number, behavior: ScrollBehavior = 'auto') => {
  if (!containerRef.value) return
  
  // Get the accumulated height up to the target index
  const targetScrollTop = accumulatedHeights.value[targetIndex] ?? (targetIndex * props.defaultItemHeight)
  
  containerRef.value.scrollTo({
    top: targetScrollTop,
    behavior,
  })
}

// Resize observer
let resizeObserver: ResizeObserver | null = null

const updateContainerHeight = () => {
  if (containerRef.value) {
    containerHeight.value = containerRef.value.clientHeight
  }
}

onMounted(() => {
  updateContainerHeight()
  
  if (containerRef.value) {
    resizeObserver = new ResizeObserver(() => {
      updateContainerHeight()
      // Re-measure items after container resize
      nextTick(() => {
        setTimeout(measureItems, 50)
      })
    })
    resizeObserver.observe(containerRef.value)
  }
  
  // Initial measure after items render
  nextTick(() => {
    setTimeout(measureItems, 100)
  })
})

onUnmounted(() => {
  if (resizeObserver) {
    resizeObserver.disconnect()
  }
})

// Note: We DON'T watch visibleItems here as it causes high CPU during scrolling
// Item heights are measured via onScroll debounce instead

// Expose methods for parent
defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  preserveScrollPosition,
  scrollToItem,
  scrollInfo,
  containerRef,
  isPreservingScroll,
})
</script>

<template>
  <div
    ref="containerRef"
    class="virtual-scroller"
    @scroll="onScroll"
  >
    <!-- Top spacer to maintain scroll position -->
    <div class="virtual-scroller-spacer" :style="{ height: visibleRange.topSpacer + 'px' }"></div>
    
    <!-- Visible items -->
    <div class="virtual-scroller-content">
      <div
        v-for="{ item, index } in visibleItems"
        :key="index"
      >
        <slot :item="item" :index="index" />
      </div>
    </div>
    
    <!-- Bottom spacer to maintain scroll position -->
    <div class="virtual-scroller-spacer" :style="{ height: visibleRange.bottomSpacer + 'px' }"></div>
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