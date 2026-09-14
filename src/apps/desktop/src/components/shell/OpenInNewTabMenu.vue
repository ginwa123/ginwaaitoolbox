<script setup lang="ts">
/**
 * Shared right-click menu for kanban task cards.
 * Teleported to body so overflow ancestors (virtual scrollers,
 * kanban columns) never clip it. Hosts own the payload and wire
 * `@open` (chat) + `@open-details` (task detail) to their
 * window.open calls; visibility is `v-if` on the host's menu state.
 *
 * The details item is opt-in via `showDetails` so sidebar rows
 * (WorkspaceItemTaskRow) keep the single chat item while kanban
 * cards (WorkspaceItemTaskCard) offer both.
 */
defineProps<{
  x: number
  y: number
  showDetails?: boolean
  showStop?: boolean
}>()

const emit = defineEmits<{
  open: []
  openDetails: []
  stop: []
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
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span>Open chat in new tab
      </button>
      <button
        v-if="showDetails"
        type="button"
        role="menuitem"
        data-testid="open-details-new-tab-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('openDetails')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span>Open details in new tab
      </button>
      <button
        v-if="showStop"
        type="button"
        role="menuitem"
        data-testid="stop-agent-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        style="color: var(--color-red);"
        @click="emit('stop')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#9632;</span>Stop agent
      </button>
    </div>
  </Teleport>
</template>
