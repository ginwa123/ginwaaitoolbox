<script setup lang="ts">
import { ref } from 'vue'
import MemoryList from './tool_outputs/MemoryList.vue'
import MemoryDetail from './MemoryDetail.vue'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

const selectedMemoryName = ref<string | null>(null)
const memoryListRef = ref<InstanceType<typeof MemoryList> | null>(null)

const handleSelectMemory = (name: string) => {
  selectedMemoryName.value = name
}

const handleMemoryDeleted = (_name: string) => {
  selectedMemoryName.value = null
  memoryListRef.value?.refresh()
  emit('notification', 'Memory deleted successfully', 'success')
}

const handleMemorySaved = () => {
  memoryListRef.value?.refresh()
  emit('notification', 'Memory saved', 'success')
}

const handleError = (message: string) => {
  emit('notification', message, 'error')
}
</script>

<template>
  <div class="flex h-full gap-6">
    <!-- Memory List Panel -->
    <div class="w-80 shrink-0 flex flex-col overflow-hidden">
      <div
        class="rounded-xl p-6 flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      >
        <h2
          class="text-base font-semibold mb-4 shrink-0"
          style="color: var(--semantic-text);"
        >Memories</h2>
        <p class="text-sm mb-4 shrink-0" style="color: var(--semantic-text-muted);">
          Global markdown notes the agent can reference. Files live in <code>~/.config/nalar/memories/</code>.
        </p>
        <div class="flex-1 overflow-y-auto min-h-0">
          <MemoryList
            ref="memoryListRef"
            :selected-memory-name="selectedMemoryName"
            @select-memory="handleSelectMemory"
          />
        </div>
      </div>
    </div>

    <!-- Memory Detail Panel -->
    <div class="flex-1 flex flex-col overflow-hidden">
      <div
        class="rounded-xl flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      >
        <h2
          class="text-base font-semibold p-4 shrink-0"
          style="color: var(--semantic-text); border-bottom: 1px solid var(--color-border);"
        >Memory</h2>
        <div class="flex-1 overflow-hidden">
          <MemoryDetail
            :memory-name="selectedMemoryName"
            @memory-deleted="handleMemoryDeleted"
            @memory-saved="handleMemorySaved"
            @error="handleError"
          />
        </div>
      </div>
    </div>
  </div>
</template>
