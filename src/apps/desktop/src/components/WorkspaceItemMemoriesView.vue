<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import LocalMemoryDetailView from './LocalMemoryDetailView.vue'
import {
  listLocalMemories,
  type Memory,
} from '../api'

const props = defineProps<{
  cwd: string
  itemName?: string
}>()

const memories = ref<Memory[]>([])
const isLoading = ref(false)
const error = ref<string | null>(null)
const selectedMemoryName = ref<string | null>(null)
const isCreating = ref(false)

const hasCwd = computed(() => !!props.cwd && props.cwd.length > 0)
const headerPath = computed(() =>
  hasCwd.value ? `${props.cwd}/.nalar/memories/` : '',
)

const loadList = async () => {
  if (!hasCwd.value) {
    memories.value = []
    return
  }
  isLoading.value = true
  error.value = null
  try {
    const result = await listLocalMemories(props.cwd)
    memories.value = result.memories || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load memories'
  } finally {
    isLoading.value = false
  }
}

const handleRefresh = () => void loadList()

const handleSelectMemory = (name: string) => {
  selectedMemoryName.value = name
}

const handleStartCreate = () => {
  selectedMemoryName.value = null
  isCreating.value = true
}

const handleCancelCreate = () => {
  isCreating.value = false
}

const handleMemorySaved = () => {
  isCreating.value = false
  // Refresh list (new memory appears at top or bottom — server returns
  // sorted by name; preserve that). Detail's emit('memorySaved') fires
  // this AFTER the API returns, so reload here is safe.
  void loadList()
}

const handleMemoryDeleted = () => {
  selectedMemoryName.value = null
  void loadList()
}

const formatSize = (bytes: number): string => {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

// Re-fetch when cwd changes (user clicks a different workspace item).
// This is the "auto-refresh on focus" decision (#4 in Defaults).
watch(
  () => props.cwd,
  () => {
    selectedMemoryName.value = null
    isCreating.value = false
    void loadList()
  },
  { immediate: true },
)
</script>

<template>
  <div class="flex flex-col h-full" data-testid="workspace-item-memories-view">
    <!-- Header: item name + path + refresh button -->
    <div
      class="flex items-center justify-between gap-3 px-6 py-3 shrink-0"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <div class="flex flex-col min-w-0">
        <h2
          v-if="itemName"
          class="text-base font-semibold truncate"
          style="color: var(--semantic-text);"
        >
          🧠 {{ itemName }}
        </h2>
        <p
          v-if="hasCwd"
          class="text-xs mt-0.5 truncate"
          style="color: var(--semantic-text-dim);"
          data-testid="workspace-item-memories-path"
        >
          {{ headerPath }}
        </p>
      </div>
      <div class="flex items-center gap-2 shrink-0">
        <button
          v-if="hasCwd"
          type="button"
          @click="handleRefresh"
          :disabled="isLoading"
          data-testid="workspace-item-memories-refresh"
          class="px-3 py-1.5 rounded-lg text-xs font-medium"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text-muted);
            border: 1px solid var(--color-border);
          "
        >
          {{ isLoading ? 'Loading…' : '↻ Refresh' }}
        </button>
        <button
          v-if="hasCwd"
          type="button"
          @click="handleStartCreate"
          data-testid="workspace-item-memories-new"
          class="px-3 py-1.5 rounded-lg text-xs font-medium"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
        >
          + New Memory
        </button>
      </div>
    </div>

    <!-- Empty cwd fallback (rare — only legacy items without path) -->
    <div
      v-if="!hasCwd"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-no-cwd"
    >
      <p class="text-sm" style="color: var(--semantic-text-dim);">
        No path is set on this project — pick a directory when creating the item to enable local memories.
      </p>
    </div>

    <!-- Loading -->
    <div
      v-else-if="isLoading && memories.length === 0"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-loading"
    >
      <div class="flex items-center gap-3">
        <div
          class="w-5 h-5 border-2 rounded-full animate-spin"
          style="border-color: var(--color-violet); border-top-color: transparent;"
        ></div>
        <span style="color: var(--semantic-text-muted);">Loading memories…</span>
      </div>
    </div>

    <!-- Error -->
    <div
      v-else-if="error"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-error"
    >
      <div class="text-center">
        <p class="text-sm" style="color: var(--color-red);">{{ error }}</p>
        <button
          type="button"
          @click="handleRefresh"
          class="mt-3 px-4 py-2 rounded-lg text-sm"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text-muted);
            border: 1px solid var(--color-border);
          "
        >Retry</button>
      </div>
    </div>

    <!-- Empty list -->
    <div
      v-else-if="memories.length === 0"
      class="flex-1 flex items-center justify-center"
      data-testid="workspace-item-memories-empty"
    >
      <div class="text-center">
        <p class="text-sm" style="color: var(--semantic-text-muted);">
          No memories yet
        </p>
        <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
          Create one with the + New Memory button, or add a <code>.md</code> file to <code>{{ headerPath }}</code>.
        </p>
      </div>
    </div>

    <!-- List + detail two-panel -->
    <div v-else class="flex-1 flex min-h-0">
      <!-- List panel -->
      <div
        class="w-72 shrink-0 overflow-y-auto"
        style="border-right: 1px solid var(--color-border);"
      >
        <ul class="p-3 space-y-2" data-testid="workspace-item-memories-list">
          <li
            v-for="mem in memories"
            :key="mem.name"
            @click="handleSelectMemory(mem.name)"
            class="p-3 rounded-lg cursor-pointer transition-all"
            :class="{ 'ring-2': selectedMemoryName === mem.name }"
            :style="selectedMemoryName === mem.name
              ? 'background-color: var(--semantic-active-bg); border: 1px solid var(--color-violet);'
              : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'"
            :data-testid="`workspace-item-memories-row-${mem.name}`"
          >
            <div class="flex items-start gap-2 min-w-0">
              <span class="text-base">🧠</span>
              <div class="flex-1 min-w-0">
                <h3
                  class="text-sm font-medium truncate"
                  style="color: var(--semantic-text);"
                >{{ mem.title }}</h3>
                <p
                  class="text-xs mt-0.5 truncate"
                  style="color: var(--semantic-text-dim);"
                >{{ mem.name }} · {{ formatSize(mem.size) }}</p>
              </div>
            </div>
          </li>
        </ul>
      </div>

      <!-- Detail panel -->
      <div class="flex-1 overflow-hidden">
        <LocalMemoryDetailView
          v-if="selectedMemoryName || isCreating"
          :cwd="cwd"
          :memory-name="isCreating ? null : selectedMemoryName"
          :is-creating="isCreating"
          @memory-saved="handleMemorySaved"
          @memory-deleted="handleMemoryDeleted"
          @cancel-create="handleCancelCreate"
        />
        <div
          v-else
          class="h-full flex items-center justify-center"
          data-testid="workspace-item-memories-detail-empty"
        >
          <p class="text-sm" style="color: var(--semantic-text-muted);">
            Select a memory, or create a new one.
          </p>
        </div>
      </div>
    </div>
  </div>
</template>