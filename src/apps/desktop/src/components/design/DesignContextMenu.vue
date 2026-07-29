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
      <!-- Menu items land here in Chunk 5 -->
    </div>
  </Teleport>
</template>