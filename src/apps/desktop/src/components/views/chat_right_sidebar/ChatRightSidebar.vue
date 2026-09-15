<script setup lang="ts">
import { ref, watch } from 'vue'
import SidebarDiffPanel from './SidebarDiffPanel.vue'
import type { DiffSelection } from './parseUnifiedDiff'

const props = defineProps<{
  cwd: string
  open: boolean
  width: number
  minWidth?: number
  maxWidth?: number
  /** Attached PR URL — switches the panel to PR-changes mode. */
  prUrl?: string
  /** Effective provider for the attached PR. */
  prProvider?: string
}>()

const emit = defineEmits<{
  'update:open': [open: boolean]
  'update:width': [width: number]
  refresh: []
  'show-diff': [selection: DiffSelection]
}>()

const panelRef = ref<InstanceType<typeof SidebarDiffPanel> | null>(null)

const isResizing = ref(false)

const startResize = (e: MouseEvent) => {
  e.preventDefault()
  isResizing.value = true
  const startX = e.clientX
  const startWidth = props.width
  const min = props.minWidth ?? 200
  const max = props.maxWidth ?? 600

  const onMove = (ev: MouseEvent) => {
    const next = startWidth - (ev.clientX - startX)
    emit('update:width', Math.max(min, Math.min(max, next)))
  }
  const onUp = () => {
    isResizing.value = false
    window.removeEventListener('mousemove', onMove)
    window.removeEventListener('mouseup', onUp)
  }
  window.addEventListener('mousemove', onMove)
  window.addEventListener('mouseup', onUp)
}

const close = () => emit('update:open', false)

watch(
  () => props.cwd,
  () => {
    panelRef.value?.loadGitStatus()
  },
)

defineExpose({
  refresh: () => panelRef.value?.loadGitStatus(),
  reloadDiff: () => panelRef.value?.loadDiff(),
})
</script>

<template>
  <aside
    v-if="open"
    class="chat-right-sidebar shrink-0 h-full relative hidden lg:flex flex-col min-h-0"
    :style="{
      width: width + 'px',
      backgroundColor: 'var(--semantic-sidebar-bg)',
      borderLeft: '1px solid var(--color-border)',
    }"
    data-testid="chat-right-sidebar"
  >
    <div
      class="absolute left-0 top-0 bottom-0 w-1 cursor-col-resize hover:opacity-100 opacity-0 hover:bg-[var(--color-violet)]"
      style="background: transparent"
      data-testid="chat-right-sidebar-resize"
      @mousedown="startResize"
    />
    <div
      class="flex items-center gap-2 px-3 h-10 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <span class="text-xs font-semibold flex-1" style="color: var(--semantic-text)">
        Changes
      </span>
      <button
        type="button"
        class="w-6 h-6 rounded flex items-center justify-center hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Close sidebar"
        aria-label="Close sidebar"
        data-testid="chat-right-sidebar-close"
        @click="close"
      >
        ✕
      </button>
    </div>
    <div class="flex-1 min-h-0">
      <SidebarDiffPanel
        ref="panelRef"
        :cwd="cwd"
        :pr-url="prUrl"
        :pr-provider="prProvider"
        @refresh="() => emit('refresh')"
        @show-diff="(selection) => emit('show-diff', selection)"
      />
    </div>
  </aside>
</template>
