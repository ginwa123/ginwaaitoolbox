<script setup lang="ts">
/**
 * Shared right-click menu with a single "Open in new tab" item.
 * Teleported to body so overflow ancestors (virtual scrollers,
 * kanban columns) never clip it. Hosts own the payload and wire
 * `@open` to their window.open call; visibility is `v-if` on the
 * host's menu state.
 */
defineProps<{
  x: number
  y: number
}>()

const emit = defineEmits<{
  open: []
}>()
</script>

<template>
  <Teleport to="body">
    <div
      data-testid="open-new-tab-menu"
      role="menu"
      class="fixed z-50 py-1 text-xs rounded-lg shadow-lg"
      :style="{
        left: `${x}px`,
        top: `${y}px`,
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
      @click.stop
    >
      <button
        type="button"
        role="menuitem"
        data-testid="open-new-tab-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('open')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span>Open in new tab
      </button>
    </div>
  </Teleport>
</template>
