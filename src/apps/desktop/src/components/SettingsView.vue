<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import NalarSettings from './NalarSettings.vue'
import SkillsSettings from './SkillsSettings.vue'
import MemoriesSettings from './MemoriesSettings.vue'

const router = useRouter()

// Settings sidebar state
const activeSettingsTab = ref('nalar')

// Notification state
const notification = ref<{ message: string; type: 'success' | 'error' } | null>(null)

const showNotification = (message: string, type: 'success' | 'error') => {
  notification.value = { message, type }
  setTimeout(() => {
    notification.value = null
  }, 3000)
}

const emit = defineEmits<{
  close: []
}>()

const goBack = () => {
  router.back()
}

const setSettingsTab = (tab: string) => {
  activeSettingsTab.value = tab
}

const handleNotification = (message: string, type: 'success' | 'error') => {
  showNotification(message, type)
}
</script>

<template>
  <!-- Fullscreen Settings Overlay -->
  <div class="fixed inset-0 z-50 flex" style="background-color: var(--semantic-content-bg);">
    <!-- Settings Sidebar -->
    <div
      class="h-full flex flex-col shrink-0"
      style="width: 240px; background-color: var(--semantic-sidebar-bg); border-right: 1px solid var(--color-border);"
    >
      <!-- Settings Header -->
      <div
        class="h-14 flex items-center px-4 shrink-0"
        style="border-bottom: 1px solid var(--color-border);"
      >
        <button
          @click="goBack"
          class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80 mr-3"
          style="color: var(--semantic-text-muted);"
          title="Back"
        >
          <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </button>
        <h1
          class="text-lg font-semibold"
          style="color: var(--semantic-text);"
        >Settings</h1>
      </div>

      <!-- Settings Menu -->
      <nav class="flex-1 py-4 px-3 overflow-y-auto">
        <button
          @click="setSettingsTab('nalar')"
          class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200 mb-1"
          :style="activeSettingsTab === 'nalar'
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
            : `color: var(--semantic-text-muted);`"
        >
          <span class="text-lg">🤖</span>
          <span>Nalar</span>
        </button>

        <button
          @click="setSettingsTab('skills')"
          class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200"
          :style="activeSettingsTab === 'skills'
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
            : `color: var(--semantic-text-muted);`"
        >
          <span class="text-lg">🛠️</span>
          <span>Skills</span>
        </button>

        <button
          @click="setSettingsTab('memories')"
          class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200"
          :style="activeSettingsTab === 'memories'
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
            : `color: var(--semantic-text-muted);`"
        >
          <span class="text-lg">🧠</span>
          <span>Memories</span>
        </button>
      </nav>
    </div>

    <!-- Settings Content -->
    <main class="flex-1 flex flex-col overflow-hidden">
      <!-- Nalar Tab Content -->
      <div v-if="activeSettingsTab === 'nalar'" class="flex-1 overflow-y-auto p-6">
        <NalarSettings @notification="handleNotification" />
      </div>

      <!-- Skills Tab Content -->
      <div v-else-if="activeSettingsTab === 'skills'" class="flex-1 overflow-y-auto p-6">
        <SkillsSettings @notification="handleNotification" />
      </div>

      <!-- Memories Tab Content -->
      <div v-else-if="activeSettingsTab === 'memories'" class="flex-1 overflow-y-auto p-6">
        <MemoriesSettings @notification="handleNotification" />
      </div>
    </main>

    <!-- Notification Toast -->
    <div 
      v-if="notification"
      class="fixed bottom-6 right-6 px-4 py-3 rounded-lg shadow-lg z-50"
      :style="notification.type === 'success' 
        ? 'background-color: var(--color-green); color: white;' 
        : 'background-color: var(--color-red); color: white;'"
    >
      {{ notification.message }}
    </div>
  </div>
</template>