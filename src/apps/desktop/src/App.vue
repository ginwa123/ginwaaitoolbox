<script setup lang="ts">
import { ref, provide, onMounted, onUnmounted } from 'vue'
import * as api from './api'

// LLM processing state - provided to child components
// Object mapping sessionId to processing status (using object instead of Set for better reactivity)
const processingState = ref<Record<string, boolean>>({})
provide('processingState', processingState)

// Check if a session is processing
const isProcessing = (sessionId: string) => !!processingState.value[sessionId]

// Poll for LLM processing status
let processingPollInterval: ReturnType<typeof setInterval> | null = null

const checkLLMProcessing = async () => {
  try {
    const { workers } = await api.getWorkers(undefined, 50)
    const newState: Record<string, boolean> = {}
    for (const worker of workers) {
      // Extract session ID from worker (workers are identified by session_id)
      const sessionId = worker.session_id || worker.worker_id
      if (sessionId) {
        newState[sessionId] = true
      }
    }
    processingState.value = newState
  } catch (err) {
    console.error('Failed to check LLM processing:', err)
    processingState.value = {}
  }
}

const startProcessingPoll = () => {
  checkLLMProcessing()
  if (processingPollInterval) clearInterval(processingPollInterval)
  processingPollInterval = setInterval(checkLLMProcessing, 2000)
}

const stopProcessingPoll = () => {
  if (processingPollInterval) {
    clearInterval(processingPollInterval)
    processingPollInterval = null
  }
}

onMounted(() => {
  startProcessingPoll()
})

onUnmounted(() => {
  stopProcessingPoll()
})
</script>

<template>
  <router-view />
</template>
