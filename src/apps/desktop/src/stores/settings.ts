import { defineStore } from 'pinia'
import { ref } from 'vue'

// Storage keys
const STORAGE_KEY_API_ENDPOINT = 'settings-api-endpoint'
const STORAGE_KEY_API_KEY = 'settings-api-key'
const STORAGE_KEY_MODEL = 'settings-model'
const STORAGE_KEY_TEMPERATURE = 'settings-temperature'
const STORAGE_KEY_MAX_TOKENS = 'settings-max-tokens'
const STORAGE_KEY_SYSTEM_PROMPT = 'settings-system-prompt'

export const useSettingsStore = defineStore('settings', () => {
  // Settings state
  const apiEndpoint = ref(loadApiEndpoint())
  const apiKey = ref(loadApiKey())
  const model = ref(loadModel())
  const temperature = ref(loadTemperature())
  const maxTokens = ref(loadMaxTokens())
  const systemPrompt = ref(loadSystemPrompt())

  // Helper functions
  function loadApiEndpoint(): string {
    return localStorage.getItem(STORAGE_KEY_API_ENDPOINT) || ''
  }

  function loadApiKey(): string {
    return localStorage.getItem(STORAGE_KEY_API_KEY) || ''
  }

  function loadModel(): string {
    return localStorage.getItem(STORAGE_KEY_MODEL) || ''
  }

  function loadTemperature(): number {
    const saved = localStorage.getItem(STORAGE_KEY_TEMPERATURE)
    if (saved) {
      const parsed = parseFloat(saved)
      if (!isNaN(parsed)) return parsed
    }
    return 0.7
  }

  function loadMaxTokens(): string {
    return localStorage.getItem(STORAGE_KEY_MAX_TOKENS) || ''
  }

  function loadSystemPrompt(): string {
    return localStorage.getItem(STORAGE_KEY_SYSTEM_PROMPT) || ''
  }

  // Actions
  function saveSettings() {
    localStorage.setItem(STORAGE_KEY_API_ENDPOINT, apiEndpoint.value)
    localStorage.setItem(STORAGE_KEY_API_KEY, apiKey.value)
    localStorage.setItem(STORAGE_KEY_MODEL, model.value)
    localStorage.setItem(STORAGE_KEY_TEMPERATURE, temperature.value.toString())
    localStorage.setItem(STORAGE_KEY_MAX_TOKENS, maxTokens.value)
    localStorage.setItem(STORAGE_KEY_SYSTEM_PROMPT, systemPrompt.value)
  }

  function resetSettings() {
    apiEndpoint.value = ''
    apiKey.value = ''
    model.value = ''
    temperature.value = 0.7
    maxTokens.value = ''
    systemPrompt.value = ''
    localStorage.removeItem(STORAGE_KEY_API_ENDPOINT)
    localStorage.removeItem(STORAGE_KEY_API_KEY)
    localStorage.removeItem(STORAGE_KEY_MODEL)
    localStorage.removeItem(STORAGE_KEY_TEMPERATURE)
    localStorage.removeItem(STORAGE_KEY_MAX_TOKENS)
    localStorage.removeItem(STORAGE_KEY_SYSTEM_PROMPT)
  }

  return {
    // State
    apiEndpoint,
    apiKey,
    model,
    temperature,
    maxTokens,
    systemPrompt,
    // Actions
    saveSettings,
    resetSettings,
  }
})