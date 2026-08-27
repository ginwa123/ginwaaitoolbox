<!--
  KanbanAgentSettings — per-board agent config dialog (Migration 081,
  agent-kanbans mirror).

  Hosts the three agent-menu sections for a kanban board:
    1. Knowledge   — file XOR inline-text entries (reuses
                     AgentKnowledgeDialog + AgentKnowledgeDetailDialog)
    2. System Prompt — named persona blocks (reuses AgentSystemPromptDialog)
    3. Tools       — inline checkbox allowlist (registry from
                     getAgentToolsRegistry, toggles via enable/disable)

  Unlike the AgentView wiring (state in AppLayout refs), ALL state is
  local to this component — it's self-contained so AppLayout only needs
  a `:show` + `:item` mount. Data loads on open (watch show → load()),
  mutations are optimistic with revert-on-failure (mirrors the
  AppLayout handler patterns).

  Public API:
    props:  show (boolean), item (WorkspaceItem | null)
    emits:  close

  Plan: docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
  Task: task_1787597624259_2
-->
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import {
  getAgentKanban,
  // updateAgentKanban is exported but not yet wired — the per-board
  // config is currently read-only from this dialog (knowledge + tools
  // + system-prompt editors cover the editable surface; the top-level
  // agent-kanban row is set on creation and never edited). Re-add
  // the import when the top-level editor lands.
  addAgentKanbanKnowledge,
  updateAgentKanbanKnowledge,
  deleteAgentKanbanKnowledge,
  addAgentKanbanSystemPrompt,
  updateAgentKanbanSystemPrompt,
  deleteAgentKanbanSystemPrompt,
  getAgentToolsRegistry,
  enableAgentKanbanTool,
  disableAgentKanbanTool,
  type AgentKanban,
  type AgentKanbanKnowledgeRow,
  type AgentKanbanSystemPromptRow,
  type AgentRegistryEntry,
} from '../../api'
import AgentKnowledgeDialog from '../dialogs/AgentKnowledgeDialog.vue'
import AgentKnowledgeDetailDialog from '../dialogs/AgentKnowledgeDetailDialog.vue'
import AgentSystemPromptDialog from '../dialogs/AgentSystemPromptDialog.vue'
import type { AgentKnowledgeRow, AgentSystemPromptRow } from '../../api'

const props = withDefaults(
  defineProps<{
    show: boolean
    item: { id: string; name?: string } | null
    workspaceId?: string
  }>(),
  { workspaceId: '' },
)

const emit = defineEmits<{ close: [] }>()

// ─── Board config state ──────────────────────────────────────────────
const loading = ref(false)
const loadError = ref<string | null>(null)
const config = ref<AgentKanban | null>(null)
const knowledges = ref<AgentKanbanKnowledgeRow[]>([])
const tools = ref<string[]>([])
const systemPrompts = ref<AgentKanbanSystemPromptRow[]>([])
const toolRegistry = ref<AgentRegistryEntry[]>([])

// ─── Sub-dialog state ────────────────────────────────────────────────
const knowledgeAddOpen = ref(false)
const knowledgeEditOpen = ref(false)
const knowledgeEditRow = ref<AgentKanbanKnowledgeRow | null>(null)
const promptDialogOpen = ref(false)
const promptEditRow = ref<AgentKanbanSystemPromptRow | null>(null)

// The reused Agent dialogs expect AgentKnowledgeRow / AgentSystemPromptRow
// (agent_id-keyed). Adapt kanban rows by mapping kanban_id → agent_id —
// the dialogs never send the id field back, so the mapping is lossless.
const knowledgeEditRowAdapted = computed<AgentKnowledgeRow | null>(() => {
  const k = knowledgeEditRow.value
  if (!k) return null
  return { ...k, agent_id: k.kanban_id }
})
const promptEditRowAdapted = computed<AgentSystemPromptRow | null>(() => {
  const p = promptEditRow.value
  if (!p) return null
  return { ...p, agent_id: p.kanban_id }
})

// busy/error shared by all sub-dialogs (only one can be open at a time).
const busy = ref(false)
const dialogError = ref<string | null>(null)

const kanbanId = computed(() => props.item?.id ?? '')

const errText = (err: unknown): string => {
  const msg = err instanceof Error ? err.message : String(err)
  // Strip the "API 500:" style prefix apiFetch adds — keep the message.
  return msg.replace(/^API \d+:\s*/, '')
}

