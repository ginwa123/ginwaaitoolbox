<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import SidebarDiffView from './SidebarDiffView.vue'
import type { ParsedDiffLine } from './parseUnifiedDiff'

/**
 * One lazily-mounted file section of the stacked center diff. The shell
 * (id anchor + content-visibility sizing) renders immediately so scroll
 * position stays stable; the heavy SidebarDiffView mounts when the
 * section nears the viewport (400px prefetch margin). A fixed-height
 * placeholder holds layout until then.
 */
const props = defineProps<{
  sectionId: string
  path: string
  lines: ParsedDiffLine[]
  added: number
  removed: number
  staged?: boolean
  error?: string | null
  cwd: string
}>()

const emit = defineEmits<{
  open: [payload: { path: string; line?: number }]
  retry: []
  'submit-review': [message: string]
}>()

const isMounted = ref(false)
const rootEl = ref<HTMLElement | null>(null)
let observer: IntersectionObserver | null = null

onMounted(() => {
  const el = rootEl.value
  if (!el || typeof IntersectionObserver === 'undefined') {
    // No observer (jsdom/tests) — mount immediately.
    isMounted.value = true
    return
  }
  observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          isMounted.value = true
          observer?.disconnect()
          observer = null
          break
        }
      }
    },
    { rootMargin: '400px 0px' },
  )
  observer.observe(el)
})

onUnmounted(() => {
  observer?.disconnect()
  observer = null
})
</script>

<template>
  <section
    ref="rootEl"
    :id="sectionId"
    :data-path="props.path"
    data-testid="center-diff-section"
    style="content-visibility: auto; contain-intrinsic-size: auto 400px"
  >
    <div
      v-if="!isMounted"
      data-testid="center-diff-placeholder"
      style="min-height: 200px"
    />
    <SidebarDiffView
      v-else
      :path="path"
      :lines="lines"
      :added="added"
      :removed="removed"
      :staged="staged"
      :loading="false"
      :error="error ?? null"
      :cwd="cwd"
      :show-back="false"
      @open="(payload) => emit('open', payload)"
      @retry="() => emit('retry')"
      @submit-review="(message) => emit('submit-review', message)"
    />
  </section>
</template>
