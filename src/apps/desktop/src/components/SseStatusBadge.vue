<!--
  SseStatusBadge.vue

  A small inline pill that surfaces the connection state of an
  `api.SseClient`. Driven by the SseClient's `onStateChange` API
  (see `helpers/sseClient.ts`). Renders NOTHING for the common
  case (`open`) so the chat UI is unchanged when the connection
  is healthy.

  Visible states
  ──────────────
  - `connecting`    → grey pill "Connecting…"
  - `reconnecting`  → amber pill "Reconnecting… (attempt N)"
  - `failed`        → red pill "Connection lost — Retry"
  - `open`, `closed` → hidden (default)

  Why a separate component
  ────────────────────────
  The SseClient's `onStateChange(cb)` returns an unsubscribe
  function. To avoid leaking listeners when the parent component
  re-renders with a new client reference, the badge:
    1. Holds the unsubscribe function in a setup-scope variable
    2. Watches the `client` prop and re-subscribes when it
       changes
    3. Cleans up the listener in `onUnmounted`

  This way, swapping one SseClient for another (e.g. on session
  change) automatically unsubscribes from the old one and
  subscribes to the new one — no manual teardown in the parent.
-->
<script setup lang="ts">
import { onUnmounted, ref, watch } from 'vue'

import type { SseClient, SseState } from '../helpers/sseClient'

const props = defineProps<{
  /**
   * The SseClient to observe. When this reference changes
   * (e.g. a new chat is opened, a new session SSE is created),
   * the badge unsubscribes from the old client and
   * subscribes to the new one.
   */
  client: SseClient | null | undefined
}>()

const state = ref<SseState>('connecting')
const attempt = ref(0)
let unsubscribe: (() => void) | null = null

function attach(c: SseClient | null | undefined): void {
  // Always tear down the previous subscription first. This is
  // the defense against the App.vue-style "stale timer
  // closes a working connection" class of bug.
  if (unsubscribe) {
    unsubscribe()
    unsubscribe = null
  }
  if (!c) {
    state.value = 'closed'
    return
  }
  // Read the current state immediately so we don't flash the
  // wrong pill for a frame while waiting for the first state
  // emission.
  state.value = c.getState()
  unsubscribe = c.onStateChange((s, info) => {
    state.value = s
    attempt.value = info.attempt
  })
}

watch(
  () => props.client,
  (next) => attach(next),
  { immediate: true },
)

onUnmounted(() => {
  if (unsubscribe) {
    unsubscribe()
    unsubscribe = null
  }
})
</script>

<template>
  <span
    v-if="state === 'connecting'"
    class="sse-status sse-status--connecting"
    role="status"
    aria-live="polite"
  >
    <span class="sse-status__dot" />
    Connecting…
  </span>
  <span
    v-else-if="state === 'reconnecting'"
    class="sse-status sse-status--reconnecting"
    role="status"
    aria-live="polite"
  >
    <span class="sse-status__dot" />
    Reconnecting<span v-if="attempt > 1"> (attempt {{ attempt }})</span>…
  </span>
  <span
    v-else-if="state === 'failed'"
    class="sse-status sse-status--failed"
    role="status"
    aria-live="assertive"
  >
    <span class="sse-status__dot" />
    Connection lost
  </span>
</template>

<style scoped>
.sse-status {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.15rem 0.6rem;
  border-radius: 9999px;
  font-size: 0.75rem;
  font-weight: 500;
  line-height: 1.2;
  white-space: nowrap;
  user-select: none;
}

.sse-status__dot {
  width: 0.5rem;
  height: 0.5rem;
  border-radius: 9999px;
  background: currentColor;
  flex-shrink: 0;
  /* Subtle pulse so the user sees something is happening. The
     animation is cheap (transform-only) and respects the user's
     reduced-motion preference. */
  animation: sse-pulse 1.4s ease-in-out infinite;
}

.sse-status--connecting {
  background: rgb(148 163 184 / 0.18);
  color: rgb(148 163 184);
}

.sse-status--reconnecting {
  background: rgb(245 158 11 / 0.18);
  color: rgb(245 158 11);
}

.sse-status--failed {
  background: rgb(239 68 68 / 0.18);
  color: rgb(239 68 68);
}

@keyframes sse-pulse {
  0%, 100% { opacity: 1; transform: scale(1); }
  50%      { opacity: 0.45; transform: scale(0.85); }
}

@media (prefers-reduced-motion: reduce) {
  .sse-status__dot {
    animation: none;
  }
}
</style>