// ─── Load ────────────────────────────────────────────────────────────
const load = async () => {
  if (!kanbanId.value) return
  loading.value = true
  loadError.value = null
  try {
    // Registry first (cheap, needed by the tools panel either way).
    try {
      const reg = await getAgentToolsRegistry()
      toolRegistry.value = reg.tools
    } catch {
      toolRegistry.value = []
    }
    const data = await getAgentKanban(props.workspaceId ?? '', kanbanId.value)
    if (data) {
      config.value = data.agent_kanban
      knowledges.value = data.knowledges
      tools.value = [...data.tools].sort()
      systemPrompts.value = data.system_prompts
    } else {
      // 404 "not configured" — expected state for a fresh board.
      config.value = null
      knowledges.value = []
      tools.value = []
      systemPrompts.value = []
    }
  } catch (err) {
    loadError.value = errText(err)
  } finally {
    loading.value = false
  }
}

// Reload on every open.
watch(
  () => props.show,
  async (show) => {
    if (show) await load()
  },
  { immediate: true },
)

const handleClose = () => emit('close')

// ─── Knowledge handlers ──────────────────────────────────────────────
const handleKnowledgeCreate = async (filePath: string, label: string, content: string) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const row = await addAgentKanbanKnowledge(config.value.id, filePath, label, content)
    knowledges.value.unshift(row)
    knowledgeAddOpen.value = false
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handleKnowledgeSave = async (
  knowledgeId: string,
  updates: { label: string; file_path?: string; content?: string },
) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const updated = await updateAgentKanbanKnowledge(config.value.id, knowledgeId, updates)
    const idx = knowledges.value.findIndex((k) => k.id === knowledgeId)
    if (idx >= 0) knowledges.value.splice(idx, 1, updated)
    knowledgeEditOpen.value = false
    knowledgeEditRow.value = null
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handleKnowledgeRemove = async (knowledgeId: string) => {
  if (!config.value) return
  const idx = knowledges.value.findIndex((k) => k.id === knowledgeId)
  const backup = idx >= 0 ? knowledges.value[idx] : null
  if (idx < 0 || !backup) return
  knowledges.value.splice(idx, 1) // optimistic
  try {
    await deleteAgentKanbanKnowledge(config.value.id, knowledgeId)
  } catch (err) {
    knowledges.value.splice(idx, 0, backup) // revert
    loadError.value = errText(err)
  }
}

// ─── System prompt handlers ──────────────────────────────────────────
const handlePromptCreate = async (title: string, content: string) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const row = await addAgentKanbanSystemPrompt(config.value.id, title, content)
    systemPrompts.value.unshift(row)
    promptDialogOpen.value = false
    promptEditRow.value = null
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handlePromptSave = async (promptId: string, updates: { title: string; content: string }) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const updated = await updateAgentKanbanSystemPrompt(config.value.id, promptId, updates)
    const idx = systemPrompts.value.findIndex((p) => p.id === promptId)
    if (idx >= 0) systemPrompts.value.splice(idx, 1, updated)
    promptDialogOpen.value = false
    promptEditRow.value = null
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handlePromptRemove = async (promptId: string) => {
  if (!config.value) return
  const idx = systemPrompts.value.findIndex((p) => p.id === promptId)
  const backup = idx >= 0 ? systemPrompts.value[idx] : null
  if (idx < 0 || !backup) return
  systemPrompts.value.splice(idx, 1) // optimistic
  try {
    await deleteAgentKanbanSystemPrompt(config.value.id, promptId)
  } catch (err) {
    systemPrompts.value.splice(idx, 0, backup) // revert
    loadError.value = errText(err)
  }
}

// ─── Tool toggle handlers ────────────────────────────────────────────
const toolBusy = ref(false)
const isEnabled = (toolName: string) => tools.value.includes(toolName)

const handleToggleTool = async (toolName: string) => {
  if (!config.value || toolBusy.value) return
  toolBusy.value = true
  const wasEnabled = isEnabled(toolName)
  // Optimistic flip.
  if (wasEnabled) {
    tools.value = tools.value.filter((t) => t !== toolName)
  } else {
    tools.value = [...tools.value, toolName].sort()
  }
  try {
    if (wasEnabled) {
      await disableAgentKanbanTool(config.value.id, toolName)
    } else {
      await enableAgentKanbanTool(config.value.id, toolName)
    }
  } catch (err) {
    // Revert.
    if (wasEnabled) {
      tools.value = [...tools.value, toolName].sort()
    } else {
      tools.value = tools.value.filter((t) => t !== toolName)
    }
    loadError.value = errText(err)
  } finally {
    toolBusy.value = false
  }
}
</script>

