<!--
  SessionSlider.vue — per-session LLM "still working" indicator.

  Renders a small yellow circle spinner inline in its parent
  whenever `processingState[sessionId]` is true. Owned by `App.vue`
  via Vue's provide/inject (a `Ref<Record<string, boolean>>`); the
  SSE worker event handler in App.vue flips entries true/false so
  this component is reactive for free.

  Where it mounts
  ───────────────
  - ChatsList rows (sidebar): one spinner per row, at the end of
    the chat row — replaces the previous bottom-edge sliding bar.
    The ChatView and SubAgentPeekPanel deliberately do NOT mount
    this component: the sidebar row already signals "this session
    is busy" for the same session, and adding a duplicate spinner
    elsewhere would be redundant (see design memory
    `design-no-redundant-loading-indicators`).
  - WorkspaceItem / WorkspaceItemTaskRow / ProjectsList /
    AgentChatView: same circle, same API.

  Why a circle, not a bottom bar
  ──────────────────────────────
  The bottom sliding bar spans the full row width and draws the eye
  even when the user is reading elsewhere. A compact circle spinner
  marks exactly the busy row without the full-width motion.

  Reduced motion
  ──────────────
  Under `@media (prefers-reduced-motion: reduce)` the spin animation
  is suppressed and the circle renders as a static muted ring —
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
  <span
    v-if="isVisible"
    class="session-spinner"
    :data-testid="testId"
    role="status"
    :aria-busy="true"
    aria-live="polite"
    aria-label="Agent is working"
  >
    <span class="session-spinner__circle" data-testid="session-slider-track" />
  </span>
</template>

<style scoped>
.session-spinner {
  /* Inline circle: sits in the flex row where it's mounted, takes
     no space at all while idle (v-if removes it from the DOM). */
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 20px;
  height: 20px;
  flex-shrink: 0;
  pointer-events: none;
}

.session-spinner__circle {
  width: 14px;
  height: 14px;
  border-radius: 9999px;
  border: 2px solid var(--color-yellow);
  border-top-color: transparent;
  animation: session-spinner-spin 0.8s linear infinite;
}

@keyframes session-spinner-spin {
  to {
    transform: rotate(360deg);
  }
}

@media (prefers-reduced-motion: reduce) {
  .session-spinner__circle {
    animation: none;
    border-top-color: var(--color-yellow);
    opacity: 0.7;
  }
}
</style>
