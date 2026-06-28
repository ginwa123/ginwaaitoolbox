<script setup lang="ts">
import { ref, provide, onMounted, onUnmounted } from 'vue'
import * as api from './api'

// LLM processing state - provided to child components
// Object mapping sessionId to processing status (using object instead of Set for better reactivity)
const processingState = ref<Record<string, boolean>>({})
provide('processingState', processingState)

// SSE connection for worker events. Now a `SseClient` (the
// shared auto-reconnecting wrapper in `helpers/sseClient.ts`)
// instead of a raw `EventSource` — see `docs/sse-reconnect-plan.md`
// §1.1 for the two bugs this fixes (timer leak on unmount, stale
// timer closing a working connection).
let workersSse: api.SseClient | null = null

// Handle worker event from SSE
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

// Initialize SSE connection for workers. The SseClient handles
// exponential backoff (1s → 30s, full jitter), visibility-aware
// pausing, and the `online` event fast-path, so we no longer
// need the hand-rolled `setTimeout(reconnect, 5000)` — that
// naive retry is exactly what the SseClient replaces.
const initWorkersSse = async () => {
  // Clean up existing connection
  if (workersSse) {
    workersSse.close()
  }

  workersSse = await api.createWorkersSseConnection(
    handleWorkerEvent,
    // onError is only invoked on TERMINAL failure (state went
    // to `failed`). Transient errors are retried internally and
    // do not fire this callback — the old behavior of logging
    // every retry attempt was misleading, since a reconnect
    // is not an error from the user's perspective.
    (error) => {
      console.error('[App] Workers SSE failed permanently:', error)
    },
    () => {
      console.log('[App] Workers SSE connected')
      // Initial fetch to sync state. This re-runs on every
      // successful reconnect, which is what we want — a
      // server restart that loses in-memory state should be
      // re-synced on the next open.
      fetchInitialWorkers()
    },
  )
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

onMounted(() => {
  initWorkersSse()
})

onUnmounted(() => {
  if (workersSse) {
    // SseClient.close() removes its visibility/online listeners
    // and cancels any pending retry timer — no more timer leak
    // (the previous hand-rolled setTimeout could fire after
    // unmount and create a dangling EventSource).
    workersSse.close()
    workersSse = null
  }
})
</script>

<template>
  <router-view />
</template>
