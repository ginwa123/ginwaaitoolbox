<!--
  AgentView — main view for `item_type='agent'` workspace items.

  Three sections (per spec D11):
    1. Knowledge panel — list of markdown paths with add/remove
    2. Tools panel — checkbox list rendered from agentTools registry
    3. Chat list (right column) — existing workspace_item_tasks filtered

  Plan: 2026-08-15-agent-mode (Task 17)
-->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import * as api from '../../api'
import { useAgentToolsStore } from '../../stores/agentTools'

interface Props {
  item: { id: string; name?: string; path?: string }
  workspaceId: string
  itemId: string
  knowledge: api.AgentKnowledgeRow[]
  tools: string[]
}

const props = defineProps<Props>()

const emit = defineEmits<{
  addKnowledge: []
  removeKnowledge: [knowledgeId: string]
  toggleTool: [toolName: string, enabled: boolean]
  newChat: []
  selectTask: [taskId: string]
}>()

const agentToolsStore = useAgentToolsStore()
const loading = ref(true)
const error = ref<string | null>(null)

onMounted(async () => {
  loading.value = true
  try {
    await agentToolsStore.fetchRegistry()
  } finally {
    loading.value = false
  }
})

watch(
  () => props.tools,
  () => {
    // Re-render when tools prop changes.
  },
)

function isToolEnabled(name: string): boolean {
  return props.tools.includes(name)
}

function basename(path: string): string {
  const idx = path.lastIndexOf('/')
  return idx === -1 ? path : path.slice(idx + 1)
}

async function handleToggleTool(name: string, event: Event) {
  const checked = (event.target as HTMLInputElement).checked
  emit('toggleTool', name, checked)
}

async function handleNewChat() {
  emit('newChat')
}
</script>

<template>
  <div class="flex h-full" data-testid="agent-view">
    <!-- Left column: Knowledge + Tools panels -->
    <div class="w-96 border-r overflow-y-auto p-4 space-y-6" style="border-color: var(--color-border);">
      <!-- Knowledge panel -->
      <section data-testid="agent-knowledge-panel">
        <div class="flex items-center justify-between mb-2">
          <h2 class="text-sm font-semibold" style="color: var(--semantic-text);">
            Knowledge ({{ knowledge.length }})
          </h2>
          <button
            type="button"
            @click="emit('addKnowledge')"
            data-testid="agent-add-knowledge"
            class="text-xs px-2 py-1 rounded"
            style="background: var(--color-violet); color: var(--color-bg);"
          >
            + Add
          </button>
        </div>
        <div v-if="knowledge.length === 0" class="text-xs" style="color: var(--semantic-text-dim);">
          No knowledge files yet — click + Add to attach a markdown file.
        </div>
        <ul v-else class="space-y-2">
          <li
            v-for="k in knowledge"
            :key="k.id"
            data-testid="agent-knowledge-item"
            class="p-2 rounded flex items-start gap-2"
            style="background: var(--semantic-sidebar-bg);"
          >
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium truncate" style="color: var(--semantic-text);">
                {{ k.label || basename(k.file_path) }}
              </div>
              <div class="text-xs font-mono truncate" style="color: var(--semantic-text-dim);" :title="k.file_path">
                {{ k.file_path }}
              </div>
            </div>
            <button
              type="button"
              @click="emit('removeKnowledge', k.id)"
              data-testid="agent-remove-knowledge"
              class="text-xs shrink-0"
              style="color: var(--color-red);"
              :aria-label="`Remove ${k.label || basename(k.file_path)}`"
            >
              ✕
            </button>
          </li>
        </ul>
      </section>

      <!-- Tools panel -->
      <section data-testid="agent-tools-panel">
        <h2 class="text-sm font-semibold mb-2" style="color: var(--semantic-text);">
          Tools ({{ tools.length }} / {{ agentToolsStore.registry.length }} enabled)
        </h2>
        <p class="text-xs mb-3" style="color: var(--semantic-text-dim);">
          Toggle to give this Agent capabilities. Empty = pure chat (no tools).
        </p>
        <div v-if="agentToolsStore.error" class="text-xs p-2 rounded mb-2" style="background: var(--color-red); color: var(--color-bg);">
          Tool registry unavailable.
        </div>
        <div v-if="loading" class="text-xs" style="color: var(--semantic-text-dim);">
          Loading tool registry…
        </div>
        <ul v-else class="space-y-1 max-h-96 overflow-y-auto">
          <li
            v-for="tool in agentToolsStore.registry"
            :key="tool.name"
            data-testid="agent-tool-item"
            class="flex items-start gap-2 p-1 rounded hover:opacity-80"
          >
            <input
              type="checkbox"
              :id="`tool-${tool.name}`"
              :checked="isToolEnabled(tool.name)"
              @change="(e) => handleToggleTool(tool.name, e)"
              :data-testid="`agent-tool-checkbox-${tool.name}`"
              class="mt-1 shrink-0"
            />
            <label :for="`tool-${tool.name}`" class="text-xs cursor-pointer flex-1 min-w-0">
              <div class="font-mono" style="color: var(--semantic-text);">{{ tool.name }}</div>
              <div class="text-xs truncate" style="color: var(--semantic-text-dim);">{{ tool.description }}</div>
            </label>
          </li>
        </ul>
      </section>
    </div>

    <!-- Right column: Chat list + New Chat button -->
    <div class="flex-1 flex flex-col p-4">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-base font-semibold" style="color: var(--semantic-text);">
          {{ props.item.name || 'Agent' }}
        </h2>
        <button
          type="button"
          @click="handleNewChat"
          data-testid="agent-new-chat"
          class="text-sm px-3 py-1.5 rounded"
          style="background: var(--color-violet); color: var(--color-bg);"
        >
          + New Chat
        </button>
      </div>
      <div class="text-xs" style="color: var(--semantic-text-dim);">
        Click <strong>+ New Chat</strong> to start a conversation with this Agent.
        Knowledge files will be loaded into context, and only the tools you've enabled will be available.
      </div>
    </div>
  </div>
</template>