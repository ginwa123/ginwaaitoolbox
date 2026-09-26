<!--
  SessionSlider.vue — per-session LLM "still working" indicator.

  Renders a small yellow circle spinner inline in its parent whenever
  `processingState[sessionId]` is true. Owned by `App.vue` via Vue's
  provide/inject (a `Ref<Record<string, boolean>>`); the SSE worker
  event handler in App.vue flips entries true/false so this component
  is reactive for free.

  The spinner uses an inline SVG and native SVG rotation rather than a
  component-scoped CSS border-rotation keyframe. Firefox supports SVG
  animation natively, so the busy indicator does not depend on a CSS
  keyframe being applied to the spinner element.

  Reduced motion
  ──────────────
  When the user requests reduced motion, the native rotation is not
  rendered and the SVG becomes a static muted ring instead.
-->
<script setup lang="ts">
import { useMediaQuery } from '@vueuse/core'
import { computed, inject, ref, type Ref } from 'vue'

const props = withDefaults(
  defineProps<{
    sessionId: string
    /** A distinct `data-testid` lets each sidebar surface target its own spinner. */
    testId?: string
  }>(),
  { testId: 'session-slider' },
)

const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref({}) as Ref<Record<string, boolean>>,
)

const isVisible = computed(() => !!processingState.value[props.sessionId])
const prefersReducedMotion = useMediaQuery('(prefers-reduced-motion: reduce)')
</script>

<template>
  <span
    v-if="isVisible"
    class="session-spinner"
    :data-testid="testId"
    role="status"
    aria-busy="true"
    aria-live="polite"
    aria-label="Agent is working"
  >
    <svg
      class="session-spinner__svg"
      data-testid="session-slider-track"
      viewBox="0 0 20 20"
      aria-hidden="true"
    >
      <circle class="session-spinner__track" cx="10" cy="10" r="8" pathLength="100" />
      <g data-testid="session-spinner-rotor">
        <circle class="session-spinner__arc" cx="10" cy="10" r="8" pathLength="100" />
        <animateTransform
          v-if="!prefersReducedMotion"
          data-testid="session-spinner-motion"
          attributeName="transform"
          type="rotate"
          from="0 10 10"
          to="360 10 10"
          dur="0.8s"
          repeatCount="indefinite"
        />
      </g>
    </svg>
  </span>
</template>

<style scoped>
.session-spinner {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 20px;
  height: 20px;
  flex-shrink: 0;
  pointer-events: none;
}

.session-spinner__svg {
  display: block;
  width: 16px;
  height: 16px;
  overflow: visible;
}

.session-spinner__track,
.session-spinner__arc {
  fill: none;
  stroke: var(--color-yellow);
  stroke-width: 2.5;
}

.session-spinner__track {
  opacity: 0.22;
}

.session-spinner__arc {
  stroke-linecap: round;
  stroke-dasharray: 25 75;
}

@media (prefers-reduced-motion: reduce) {
  .session-spinner__arc {
    stroke-dasharray: 100 0;
    opacity: 0.7;
  }
}
</style>