<template>
  <Teleport to="body">
    <Transition name="kanban-agent-settings-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        role="dialog"
        aria-modal="true"
        aria-labelledby="kanban-agent-settings-title"
        data-testid="kanban-agent-settings-dialog"
      >
        <div class="absolute inset-0 backdrop-blur-md" style="background: rgba(0, 0, 0, 0.6);" @click="handleClose" />
        <div
          class="relative w-full max-w-2xl mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 80vh;"
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-3 flex items-start justify-between shrink-0">
            <div>
              <h3 id="kanban-agent-settings-title" class="text-base font-semibold" style="color: var(--semantic-text);">
                Agent config
              </h3>
              <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
                Knowledge, persona and tool access injected into every chat on this board.
              </p>
            </div>
            <button
              type="button"
              class="shrink-0 w-7 h-7 rounded-full flex items-center justify-center hover:opacity-70 transition-opacity"
              style="color: var(--semantic-text-dim);"
              aria-label="Close agent config"
              data-testid="kanban-agent-settings-close"
              @click="handleClose"
            >
              ✕
            </button>
          </div>

          <!-- Loading / error / empty states -->
          <div v-if="loading" class="px-5 py-8 text-sm text-center" style="color: var(--semantic-text-dim);" data-testid="kanban-agent-settings-loading">
            Loading…
          </div>
          <div v-else-if="loadError && !config" class="px-5 py-6 text-sm text-center" style="color: rgb(239, 68, 68);" data-testid="kanban-agent-settings-error">
            {{ loadError }}
          </div>

          <!-- Body -->
          <div v-else-if="config" class="px-5 pb-5 overflow-y-auto flex flex-col gap-5">
            <!-- ─── Knowledge section ─── -->
            <section data-testid="kanban-agent-knowledge-panel">
              <div class="flex items-center justify-between mb-2">
                <h4 class="text-sm font-semibold" style="color: var(--semantic-text);">
                  Knowledge
                  <span class="ml-1 text-xs font-normal" style="color: var(--semantic-text-dim);">({{ knowledges.length }})</span>
                </h4>
                <button
                  type="button"
                  class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
                  data-testid="kanban-agent-knowledge-add"
                  @click="knowledgeAddOpen = true"
                >
                  <span aria-hidden="true">✚</span> Add
                </button>
              </div>
              <ul v-if="knowledges.length" class="flex flex-col gap-1">
                <li
                  v-for="k in knowledges"
                  :key="k.id"
                  class="flex items-center gap-2 px-3 py-2 rounded-lg text-xs"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
                  :data-testid="`kanban-agent-knowledge-row-${k.id}`"
                >
                  <span class="truncate flex-1" style="color: var(--semantic-text);">
                    {{ k.label || (k.content ? 'Inline knowledge' : k.file_path.split('/').pop()) }}
                  </span>
                  <button
                    type="button"
                    class="shrink-0 hover:opacity-70"
                    style="color: var(--semantic-text-dim);"
                    :aria-label="`Edit knowledge ${k.label || k.id}`"
                    :data-testid="`kanban-agent-knowledge-edit-${k.id}`"
                    @click="knowledgeEditRow = k; knowledgeEditOpen = true"
                  >✎</button>
                  <button
                    type="button"
                    class="shrink-0 hover:opacity-70"
                    style="color: rgb(239, 68, 68);"
                    :aria-label="`Remove knowledge ${k.label || k.id}`"
                    :data-testid="`kanban-agent-knowledge-remove-${k.id}`"
                    @click="handleKnowledgeRemove(k.id)"
                  >✕</button>
                </li>
              </ul>
              <p v-else class="text-xs" style="color: var(--semantic-text-dim);" data-testid="kanban-agent-knowledge-empty">
                No knowledge entries yet.
              </p>
            </section>

            <!-- ─── System prompt section ─── -->
            <section data-testid="kanban-agent-system-prompt-panel">
              <div class="flex items-center justify-between mb-2">
                <h4 class="text-sm font-semibold" style="color: var(--semantic-text);">
                  System Prompt
                  <span class="ml-1 text-xs font-normal" style="color: var(--semantic-text-dim);">({{ systemPrompts.length }})</span>
                </h4>
                <button
                  type="button"
                  class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
                  data-testid="kanban-agent-system-prompt-add"
                  @click="promptEditRow = null; promptDialogOpen = true"
                >
                  <span aria-hidden="true">✚</span> Add
                </button>
              </div>
              <ul v-if="systemPrompts.length" class="flex flex-col gap-1">
                <li
                  v-for="p in systemPrompts"
                  :key="p.id"
                  class="flex items-center gap-2 px-3 py-2 rounded-lg text-xs"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
                  :data-testid="`kanban-agent-system-prompt-row-${p.id}`"
                >
                  <span class="truncate flex-1" style="color: var(--semantic-text);">
                    {{ p.title || 'Untitled prompt' }}
                  </span>
                  <button
                    type="button"
                    class="shrink-0 hover:opacity-70"
                    style="color: var(--semantic-text-dim);"
                    :aria-label="`Edit system prompt ${p.title || p.id}`"
                    :data-testid="`kanban-agent-system-prompt-edit-${p.id}`"
                    @click="promptEditRow = p; promptDialogOpen = true"
                  >✎</button>
                  <button
                    type="button"
                    class="shrink-0 hover:opacity-70"
                    style="color: rgb(239, 68, 68);"
                    :aria-label="`Remove system prompt ${p.title || p.id}`"
                    :data-testid="`kanban-agent-system-prompt-remove-${p.id}`"
                    @click="handlePromptRemove(p.id)"
                  >✕</button>
                </li>
              </ul>
              <p v-else class="text-xs" style="color: var(--semantic-text-dim);" data-testid="kanban-agent-system-prompt-empty">
                No system prompts yet.
              </p>
            </section>

            <!-- ─── Tools section ─── -->
            <section data-testid="kanban-agent-tools-panel">
              <div class="flex items-center justify-between mb-2">
                <h4 class="text-sm font-semibold" style="color: var(--semantic-text);">
                  Tools
                  <span class="ml-1 text-xs font-normal" style="color: var(--semantic-text-dim);">({{ tools.length }} enabled)</span>
                </h4>
              </div>
              <ul class="grid grid-cols-2 gap-1">
                <li v-for="t in toolRegistry" :key="t.name">
                  <label
                    class="flex items-center gap-2 px-3 py-2 rounded-lg text-xs cursor-pointer select-none"
                    style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
                    :data-testid="`kanban-agent-tool-${t.name}`"
                  >
                    <input
                      type="checkbox"
                      class="accent-current"
                      :checked="isEnabled(t.name)"
                      :disabled="toolBusy"
                      :data-testid="`kanban-agent-tool-check-${t.name}`"
                      @change="handleToggleTool(t.name)"
                    />
                    <span class="truncate" style="color: var(--semantic-text);" :title="t.description">{{ t.name }}</span>
                  </label>
                </li>
              </ul>
              <p v-if="!toolRegistry.length" class="text-xs mt-1" style="color: var(--semantic-text-dim);" data-testid="kanban-agent-tools-empty">
                Tool registry unavailable.
              </p>
            </section>

            <!-- Non-fatal mutation error banner -->
            <p
              v-if="loadError && config"
              class="text-xs px-3 py-2 rounded-lg"
              style="color: rgb(239, 68, 68); background-color: rgba(239, 68, 68, 0.08);"
              data-testid="kanban-agent-settings-mutation-error"
            >
              {{ loadError }}
            </p>
          </div>

          <!-- Unconfigured empty state -->
          <div v-else class="px-5 py-8 flex flex-col items-center gap-3" data-testid="kanban-agent-settings-unconfigured">
            <p class="text-sm text-center" style="color: var(--semantic-text-dim);">
              This board has no agent config yet. Enable a tool below to create one.
            </p>
            <ul class="w-full grid grid-cols-2 gap-1">
              <li v-for="t in toolRegistry" :key="t.name">
                <label
                  class="flex items-center gap-2 px-3 py-2 rounded-lg text-xs cursor-pointer select-none"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
                  :data-testid="`kanban-agent-tool-${t.name}`"
                >
                  <input
                    type="checkbox"
                    class="accent-current"
                    :checked="false"
                    :disabled="toolBusy"
                    :data-testid="`kanban-agent-tool-check-${t.name}`"
                    @change="handleToggleTool(t.name)"
                  />
                  <span class="truncate" style="color: var(--semantic-text);" :title="t.description">{{ t.name }}</span>
                </label>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Transition>

    <!-- Sub-dialogs (reuse the Agent dialogs verbatim) -->
    <AgentKnowledgeDialog
      :show="knowledgeAddOpen"
      :busy="busy"
      :error="dialogError"
      @close="knowledgeAddOpen = false"
      @create="handleKnowledgeCreate"
    />
    <AgentKnowledgeDetailDialog
      :show="knowledgeEditOpen"
      :row="knowledgeEditRowAdapted"
      :busy="busy"
      :error="dialogError"
      @close="knowledgeEditOpen = false; knowledgeEditRow = null"
      @save="handleKnowledgeSave"
    />
    <AgentSystemPromptDialog
      :show="promptDialogOpen"
      :row="promptEditRowAdapted"
      :busy="busy"
      :error="dialogError"
      @close="promptDialogOpen = false; promptEditRow = null"
      @create="handlePromptCreate"
      @save="handlePromptSave"
    />
  </Teleport>
</template>

<style scoped>
.kanban-agent-settings-modal-enter-active,
.kanban-agent-settings-modal-leave-active {
  transition: opacity 0.18s ease;
}
.kanban-agent-settings-modal-enter-from,
.kanban-agent-settings-modal-leave-to {
  opacity: 0;
}
</style>
