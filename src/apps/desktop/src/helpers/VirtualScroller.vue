<script setup lang="ts" generic="T">
/**
 * VirtualScroller - Agnostic Virtual Scrolling Component
 * 
 * Features:
 * - Fixed-height item assumption for simplicity
 * - Slot-based rendering for full flexibility
 * - Exposes scroll state and methods for parent control
 * - Supports infinite scroll via onLoadMore callback
 * 
 * Usage:
 * <VirtualScroller
 *   :items="myItems"
 *   :item-height="48"
 *   :buffer="5"
 *   @load-more="fetchMore"
 * >
 *   <template #default="{ item, index }">
 *     <div class="chat-item">{{ item.name }}</div>
 *   </template>
 * </VirtualScroller>
 */

import { ref, computed, onMounted, onUnmounted, watch } from 'vue'

// Props
const props = withDefaults(defineProps<{
  items: T[]
  itemHeight: number
  buffer?: number
  containerHeight?: number
  loadMoreThreshold?: number
}>(), {
  buffer: 5,
  loadMoreThreshold: 200,
})

const emit = defineEmits<{
  loadMore: []
  scroll: [scrollTop: number, direction: 'up' | 'down']
}>()

// Refs
const containerRef = ref<HTMLElement | null>(null)
const scrollTop = ref(0)
const lastScrollTop = ref(0)
const containerHeight = ref(props.containerHeight ?? 0)

// Computed
const totalHeight = computed(() => props.items.length * props.itemHeight)

const startIndex = computed(() => {
  return Math.max(0, Math.floor(scrollTop.value / props.itemHeight) - props.buffer)
})

const endIndex = computed(() => {
  const visibleCount = Math.ceil(containerHeight.value / props.itemHeight)
  return Math.min(props.items.length, startIndex.value + visibleCount + props.buffer * 2)
})

const visibleItems = computed(() => {
  return props.items.slice(startIndex.value, endIndex.value).map((item, i) => ({
    item,
    index: startIndex.value + i,
  }))
})

const offsetY = computed(() => startIndex.value * props.itemHeight)

const hasMore = computed(() => endIndex.value < props.items.length)

const scrollInfo = computed(() => ({
  scrollTop: scrollTop.value,
  visibleStart: startIndex.value,
  visibleEnd: endIndex.value,
  totalItems: props.items.length,
  direction: scrollTop.value > lastScrollTop.value ? 'down' as const : 'up' as const,
}))

// Methods
const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const newScrollTop = target.scrollTop
  const direction = newScrollTop > lastScrollTop.value ? 'down' : 'up'
  
  scrollTop.value = newScrollTop
  lastScrollTop.value = newScrollTop

  emit('scroll', newScrollTop, direction)

  // Infinite scroll detection
  const scrollBottom = target.scrollHeight - target.scrollTop - target.clientHeight
  if (scrollBottom < props.loadMoreThreshold && props.items.length > 0) {
    emit('loadMore')
  }
}

const scrollToIndex = (index: number, behavior: ScrollBehavior = 'auto') => {
  if (containerRef.value) {
    containerRef.value.scrollTo({
      top: index * props.itemHeight,
      behavior,
    })
  }
}

const scrollToTop = (behavior: ScrollBehavior = 'auto') => {
  if (containerRef.value) {
    containerRef.value.scrollTo({ top: 0, behavior })
  }
}

const scrollToBottom = (behavior: ScrollBehavior = 'auto') => {
  if (containerRef.value) {
    containerRef.value.scrollTo({
      top: totalHeight.value,
      behavior,
    })
  }
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
    })
    resizeObserver.observe(containerRef.value)
  }
})

onUnmounted(() => {
  if (resizeObserver) {
    resizeObserver.disconnect()
  }
})

// Expose methods for parent
defineExpose({
  scrollToIndex,
  scrollToTop,
  scrollToBottom,
  scrollInfo,
  containerRef,
})
</script>

<template>
  <div
    ref="containerRef"
    class="virtual-scroller"
    @scroll="onScroll"
  >
    <div
      class="virtual-scroller-inner"
      :style="{ height: totalHeight + 'px' }"
    >
      <div
        class="virtual-scroller-content"
        :style="{ transform: `translateY(${offsetY}px)` }"
      >
        <slot
          v-for="{ item, index } in visibleItems"
          :key="index"
          :item="item"
          :index="index"
        />
      </div>
    </div>
  </div>
</template>

<style scoped>
.virtual-scroller {
  overflow-y: auto;
  height: 100%;
  position: relative;
}

.virtual-scroller-inner {
  position: relative;
  width: 100%;
}

.virtual-scroller-content {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
}
</style>