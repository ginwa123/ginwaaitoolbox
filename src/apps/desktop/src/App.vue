<script setup lang="ts">
import { ref, provide, onMounted, onUnmounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import * as api from './api'
import { installSseBus, useSseBus } from './helpers/sseBus'
import { useNavigationStore } from './stores/navigation'

// ─── Global wheel-zoom suppressor ──────────────────────────────────────
//
// The desktop webview (WebKitGTK / WKWebView / WebView2) interprets
// `Ctrl+wheel` and `metaKey+wheel` (trackpad pinch on macOS emits
// wheel-with-ctrlKey) as PAGE-level zoom — scaling the ENTIRE app shell
// (sidebar + main + every component). That conflicts with the design
// canvas's own cursor-anchored zoom (`DesignView.vue::handleCanvasWheel`,
// line 1844), which only scales the canvas via `transform: scale()`.
//
// This capture-phase listener cancels the browser's default zoom by
// calling `preventDefault()` on every `wheel` event that carries a
// zoom modifier. We deliberately do NOT call `stopPropagation()` so the
// design canvas's bubble-phase `@wheel` handler still fires and performs
// its own cursor-anchored zoom. The handler is a no-op for events
// without zoom modifiers, so plain scroll/wheel behaviour (page scroll,
// sidebar scroll, etc.) is preserved.
//
// We pair this with `touch-action: manipulation` on html/body
// (`style.css`) to block the mobile/touch pinch gesture at the CSS
// layer too, and `maximum-scale=1.0, user-scalable=no` on the viewport
// meta (`index.html`) to block the host webview's own zoom surface.
const handleGlobalWheel = (event: WheelEvent): void => {
  if (!event.ctrlKey && !event.metaKey) return
  event.preventDefault()
}

// LLM processing state - provided to child components
// Object mapping sessionId to processing status (using object instead of Set for better reactivity)
const processingState = ref<Record<string, boolean>>({})
provide('processingState', processingState)

// Handle worker event from the SSE bus. Migrated from an App.vue-owned
// SseClient (Chunk 5 of the unify-SSE plan): the bus now owns the
// `/api/events?channels=workers,sessions,kanban` connection, and App.vue
// only subscribes to the `worker` channel via `bus.on('worker', cb)`.
//
// The previous per-app `createUnifiedSseConnection` factory was retired
// with the unify-SSE plan — see `docs/sse-reconnect-plan.md` §1.1 for
// the two bugs the SseClient it used to wrap fixes (timer leak on
// unmount, stale timer closing a working connection).
const handleWorkerEvent = (event: api.WorkerEvent) => {
  console.log('[App] Worker event:', event)

  if (event.action === 'deleted') {
    // Remove session from processing state
    const sessionId = event.session_id || event.id
    if (sessionId && processingState.value[sessionId]) {
      const newState = { ...processingState.value }
      delete newState[sessionId]
      processingState.value = newState
    }
  } else {
    // created or updated - add to processing state
    const sessionId = event.session_id || event.id
    if (sessionId) {
      processingState.value = {
        ...processingState.value,
        [sessionId]: true,
      }
    }
  }
}

// Fetch initial worker state (fallback for when SSE connection starts)
const fetchInitialWorkers = async () => {
  try {
    const { workers } = await api.getWorkers(undefined, 50)
    const newState: Record<string, boolean> = {}
    for (const worker of workers) {
      const sessionId = worker.session_id || worker.id
      if (sessionId) {
        newState[sessionId] = true
      }
    }
    processingState.value = newState
  } catch (err) {
    console.error('Failed to fetch initial workers:', err)
  }
}

// Check if a session is processing
const isProcessing = (sessionId: string) => !!processingState.value[sessionId]

let offWorker: (() => void) | null = null

onMounted(() => {
  // Install the global wheel-zoom suppressor in CAPTURE phase so it
  // runs before any bubble-phase `@wheel` handler on child components.
  // The host webview's page-zoom default fires AT THE PHASE END, so a
  // capture-phase `preventDefault()` is the only place that reliably
  // cancels it across the entire app shell (sidebar, kanban, chat,
  // settings, etc.). Child component `@wheel` listeners (e.g.
  // DesignView's `handleCanvasWheel`) still fire normally because we
  // do NOT call `stopPropagation()`.
  window.addEventListener('wheel', handleGlobalWheel, { passive: false, capture: true })

  // `installSseBus(_app?: App)` takes an optional `App` parameter for
  // future `provide()` use; the module-singleton implementation
  // doesn't use it, so we pass nothing. Idempotent: a second call
  // (e.g. HMR re-mount, or App.vue's own install from `main.ts`
  // mounting first) returns the same singleton.
  const bus = installSseBus()
  offWorker = bus.on('worker', handleWorkerEvent)

  // Wire the frontendLogClient's route/session context callbacks
  // AFTER Vue router is alive and the navigation store is ready.
  // `main.ts` installed the client with no-op stubs
  // (getRoutePath/getSessionId both return null); we replace them
  // here with live getters. The logCtx object lives on
  // `window.__nalarLogCtx` (set by main.ts) so it survives the
  // remount — only the callback functions need to point at the
  // current component scope's reactive refs.
  const route = useRoute()
  const navigationStore = useNavigationStore()
  const logCtx = (
    window as unknown as {
      __nalarLogCtx:
        | {
            getRoutePath: () => string | null
            getSessionId: () => string | null
          }
        | null
        | undefined
    }
  ).__nalarLogCtx
  if (logCtx) {
    logCtx.getRoutePath = () => `${route.path}${route.fullPath}`
    logCtx.getSessionId = () => navigationStore.sessionId || null
  }

  // Re-sync `processingState` from the DB on every (re)connect. The
  // bus's underlying SseClient may have been `connecting` for a while
  // (server restart, network drop), so the previous in-memory state
  // (built from earlier `worker` events) is stale and may include
  // sessions that no longer exist or omit new ones.
  //
  // `{ immediate: true }` covers the fast path where the SseClient
  // is already `'open'` by the time the watcher is registered (the
  // SseClient defers its first `start()` via `setTimeout(0)`, so
  // there's a race between bus install and watch registration).
  watch(
    () => bus.state.value,
    (s) => {
      if (s === 'open') void fetchInitialWorkers()
    },
    { immediate: true },
  )
})

onUnmounted(() => {
  // Remove the global wheel-zoom suppressor. Symmetric with the
  // `addEventListener` in `onMounted` — same `{ passive: false,
  // capture: true }` flags so the listener identity matches exactly.
  // Without this, HMR re-mounts and route-level remounts would
  // accumulate stale listeners (each calling `preventDefault()` on
  // every ctrl+wheel).
  window.removeEventListener('wheel', handleGlobalWheel, { capture: true })

  // Unsubscribe the worker listener first so any in-flight event
  // dispatched during the unmount window doesn't try to mutate
  // unmounted reactive state.
  if (offWorker) {
    offWorker()
    offWorker = null
  }
  // Close the bus. Forwards to all underlying SseClients (global +
  // any per-session). Terminal — removes visibility/online listeners,
  // cancels retry timers (no timer leak that would create a dangling
  // EventSource), and nulls the singleton so a subsequent `installSseBus`
  // rebuilds from scratch.
  useSseBus().close()
})
</script>

<template>
  <router-view />
</template>
