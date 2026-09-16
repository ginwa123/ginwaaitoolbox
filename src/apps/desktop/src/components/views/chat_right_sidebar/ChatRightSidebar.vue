<script setup lang="ts">
import { ref } from 'vue'
import SidebarDiffPanel from './SidebarDiffPanel.vue'
import TerminalTab from './TerminalTab.vue'
import type { DiffSelection } from './parseUnifiedDiff'

const props = defineProps<{
  cwd: string
  open: boolean
  width: number
  minWidth?: number
  maxWidth?: number
  /** Branch from the bottom status bar (single source of truth).
   * `undefined` while loading — the panel falls back to its own
   * fetched branch. Drilled from ChatView's `sidebarBranch`. */
  branch?: string
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
  'show-diff-list': [files: DiffSelection[]]
}>()

const panelRef = ref<InstanceType<typeof SidebarDiffPanel> | null>(null)

const STORAGE_KEY_PANEL = 'nalar-right-sidebar-panel'

type SidebarPanel = 'changes' | 'terminal'

function loadPanel(): SidebarPanel {
  try {
    const params = new URLSearchParams(window.location.search)
    const q = params.get('sidebar')
    if (q === 'terminal' || q === 'changes') return q
    const saved = localStorage.getItem(STORAGE_KEY_PANEL)
    if (saved === 'terminal' || saved === 'changes') return saved
  } catch {
    // Non-browser (tests/SSR) — fall through to default.
  }
  return 'changes'
}

const activePanel = ref<SidebarPanel>(loadPanel())

const setPanel = (panel: SidebarPanel) => {
  activePanel.value = panel
  try {
    localStorage.setItem(STORAGE_KEY_PANEL, panel)
  } catch {
    // ignore
  }
}

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

// No cwd watcher here: SidebarDiffPanel already watches props.cwd
// itself (clears its tab cache + reloads). A second fetch from this
// level doubled every worktree switch and the two concurrent
// getGitChanges calls could resolve out of order (stale branch wins).

defineExpose({
  // Reload the panel's current tab (PR tab re-syncs merge state too).
  // Falls back to git status for older panel refs without refresh().
  refresh: () => {
    const panel = panelRef.value as unknown as {
      refresh?: () => unknown
      loadGitStatus?: () => unknown
    } | null
    if (panel?.refresh) return panel.refresh()
    return panel?.loadGitStatus?.()
  },
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
    <div
      class="flex items-center gap-1 px-3 pt-2 shrink-0"
      role="tablist"
      aria-label="Right sidebar panel"
    >
      <button
        type="button"
        role="tab"
        :aria-selected="activePanel === 'changes'"
        class="flex-1 text-center text-xs rounded-t px-2 py-1.5"
        :style="
          activePanel === 'changes'
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text)'
            : 'color: var(--semantic-text-dim)'
        "
        data-testid="chat-right-sidebar-tab-changes"
        @click="setPanel('changes')"
      >
        Files changed
      </button>
      <button
        type="button"
        role="tab"
        :aria-selected="activePanel === 'terminal'"
        class="flex-1 text-center text-xs rounded-t px-2 py-1.5"
        :style="
          activePanel === 'terminal'
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text)'
            : 'color: var(--semantic-text-dim)'
        "
        data-testid="chat-right-sidebar-tab-terminal"
        @click="setPanel('terminal')"
      >
        ⌁ Terminal
      </button>
    </div>
    <div class="flex-1 min-h-0">
      <!-- Both panels stay mounted (v-show, not v-if) so the PTY
      session survives tab switches; only the visible one paints. -->
      <div v-show="activePanel === 'terminal'" class="h-full min-h-0">
        <TerminalTab :cwd="cwd" />
      </div>
      <div v-show="activePanel === 'changes'" class="h-full min-h-0">
        <SidebarDiffPanel
          ref="panelRef"
          :cwd="cwd"
          :branch="branch"
          :pr-url="prUrl"
          :pr-provider="prProvider"
          @refresh="() => emit('refresh')"
          @show-diff="(selection) => emit('show-diff', selection)"
          @show-diff-list="(files) => emit('show-diff-list', files)"
        />
      </div>
    </div>
  </aside>
</template>
