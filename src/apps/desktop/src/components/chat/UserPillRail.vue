<!-- User-pill rail (2026-09-09 chatview user pill).
     Pure presentational: one pill per user group on the chat's right
     edge. Click (or Enter/Space) emits `jump` with the pill's group
     index + stable key; the host (ChatView) owns scrolling. Uniform
     vertical stack — NOT proportional to message height — so the rail
     stays predictable under VirtualScroller height estimates. -->
<script setup lang="ts">
export interface UserPill {
  groupIndex: number
  key: string
  preview: string
  title: string
}

defineProps<{
  pills: UserPill[]
  activeGroupIndex: number | null
}>()

const emit = defineEmits<{
  jump: [groupIndex: number, key: string]
}>()
</script>

<template>
  <nav
    class="user-pill-rail"
    aria-label="Jump to user messages"
    data-testid="user-pill-rail"
  >
    <button
      v-for="pill in pills"
      :key="pill.key"
      type="button"
      class="user-pill"
      :class="{ 'user-pill--active': pill.groupIndex === activeGroupIndex }"
      :title="pill.title"
      :aria-label="`Jump to message: ${pill.preview}`"
      data-testid="user-pill"
      @click="emit('jump', pill.groupIndex, pill.key)"
    />
  </nav>
</template>

<style scoped>
.user-pill-rail {
  position: absolute;
  right: 6px;
  /* Center on the VISIBLE transcript, not the full wrapper. The wrapper
     is the full column height (the composer floats over its bottom part),
     so plain `top: 50%` sits half a composer-height too low. The dock's
     ResizeObserver publishes its height as `--chat-composer-inset` on the
     chat column (inherited here); subtracting half of it restores the
     visible center. Same contract ChatScrollSlider's track already reads.
     Falls back to plain 50% where the inset is unset (bare-host unit
     mounts, read-only peek panel with no dock). */
  top: calc(50% - var(--chat-composer-inset, 0px) / 2);
  transform: translateY(-50%);
  display: flex;
  flex-direction: column;
  gap: 8px;
  z-index: 20;
  padding: 8px 4px;
  border-radius: 999px;
}

.user-pill {
  width: 24px;
  height: 4px;
  border-radius: 999px;
  padding: 0;
  border: none;
  cursor: pointer;
  background-color: var(--color-border, rgba(255, 255, 255, 0.2));
  opacity: 0.55;
  transition:
    opacity 0.15s ease,
    transform 0.15s ease,
    background-color 0.15s ease;
}

.user-pill:hover,
.user-pill:focus-visible {
  opacity: 1;
  transform: scaleX(1.25);
  background-color: var(--semantic-text-dim, #888);
  outline: none;
}

.user-pill--active {
  opacity: 1;
  background-color: var(--color-violet, #8b5cf6);
}

@media (prefers-reduced-motion: reduce) {
  .user-pill {
    transition: none;
  }
}
</style>
