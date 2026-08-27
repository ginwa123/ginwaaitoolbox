<!--
  KanbanToolsPanel — per-board tool allowlist panel for a kanban board.
  Mounted as a top-level tab body inside KanbanSettingsView at the
  route /app/kanban/:itemId/settings?tab=tools (iteration 2 of the
  2026-08-27 plan — split the Agent umbrella tab into Tools +
  Knowledge as separate top-level tabs).

  The component hosts ONLY the tools checkbox grid. Knowledge rows +
  system prompts were moved to KanbanKnowledgePanel.vue in the same
  iteration. Data shape + data-testid values are identical to the
  tools section that used to live in KanbanAgentSettings /
  KanbanAgentPanel.

  Public API:
    props: item ({ id, name? } | null), workspaceId (string)

  Data-load lifecycle:
    onMounted — fetches the agent-kanban bundle (or null on 404) +
    the tools registry. Toggling a tool calls enableAgentKanbanTool /
    disableAgentKanbanTool optimistically + revert-on-failure.

  Plan: docs/superpowers/plans/2026-08-27-kanban-agent-as-tab.md
-->
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  getAgentKanban,
  getAgentToolsRegistry,
  enableAgentKanbanTool,
  disableAgentKanbanTool,
} from '../../api'

const props = withDefaults(
  defineProps<{
    item: { id: string; name?: string } | null
    workspaceId?: string
  }>(),
  { workspaceId: '' },
)

const loading = ref(false)
const loadError = ref<string | null>(null)
// `config` is only needed to know "is there an agent_kanban row yet?"
// — toggles use `config.value.id` as the kanbanId. Null = unconfigured.
const config = ref<{ id: string } | null>(null)
const tools = ref<string[]>([])
const toolRegistry = ref<{ name: string; description: string }[]>([])

const kanbanId = computed(() => props.item?.id ?? '')

const errText = (err: unknown): string => {
  const msg = err instanceof Error ? err.message : String(err)
  return msg.replace(/^API \d+:\s*/, '')
}

const load = async () => {
  if (!kanbanId.value) return
  loading.value = true
  loadError.value = null
  try {
    try {
      const reg = await getAgentToolsRegistry()
      toolRegistry.value = reg.tools
    } catch {
      toolRegistry.value = []
    }
    const data = await getAgentKanban(props.workspaceId ?? '', kanbanId.value)
    if (data) {
      config.value = data.agent_kanban
      tools.value = [...data.tools].sort()
    } else {
      config.value = null
      tools.value = []
    }
  } catch (err) {
    loadError.value = errText(err)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  void load()
})

const toolBusy = ref(false)
const isEnabled = (toolName: string) => tools.value.includes(toolName)

const handleToggleTool = async (toolName: string) => {
  if (!config.value || toolBusy.value) return
  toolBusy.value = true
  const wasEnabled = isEnabled(toolName)
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
  <div data-testid="kanban-tools-panel">
    <div
      v-if="loading"
      class="px-5 py-8 text-sm text-center"
      style="color: var(--semantic-text-dim)"
      data-testid="kanban-tools-loading"
    >
      Loading…
    </div>
    <div
      v-else-if="loadError && !config"
      class="px-5 py-6 text-sm text-center"
      style="color: rgb(239, 68, 68)"
      data-testid="kanban-tools-error"
    >
      {{ loadError }}
    </div>

    <!-- Configured: render the checkbox grid -->
    <div
      v-else-if="config"
      class="px-5 py-5 overflow-y-auto flex flex-col gap-3"
      style="max-height: calc(100vh - 14rem)"
    >
      <section data-testid="kanban-agent-tools-panel">
        <div class="flex items-center justify-between mb-2">
          <h4 class="text-sm font-semibold" style="color: var(--semantic-text)">
            Tools
            <span class="ml-1 text-xs font-normal" style="color: var(--semantic-text-dim)">
              ({{ tools.length }} enabled)
            </span>
          </h4>
        </div>
        <ul class="grid grid-cols-2 gap-1">
          <li v-for="t in toolRegistry" :key="t.name">
            <label
              class="flex items-center gap-2 px-3 py-2 rounded-lg text-xs cursor-pointer select-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border)"
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
              <span class="truncate" style="color: var(--semantic-text)" :title="t.description">
                {{ t.name }}
              </span>
            </label>
          </li>
        </ul>
        <p
          v-if="!toolRegistry.length"
          class="text-xs mt-1"
          style="color: var(--semantic-text-dim)"
          data-testid="kanban-agent-tools-empty"
        >
          Tool registry unavailable.
        </p>
      </section>

      <p
        v-if="loadError && config"
        class="text-xs px-3 py-2 rounded-lg"
        style="color: rgb(239, 68, 68); background-color: rgba(239, 68, 68, 0.08)"
        data-testid="kanban-tools-mutation-error"
      >
        {{ loadError }}
      </p>
    </div>

    <!-- Unconfigured: still show the tools picker so the user can
         bootstrap the config by enabling any tool. -->
    <div
      v-else
      class="px-5 py-8 flex flex-col items-center gap-3"
      data-testid="kanban-tools-unconfigured"
    >
      <p class="text-sm text-center" style="color: var(--semantic-text-dim)">
        This board has no agent config yet. Enable a tool below to create one.
      </p>
      <ul class="w-full grid grid-cols-2 gap-1">
        <li v-for="t in toolRegistry" :key="t.name">
          <label
            class="flex items-center gap-2 px-3 py-2 rounded-lg text-xs cursor-pointer select-none"
            style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border)"
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
            <span class="truncate" style="color: var(--semantic-text)" :title="t.description">
              {{ t.name }}
            </span>
          </label>
        </li>
      </ul>
    </div>
  </div>
</template>
