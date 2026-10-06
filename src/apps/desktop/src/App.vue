<script setup lang="ts">
import { ref, provide, onMounted, onUnmounted } from 'vue'
import { useRoute } from 'vue-router'
import * as api from './api'
import TopLoadingBar from './components/shell/TopLoadingBar.vue'
import { installSseBus, useSseBus, __getSseBusGlobalClient } from './helpers/sseBus'
import { useTabsStore } from './stores/tabs'
import { useNavigationStore } from './stores/navigation'
import { useDocumentTitle } from './composables/useDocumentTitle'

// LLM processing state - provided to child components
// Object mapping sessionId to processing status (using object instead of Set for better reactivity)
const processingState = ref<Record<string, boolean>>({})
provide('processingState', processingState)

// Browser tab title follows the active session / task name.
useDocumentTitle()

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
// Throttled: bus.state flips to 'open' on every reconnect, and without a
// guard each reconnect would refetch workers (the columns/workers storm in
// the Network panel). Skips when the last fetch was <10s ago.
let lastWorkersFetchAt = 0
const fetchInitialWorkers = async () => {
  if (Date.now() - lastWorkersFetchAt < 10_000) return
  lastWorkersFetchAt = Date.now()
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

let offWorker: (() => void) | null = null
let offBusOpen: (() => void) | null = null

onMounted(() => {
  // `installSseBus(_app?: App)` takes an optional `App` parameter for
  // future `provide()` use; the module-singleton implementation
  // doesn't use it, so we pass nothing. Idempotent: a second call
  // (e.g. HMR re-mount, or App.vue's own install from `main.ts`
  // mounting first) returns the same singleton.
  const bus = installSseBus()
  offWorker = bus.on('worker', handleWorkerEvent)

  // Tab titles for chat sessions. Subscribed HERE, next to the install, because
  // children mount before their parent: an AppLayout-side subscription runs
  // before the bus exists and would silently never attach (that is exactly why
  // chat tabs kept the generic "Chat" label after a rename).
  useTabsStore().initTitleFeed()

  // Wire the frontendLogClient's route/session context callbacks
  // AFTER Vue router is alive and the navigation store is ready.
  // `main.ts` installed the client with no-op stubs
  // (getRoutePath/getSessionId both return null); we replace them
  // here with live getters. The logCtx object lives on
  // `window.__pabrikLogCtx` (set by main.ts) so it survives the
  // remount — only the callback functions need to point at the
  // current component scope's reactive refs.
  const route = useRoute()
  const navigationStore = useNavigationStore()
  const logCtx = (
    window as unknown as {
      __pabrikLogCtx:
        | {
            getRoutePath: () => string | null
            getSessionId: () => string | null
          }
        | null
        | undefined
    }
  ).__pabrikLogCtx
  if (logCtx) {
    // route.fullPath already includes path + query + hash — concatenating
    // route.path in front duplicates the path ("/app" + "/app?view=..." =
    // "/app/app?view=..."). Use fullPath alone so logged route_path matches
    // the browser address bar.
    logCtx.getRoutePath = () => route.fullPath
    logCtx.getSessionId = () => navigationStore.sessionId || null
  }

  // Re-sync `processingState` from the DB on every (re)connect. The
  // bus's underlying SseClient may have been `connecting` for a while
  // (server restart, network drop), so the previous in-memory state
  // (built from earlier `worker` events) is stale and may include
  // sessions that no longer exist or omit new ones.
  //
  // Explicit subscription on the underlying SseClient (not a reactive
  // watcher): `onStateChange` fires on every transition including the
  // reconnect path. The immediate check below covers the fast path
  // where the SseClient is already `'open'` by the time this hook runs
  // (the SseClient defers its first `start()` via `setTimeout(0)`, so
  // there's a race between bus install and subscription).
  if (bus.state.value === 'open') void fetchInitialWorkers()
  offBusOpen =
    __getSseBusGlobalClient()?.onStateChange((s) => {
      if (s === 'open') void fetchInitialWorkers()
    }) ?? null
})

onUnmounted(() => {
  // Unsubscribe the worker listener first so any in-flight event
  // dispatched during the unmount window doesn't try to mutate
  // unmounted reactive state.
  if (offWorker) {
    offWorker()
    offWorker = null
  }
  if (offBusOpen) {
    offBusOpen()
    offBusOpen = null
  }
  useTabsStore().disposeTitleFeed()
  // Close the bus. Forwards to all underlying SseClients (global +
  // any per-session). Terminal — removes visibility/online listeners,
  // cancels retry timers (no timer leak that would create a dangling
  // EventSource), and nulls the singleton so a subsequent `installSseBus`
  // rebuilds from scratch.
  useSseBus().close()
})
</script>

<template>
  <TopLoadingBar />
  <router-view />
</template>
