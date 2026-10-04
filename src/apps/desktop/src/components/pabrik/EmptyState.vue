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
    style="background-color: var(--semantic-content-bg); border: 1px dashed var(--color-border)"
    data-testid="empty-state"
  >
    <!-- The slot exists so a caller can put a real SVG mark here instead of
         a glyph — the right sidebar's forge empty states. Falls back to the
         `glyph` prop, so every existing caller is byte-identical. -->
    <div
      class="font-mono text-title-lg mb-3"
      style="color: var(--semantic-text-dim)"
      aria-hidden="true"
    >
      <slot name="glyph">{{ glyph }}</slot>
    </div>
    <h3 class="text-body font-semibold mb-1.5" style="color: var(--semantic-text)">{{ title }}</h3>
    <p class="text-dense max-w-sm leading-relaxed" style="color: var(--semantic-text-muted)">
      {{ description }}
    </p>
    <button
      v-if="ctaLabel"
      type="button"
      @click="ctaAction"
      class="mt-5 px-4 h-8 rounded-md text-body font-medium border transition-colors duration-150"
      style="
        border-color: var(--color-violet);
        color: var(--color-violet);
        background-color: transparent;
      "
    >
      {{ ctaLabel }}
    </button>
  </div>
</template>
