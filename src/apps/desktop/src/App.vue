<script setup lang="ts">
import { ref, provide, onMounted, onUnmounted } from 'vue'
import * as api from './api'

// LLM processing state - provided to child components
// Object mapping sessionId to processing status (using object instead of Set for better reactivity)
const processingState = ref<Record<string, boolean>>({})
provide('processingState', processingState)

// SSE connection for worker events
let workersEventSource: EventSource | null = null

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

// Initialize SSE connection for workers
const initWorkersSse = () => {
  // Clean up existing connection
  if (workersEventSource) {
    workersEventSource.close()
  }
  
  workersEventSource = api.createWorkersSseConnection(
    handleWorkerEvent,
    (error) => {
      console.error('[App] Workers SSE error:', error)
      // Reconnect after delay on error
      setTimeout(initWorkersSse, 5000)
    },
    () => {
      console.log('[App] Workers SSE connected')
      // Initial fetch to sync state
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
  if (workersEventSource) {
    workersEventSource.close()
    workersEventSource = null
  }
})
</script>

<template>
  <router-view />
</template>
