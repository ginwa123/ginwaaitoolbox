<script setup lang="ts">
import { ref, provide, onMounted, onUnmounted } from 'vue'
import * as api from './api'

// LLM processing state - provided to child components
const isLLMProcessing = ref(false)
provide('isLLMProcessing', isLLMProcessing)

// Poll for LLM processing status
let processingPollInterval: ReturnType<typeof setInterval> | null = null

const checkLLMProcessing = async () => {
  try {
    const { workers } = await api.getWorkers(undefined, 50)
    // For testing: show spinner when workers exist
    // Production: use workers.some(w => w.is_running)
    isLLMProcessing.value = workers.length > 0
  } catch (err) {
    console.error('Failed to check LLM processing:', err)
    isLLMProcessing.value = false
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