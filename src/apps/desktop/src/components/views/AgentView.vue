<!--
  AgentView — main view for `item_type='agent'` workspace items.

  Three sections (per spec D11):
    1. Knowledge panel — list of markdown paths with add/remove
    2. Tools panel — searchable, bulk-operable checkbox list rendered
       from agentTools registry
    3. Chat list (right column) — existing workspace_item_tasks filtered

  Plan: 2026-08-15-agent-mode (Task 17)
  UI/UX polish: 2026-08-20 (task_1787254463604_3) — added a search
  filter, an enabled-count chip, Select all / Clear all bulk ops,
  full-description tooltips, hover state on remove buttons, and a
  better empty state. See plan: docs/superpowers/plans/2026-08-20-agent-tools-ui-ux.md
-->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import * as api from '../../api'
import { useAgentToolsStore } from '../../stores/agentTools'
import type { WorkspaceItem } from '../../stores/workspaces'

interface Props {
  item: WorkspaceItem
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
  toggleToolsBulk: [toolNames: string[], enabled: boolean]
  newChat: []
  selectTask: [taskId: string]
}>()

const agentToolsStore = useAgentToolsStore()
const loading = ref(true)

// ─── Tools panel UI state ───────────────────────────────────────────────
//
// `searchQuery` filters the registry by name OR description (case-
// insensitive). Kept local — the registry is loaded once on mount and
// cached in the Pinia store, so re-filtering on every keystroke is
// cheap and doesn't need debouncing.
//
// `collapsedCategories` is reserved for a future category-grouping
// iteration; for now we keep the flat filtered list.
const searchQuery = ref('')

const trimmedQuery = computed(() => searchQuery.value.trim().toLowerCase())

const filteredTools = computed(() => {
  const q = trimmedQuery.value
  if (q.length === 0) return agentToolsStore.registry
  return agentToolsStore.registry.filter((t) => {
    return (
      t.name.toLowerCase().includes(q) ||
      t.description.toLowerCase().includes(q)
    )
  })
})

const enabledToolSet = computed(() => new Set(props.tools))

const enabledCountInFiltered = computed(() => {
  let n = 0
  for (const t of filteredTools.value) if (enabledToolSet.value.has(t.name)) n += 1
  return n
})

const allFilteredEnabled = computed(() => {
  const f = filteredTools.value
  if (f.length === 0) return false
  return f.every((t) => enabledToolSet.value.has(t.name))
})

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
  return enabledToolSet.value.has(name)
}

function basename(path: string): string {
  const idx = path.lastIndexOf('/')
  return idx === -1 ? path : path.slice(idx + 1)
}

async function handleToggleTool(name: string, event: Event) {
  const checked = (event.target as HTMLInputElement).checked
  emit('toggleTool', name, checked)
}

function handleSelectAllVisible() {
  // Emit one bulk event with the names currently NOT enabled.
  // Bulk handlers in the parent can dedupe + run them in parallel.
  const toEnable = filteredTools.value
    .filter((t) => !enabledToolSet.value.has(t.name))
    .map((t) => t.name)
  if (toEnable.length > 0) emit('toggleToolsBulk', toEnable, true)
}

