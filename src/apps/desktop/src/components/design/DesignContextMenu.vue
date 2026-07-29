<!--
  DesignContextMenu — shared right-click menu for the design canvas
  and layers panel. Full 7-item table per the right-click group menu
  plan (Chunk 5).

  Items (in display order):
    1. Group selection      (Cmd+G)
    2. Select all           (Cmd+A)
    ─── separator
    3. Bring to front       (Cmd+Shift+])
    4. Bring forward        (Cmd+])
    5. Send backward        (Cmd+[)
    6. Send to back         (Cmd+Shift+[)
    ─── separator
    7. Delete               (Backspace)

  Why Teleport to body: the menu must float above the design canvas
  (which has `transform: scale()` for zoom + `overflow: auto`). A
  plain div child of either parent would be clipped by the canvas's
  overflow. Teleporting to body escapes the stacking context.

  Pattern reference: src/apps/desktop/src/components/git/GitChanges.vue
  uses the same Teleport approach for the git file context menu.

  Edge clamping: if the menu would overflow the right or bottom of the
  viewport, shift it left/up so its right/bottom edge sits 8px inside
  the viewport. Estimated dimensions: 220px wide, 40px per item.
-->
<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  visible: boolean
  x: number
  y: number
  targetIds: string[]
}>()

const emit = defineEmits<{
  close: []
  group: [targetIds: string[]]
  selectAll: []
  bringToFront: [targetIds: string[]]
  bringForward: [targetIds: string[]]
  sendBackward: [targetIds: string[]]
  sendToBack: [targetIds: string[]]
  delete: [targetIds: string[]]
}>()

// Detect platform once at module load so the menu doesn't recompute
// on every render. Linux/Windows shows "Ctrl" + "+"; macOS shows
// unicode glyphs (⌘ ⇧ ⌫).
const isMac = computed(() => navigator.platform.includes('Mac'))
const acc = (mac: string, linux: string): string => (isMac.value ? mac : linux)

const hasSelection = computed(() => props.targetIds.length >= 1)
const canGroup = computed(() => props.targetIds.length >= 2)

// Items dispatched through `v-for` to avoid repeating the same
// button markup 4 times. Each entry maps to one of the design's
// 4 reorder events. The single `reorder` handler below routes to
// the right emit by name.
const reorderItems = computed(() => [
  { id: 'bring-to-front', label: 'Bring to front', acc: acc('⌘⇧]', 'Ctrl+Shift+]'), emitName: 'bringToFront' as const },
  { id: 'bring-forward', label: 'Bring forward', acc: acc('⌘]', 'Ctrl+]'), emitName: 'bringForward' as const },
  { id: 'send-backward', label: 'Send backward', acc: acc('⌘[', 'Ctrl+['), emitName: 'sendBackward' as const },
  { id: 'send-to-back', label: 'Send to back', acc: acc('⌘⇧[', 'Ctrl+Shift+['), emitName: 'sendToBack' as const },
])

// Estimated menu footprint for viewport edge clamping. Counted
// from the items[] below: 7 buttons + 2 separators = 9 rows × 40px
// tall; 220px wide minimum.
const MENU_WIDTH = 220
const MENU_ROW_HEIGHT = 40
const MENU_ROWS = 9
const VIEWPORT_MARGIN = 8

const edgeClampedStyle = computed(() => {
  let x = props.x
  let y = props.y
  const menuHeight = MENU_ROW_HEIGHT * MENU_ROWS
  if (x + MENU_WIDTH > window.innerWidth - VIEWPORT_MARGIN) {
    x = Math.max(VIEWPORT_MARGIN, window.innerWidth - MENU_WIDTH - VIEWPORT_MARGIN)
  }
  if (y + menuHeight > window.innerHeight - VIEWPORT_MARGIN) {
    y = Math.max(VIEWPORT_MARGIN, window.innerHeight - menuHeight - VIEWPORT_MARGIN)
  }
  return {
    left: `${x}px`,
    top: `${y}px`,
  }
})

function dispatchReorder(item: typeof reorderItems.value[number]): void {
  // Switch on emitName (typed `as const`) so TS narrows the
  // emit() call to the matching overload. A simple
  // `emit(item.emitName, ...)` is rejected by TS2769 because the
  // union of emit names doesn't auto-narrow to a single overload.
  switch (item.emitName) {
    case 'bringToFront': emit('bringToFront', [...props.targetIds]); return
    case 'bringForward': emit('bringForward', [...props.targetIds]); return
    case 'sendBackward': emit('sendBackward', [...props.targetIds]); return
    case 'sendToBack': emit('sendToBack', [...props.targetIds]); return
  }
}
</script>

<template>
  <Teleport v-if="visible" to="body">
    <div
      class="fixed z-50 py-1 rounded-md shadow-lg"
      :style="{
        ...edgeClampedStyle,
        backgroundColor: 'var(--semantic-sidebar-bg)',
        border: '1px solid var(--color-border)',
        minWidth: '220px',
      }"
      data-testid="design-context-menu"
      @click.stop
    >
      <button
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!canGroup"
        data-testid="design-context-menu-group"
        @click="emit('group', [...targetIds])"
      >
        <span>Group selection</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ acc('⌘G', 'Ctrl+G') }}</span>
      </button>
      <button
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between"
        style="color: var(--semantic-text);"
        data-testid="design-context-menu-select-all"
        @click="emit('selectAll')"
      >
        <span>Select all</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ acc('⌘A', 'Ctrl+A') }}</span>
      </button>
      <div class="h-px my-1" style="background-color: var(--color-border);" data-testid="design-context-menu-separator-1" />
      <button
        v-for="item in reorderItems"
        :key="item.id"
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!hasSelection"
        :data-testid="`design-context-menu-${item.id}`"
        @click="dispatchReorder(item)"
      >
        <span>{{ item.label }}</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ item.acc }}</span>
      </button>
      <div class="h-px my-1" style="background-color: var(--color-border);" data-testid="design-context-menu-separator-2" />
      <button
        type="button"
        class="w-full px-4 py-2 text-sm text-left transition-colors hover:opacity-80 flex items-center justify-between disabled:opacity-50 disabled:cursor-not-allowed"
        style="color: var(--semantic-text);"
        :disabled="!hasSelection"
        data-testid="design-context-menu-delete"
        @click="emit('delete', [...targetIds])"
      >
        <span>Delete</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">{{ acc('⌫', 'Del') }}</span>
      </button>
    </div>
  </Teleport>
</template>