<!--
  SseStatusBadge.vue

  A small inline pill that surfaces the GLOBAL SSE connection state
  held by the SSE bus (`helpers/sseBus.ts`). Reads `bus.state`
  reactively and renders NOTHING for the common case (`open`) so the
  chat UI is unchanged when the connection is healthy.

  Visible states
  ──────────────
  - `connecting`    → grey pill "Connecting…"
  - `reconnecting`  → amber pill "Reconnecting… (attempt N)"
  - `failed`        → red pill "Connection lost"
  - `open`, `closed` → hidden (default)

  Why the badge self-subscribes
  ─────────────────────────────
  Before this chunk the badge took a `client: SseClient` prop. After
  Chunks 1–7 the desktop app has ONE global SseClient owned by the
  bus; per-chat clients are gone. Hard-coding the bus as the data
  source is simpler and matches the rest of the app:

    1. No parent has to thread a client reference through
    2. The badge reflects the same connection that drives every other
       SSE consumer (chats list, workspace store, sub-agent peek)
    3. Mounting order is trivial — `App.vue` installs the bus in
       `onMounted` (Chunk 5), and every component mounted after that
       can call `useSseBus()` safely

  The badge counts reconnect attempts locally (the bus's state
  ShallowRef exposes only the state, not the attempt number, so we
  track it ourselves: bump on every `reconnecting` transition,
  reset on `open`/`closed`).

  Requires `useSseBus()` — the bus must be installed before this
  component mounts. `App.vue` does the install.
-->
<script setup lang="ts">
import { onUnmounted, ref, watch } from 'vue'

import { useSseBus } from '../../helpers/sseBus'
import type { SseState } from '../../helpers/sseClient'

const bus = useSseBus()
const state = ref<SseState>(bus.state.value)
const attempt = ref(0)

// `bus.state` is a `ShallowRef<SseState>`. Vue 3 doesn't expose
// `ref.watch(...)` (that's a Vue 2 / pinia idiom), so use the
// standalone `watch()` from 'vue' with `{ immediate: true }` so the
// initial render reads the right state without waiting for the first
// transition. The returned stop-handle tears down the watcher in
// `onUnmounted`.
const stop = watch(
  bus.state,
  (s) => {
    state.value = s
    // Bump the attempt counter on every reconnect; reset once the
    // connection recovers or the bus is torn down. We track this
    // locally because the bus's state ShallowRef does NOT expose the
    // underlying `SseClient`'s `info.attempt` — only the state name.
    if (s === 'reconnecting') {
      attempt.value += 1
    } else if (s === 'open' || s === 'closed') {
      attempt.value = 0
    }
  },
  { immediate: true },
)

onUnmounted(() => {
  stop()
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
