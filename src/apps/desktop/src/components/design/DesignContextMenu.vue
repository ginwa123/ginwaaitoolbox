<!--
  DesignContextMenu — shared right-click menu for the design canvas
  and layers panel. Empty shell in this commit; menu items land in
  Chunk 5 (the 7-item table: Group, Select all, ───, Bring/Send to
  front/back, ───, Delete).

  Why Teleport to body: the menu must float above the design canvas
  (which has `transform: scale()` for zoom + `overflow: auto`). A
  plain div child of either parent would be clipped by the canvas's
  overflow. Teleporting to body escapes the stacking context.

  Pattern reference: src/apps/desktop/src/components/git/GitChanges.vue
  uses the same Teleport approach for the git file context menu.
-->
<script setup lang="ts">
defineProps<{
  visible: boolean
  x: number
  y: number
  targetIds: string[]
}>()

defineEmits<{
  close: []
  // Chunk 2 wires this single emit; the full 7-item table
  // (Select all / Bring / Send / Delete) lands in Chunk 5.
  group: [targetIds: string[]]
}>()
</script>

<template>
  <Teleport v-if="visible" to="body">
    <div
      class="fixed z-50 py-1 rounded-md shadow-lg"
      :style="{
        left: `${x}px`,
        top: `${y}px`,
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
        :disabled="targetIds.length < 2"
        data-testid="design-context-menu-group"
        @click="$emit('group', [...targetIds])"
      >
        <span>Group selection</span>
        <span class="text-xs" style="color: var(--semantic-text-dim);">⌘G</span>
      </button>
    </div>
  </Teleport>
</template>