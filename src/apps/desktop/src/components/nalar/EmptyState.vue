<script setup lang="ts">
defineProps<{
  glyph: string
  title: string
  description: string
  ctaLabel?: string
  ctaAction?: () => void
}>()
</script>

<template>
  <div
    class="flex flex-col items-center justify-center text-center py-12 px-6 rounded-md"
    style="background-color: var(--semantic-content-bg); border: 1px dashed var(--color-border);"
    data-testid="empty-state"
  >
    <div
      class="font-mono text-2xl mb-3"
      style="color: var(--semantic-text-dim);"
      aria-hidden="true"
    >{{ glyph }}</div>
    <h3
      class="text-sm font-semibold mb-1.5"
      style="color: var(--semantic-text);"
    >{{ title }}</h3>
    <p
      class="text-xs max-w-sm leading-relaxed"
      style="color: var(--semantic-text-muted);"
    >{{ description }}</p>
    <button
      v-if="ctaLabel"
      type="button"
      @click="ctaAction"
      class="mt-5 px-4 h-8 rounded-md text-sm font-medium border transition-colors duration-150"
      style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
    >{{ ctaLabel }}</button>
  </div>
</template>
