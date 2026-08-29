<!--
  SessionSlider.vue — per-session LLM "still working" indicator.

  Renders a thin yellow bar at the bottom edge of its parent
  whenever `processingState[sessionId]` is true. Owned by `App.vue`
  via Vue's provide/inject (a `Ref<Record<string, boolean>>`); the
  SSE worker event handler in App.vue flips entries true/false so
  this component is reactive for free.

  Where it mounts
  ───────────────
  - ChatsList rows (sidebar): one slider per row, just below the
    chat name — replaces the existing yellow spinner circle.
    The ChatView and SubAgentPeekPanel deliberately do NOT mount
    this component: the sidebar row already signals "this session
    is busy" for the same session, and adding a duplicate slider
    elsewhere would be redundant (see design memory
    `design-no-redundant-loading-indicators`).

  Why a slider, not a spinner
  ──────────────────────────
  The existing yellow spinner is a single point — the eye has to
  FIND it on every glance to confirm "the agent is still working".
  A horizontal sliding bar is a continuous motion across the full
  width of the chat row: even when looking at the chat body, the
  peripheral vision catches the slider at the row's edge. Same
  idle/processing signal, lower cognitive cost.

  Reduced motion
  ──────────────
  Under `@media (prefers-reduced-motion: reduce)` the slide animation
  is suppressed and the bar renders as a static muted strip —
  matches the pattern established in `SseStatusBadge.vue:152-156`.

  NOT a network loading indicator
  ───────────────────────────────
  This component is for the LLM WORKER state (long-running SSE
  streaming), not transient HTTP fetches. A separate future
  component would handle "data is fetching" — this one's only job
  is to visualize an active worker on a specific session.
-->
<script setup lang="ts">
import { computed, inject, ref, type Ref } from 'vue'

const props = withDefaults(
  defineProps<{
    sessionId: string
    /**
     * `data-testid` attribute for the root element. Defaults to
     * `'session-slider'`; consumers mounting the component at different
     * DOM levels (workspace row vs. workspace-item row vs. task row)
     * pass distinct ids so existing selector-based tests keep working.
     */
    testId?: string
  }>(),
  { testId: 'session-slider' },
)

// `App.vue:10-11` provides a `processingState: Ref<Record<string,
// boolean>>` keyed by sessionId. The injected ref defaults to an
// empty ref so a unit test that mounts SessionSlider WITHOUT a
// `provide` (e.g. a transitive render path) doesn't crash — it
// just renders nothing.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref({}) as Ref<Record<string, boolean>>,
)

const isVisible = computed(() => !!processingState.value[props.sessionId])
</script>

<template>
  <div
    class="session-slider"
    :class="{ 'session-slider--visible': isVisible }"
    :data-testid="testId"
    role="progressbar"
    :aria-busy="isVisible"
    aria-live="polite"
  >
    <div
      class="session-slider__track"
      data-testid="session-slider-track"
    />
  </div>
</template>

<style scoped>
.session-slider {
  /* Self-positioning: pins itself to the bottom edge of whatever
     `position: relative` parent it's dropped into, inset to match
     the parent's left/right padding (`--row-px`) so the bar starts
     and ends at the same x-position as the row's text content. The
     consumer doesn't need to set any positioning classes — just put
     it as the LAST child of the parent (any subsequent siblings
     would render on top of the slider because z-index defaults to
     auto and the slider is taken out of the flex flow). */
  position: absolute;
  /* `--row-px` mirrors the parent's `px-3` (Tailwind = 0.75rem = 12px)
     so the bar's left/right edge aligns with the row's text content.
     Override per-mount via style="--row-px: 1.5rem" if the consumer
     uses different horizontal padding. */
  left: var(--row-px, 0.75rem);
  right: var(--row-px, 0.75rem);
  bottom: 0;
  height: 2px;
  overflow: hidden;
  background: rgb(0 0 0 / 0.06);
  border-radius: 1px;
  opacity: 0;
  transition: opacity 200ms ease-out;
  pointer-events: none;
}

.session-slider--visible {
  opacity: 1;
}

.session-slider__track {
  position: absolute;
  inset: 0;
  background: var(--color-yellow);
  box-shadow: 0 0 4px rgb(196 178 138 / 0.5);
  animation: session-slider-slide 1.4s cubic-bezier(0.4, 0, 0.2, 1) infinite;
  transform: translateX(-100%);
  width: 100%;
}

@keyframes session-slider-slide {
  0%   { transform: translateX(-100%); }
  100% { transform: translateX(100%); }
}

@media (prefers-reduced-motion: reduce) {
  .session-slider__track {
    animation: none;
    transform: none;
    opacity: 0.55;
  }
}
</style>