function handleClearAllVisible() {
  const toDisable = filteredTools.value
    .filter((t) => enabledToolSet.value.has(t.name))
    .map((t) => t.name)
  if (toDisable.length > 0) emit('toggleToolsBulk', toDisable, false)
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
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold" style="color: var(--semantic-text);">
              Knowledge
            </h2>
            <span
              data-testid="agent-knowledge-count"
              class="text-[10px] font-semibold px-1.5 py-0.5 rounded-full"
              :style="{
                backgroundColor: knowledge.length > 0 ? 'var(--color-violet)' : 'var(--semantic-card-bg)',
                color: knowledge.length > 0 ? 'var(--color-bg)' : 'var(--semantic-text-dim)',
                border: knowledge.length > 0 ? 'none' : '1px solid var(--color-border)',
              }"
            >
              {{ knowledge.length }}
            </span>
          </div>
          <button
            type="button"
            @click="emit('addKnowledge')"
            data-testid="agent-add-knowledge"
            class="text-xs px-2 py-1 rounded font-medium"
            style="background: var(--color-violet); color: var(--color-bg);"
          >
            + Add
          </button>
        </div>
        <div v-if="knowledge.length === 0" class="text-xs mt-2" style="color: var(--semantic-text-dim);">
          No knowledge files yet — click <strong>+ Add</strong> to attach a markdown file the agent will read on every chat start.
        </div>
        <ul v-else class="space-y-1.5 mt-2">
          <li
            v-for="k in knowledge"
            :key="k.id"
            data-testid="agent-knowledge-item"
            class="group p-2 rounded flex items-start gap-2 border"
            style="background: var(--semantic-sidebar-bg); border-color: var(--color-border);"
          >
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium truncate" style="color: var(--semantic-text);">
                {{ k.label || basename(k.file_path) }}
              </div>
              <div class="text-[11px] font-mono truncate mt-0.5" style="color: var(--semantic-text-dim);" :title="k.file_path">
                {{ k.file_path }}
              </div>
            </div>
            <button
              type="button"
              @click="emit('removeKnowledge', k.id)"
              data-testid="agent-remove-knowledge"
              class="text-xs shrink-0 opacity-40 group-hover:opacity-100 transition-opacity px-1.5 py-0.5 rounded hover:bg-red-500/10"
              style="color: var(--color-red);"
              :aria-label="`Remove ${k.label || basename(k.file_path)}`"
              title="Remove this knowledge file"
            >
              ✕
            </button>
          </li>
        </ul>
      </section>

      <!-- Tools panel -->
      <section data-testid="agent-tools-panel">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold" style="color: var(--semantic-text);">
              Tools
            </h2>
            <span
              data-testid="agent-tools-count"
              class="text-[10px] font-semibold px-1.5 py-0.5 rounded-full"
              :style="{
                backgroundColor: tools.length > 0 ? 'var(--color-violet)' : 'var(--semantic-card-bg)',
                color: tools.length > 0 ? 'var(--color-bg)' : 'var(--semantic-text-dim)',
                border: tools.length > 0 ? 'none' : '1px solid var(--color-border)',
              }"
              :title="`${tools.length} of ${agentToolsStore.registry.length} tools enabled`"
            >
              {{ tools.length }} / {{ agentToolsStore.registry.length }}
            </span>
          </div>
        </div>
        <p class="text-xs mb-3" style="color: var(--semantic-text-dim);">
          Toggle to give this Agent capabilities. Empty = pure chat (no tools).
        </p>

        <div v-if="agentToolsStore.error" data-testid="agent-tools-error" class="text-xs p-2 rounded mb-2" style="background: var(--color-red); color: var(--color-bg);">
          Tool registry unavailable.
        </div>

        <!-- Search filter + bulk ops (visible once the registry is loaded) -->
        <div v-if="!loading && !agentToolsStore.error" class="mb-2 space-y-2">
          <div class="relative flex items-center" data-testid="agent-tools-search-container">
            <input
              v-model="searchQuery"
              type="text"
              placeholder="🔍 Search tools…"
              aria-label="Search tools by name or description"
              class="w-full px-2 py-1.5 pr-7 rounded text-xs outline-none focus:ring-1"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              data-testid="agent-tools-search"
            />
            <button
              v-if="searchQuery"
              type="button"
              @click="searchQuery = ''"
              class="absolute right-1 w-5 h-5 flex items-center justify-center rounded hover:opacity-80"
              style="color: var(--semantic-text-dim);"
              data-testid="agent-tools-search-clear"
              aria-label="Clear search"
              title="Clear search"
            >
              ✕
            </button>
          </div>
          <div class="flex items-center justify-between text-[11px]" style="color: var(--semantic-text-dim);">
            <span data-testid="agent-tools-filter-status">
              <template v-if="trimmedQuery.length === 0">
                Showing all {{ filteredTools.length }} tools
              </template>
              <template v-else>
                Showing {{ enabledCountInFiltered }} / {{ filteredTools.length }} matching
              </template>
            </span>
            <div class="flex items-center gap-2">
              <button
                type="button"
                :disabled="allFilteredEnabled || filteredTools.length === 0"
                @click="handleSelectAllVisible"
                data-testid="agent-tools-select-all"
                class="font-medium disabled:opacity-40 disabled:cursor-not-allowed hover:underline"
                style="color: var(--color-violet);"
                :title="allFilteredEnabled ? 'All visible tools are already enabled' : 'Enable all visible tools'"
              >
                Select all
              </button>
              <span aria-hidden="true">·</span>
              <button
                type="button"
                :disabled="enabledCountInFiltered === 0"
                @click="handleClearAllVisible"
                data-testid="agent-tools-clear-all"
                class="font-medium disabled:opacity-40 disabled:cursor-not-allowed hover:underline"
                style="color: var(--semantic-text-muted);"
                :title="enabledCountInFiltered === 0 ? 'No visible tools are enabled' : 'Disable all visible tools'"
              >
                Clear
              </button>
            </div>
          </div>
        </div>

        <div v-if="loading" class="text-xs" style="color: var(--semantic-text-dim);" data-testid="agent-tools-loading">
          Loading tool registry…
        </div>
        <div
          v-else-if="filteredTools.length === 0 && trimmedQuery.length > 0"
          class="text-xs p-3 rounded"
          style="color: var(--semantic-text-dim); background: var(--semantic-sidebar-bg);"
          data-testid="agent-tools-empty-search"
        >
          No tools match <strong>“{{ searchQuery }}”</strong>.
          <button
            type="button"
            @click="searchQuery = ''"
            class="ml-1 underline"
            style="color: var(--color-violet);"
          >Clear search</button>
        </div>
        <ul v-else class="space-y-1 max-h-[60vh] overflow-y-auto pr-1" data-testid="agent-tools-list">
          <li
            v-for="tool in filteredTools"
            :key="tool.name"
            data-testid="agent-tool-item"
            class="flex items-start gap-2 p-2 rounded border transition-colors"
            :style="{
              backgroundColor: isToolEnabled(tool.name) ? 'var(--semantic-active-bg)' : 'var(--semantic-sidebar-bg)',
              borderColor: isToolEnabled(tool.name) ? 'var(--color-violet)' : 'var(--color-border)',
              opacity: 1,
            }"
          >
            <input
              type="checkbox"
              :id="`tool-${tool.name}`"
              :checked="isToolEnabled(tool.name)"
              @change="(e) => handleToggleTool(tool.name, e)"
              :data-testid="`agent-tool-checkbox-${tool.name}`"
              class="mt-0.5 shrink-0 cursor-pointer"
            />
            <label :for="`tool-${tool.name}`" class="text-xs cursor-pointer flex-1 min-w-0 block">
              <div class="flex items-center gap-2">
                <span class="font-mono font-semibold" style="color: var(--semantic-text);">{{ tool.name }}</span>
                <span
                  v-if="isToolEnabled(tool.name)"
                  data-testid="agent-tool-enabled-chip"
                  class="text-[9px] uppercase tracking-wider font-bold px-1 py-px rounded"
                  style="background: var(--color-violet); color: var(--color-bg);"
                >ON</span>
              </div>
              <div
                class="text-[11px] mt-0.5 leading-snug"
                style="color: var(--semantic-text-dim);"
                :title="tool.description"
              >
                {{ tool.description }}
              </div>
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
