<!--
  ProgressiveTool — universal renderer for `search_tool` / `view_tool` / `use_tool`.

  The three progressive-discovery tools let the agent browse a catalog of
  not-yet-enabled tools and equip one for the session. Backend renderers live
  in `src/agentic_loop/progressive_catalog.zig`; the exec adapter wraps them
  with the standard `wrapToolOutput` envelope, and `ChatView.innerToolData`
  passes the inner body here (see `toolOutputParser.ts` for the wire shapes).

  Header (always visible, via ToolCardHeader):
    `search_tool → "<query>" · N tools ✓` (or `error ✗`)
    `view_tool → <name> · <kind> ✓` (or `error ✗` / `not found ✗`)
    `use_tool → <name> · enabled ✓` (or `already enabled ✓` / `error ✗`)

  Expanded body (click header to toggle):
    search_tool: one row per tool (bold name + kind/server/equipped chips +
      muted summary). Truncated hint or catalog hint below.
    view_tool: description + JSON-pretty parameters + note/hint +
      did-you-mean list. Error: red block.
    use_tool: kind/equipped/inserted rows + JSON-pretty parameters + note.
      Error: red block + did-you-mean list.
    Non-empty JSON args render via shared ToolParameters below the output.

  Style matches the other tool_outputs cards (McpTool, ListDirectory):
  monospace, rounded-md, border + soft card bg, violet tool-name, ✓/✗
  status indicators, expand/collapse chevron on the right.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { parseSearchTool, parseUseTool, parseViewTool } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  toolName: string
  parameters?: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

const isSearch = computed(() => props.toolName === 'search_tool')
const isView = computed(() => props.toolName === 'view_tool')
const isUse = computed(() => props.toolName === 'use_tool')

const search = computed(() => parseSearchTool(props.content))
const view = computed(() => parseViewTool(props.content))
const use = computed(() => parseUseTool(props.content))

const isRunning = computed(() => props.content.trim().length === 0)

const success = computed(() => {
  if (isSearch.value) return search.value.success
  if (isView.value) return view.value.success
  if (isUse.value) return use.value.success
  return false
})

const primary = computed(() => {
  if (isSearch.value) {
    const q = search.value.query
    return q ? `"${q}"` : 'catalog'
  }
  if (isView.value) return view.value.name || props.toolName
  if (isUse.value) return use.value.name || props.toolName
  return props.toolName
})

const rightMeta = computed(() => {
  if (isSearch.value) {
    if (!search.value.success) return 'Error'
    const n = search.value.tools.length
    return `${n} tool${n === 1 ? '' : 's'}`
  }
  if (isView.value) {
    if (!view.value.success) return view.value.found ? 'Error' : 'Not found'
    const bits = [view.value.kind, view.value.server].filter((s) => s && s.length > 0)
    return bits.length > 0 ? bits.join(' · ') : 'found'
  }
  if (isUse.value) {
    if (!use.value.success) return 'Error'
    return use.value.inserted ? 'enabled' : 'already enabled'
  }
  return null
})

const copyValue = computed(() => {
  if (isSearch.value) return search.value.tools.map((t) => t.name).join('\n')
  if (isView.value) return view.value.prettyParameters || view.value.description || view.value.name
  if (isUse.value) return use.value.prettyParameters || use.value.name
  return primary.value
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': !success }"
    data-testid="progressive-tool"
  >
    <ToolCardHeader
      :tool-name="props.toolName"
      :primary="primary"
      :success="success"
      :expanded="isExpanded"
      :expandable="true"
      :show-open-in-editor="false"
      :copy-value="copyValue"
      :right-meta="rightMeta"
      :running="isRunning"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <!-- ── search_tool ── -->
      <template v-if="isSearch">
        <div
          v-if="!search.success"
          class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
        >
          <span class="font-semibold shrink-0">Error:</span>
          <span class="whitespace-pre-wrap break-all">{{ search.error || 'unknown error' }}</span>
        </div>
        <template v-else>
          <div v-if="search.tools.length === 0" class="px-2 py-1.5 text-[var(--semantic-text-muted)]">
            No tools match — try a broader query.
          </div>
          <div
            v-for="tool in search.tools"
            :key="tool.name"
            class="px-2 py-1.5 border-b border-[var(--color-border)] last:border-b-0"
            data-testid="progressive-tool-row"
          >
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class="font-semibold text-[var(--semantic-text)]">{{ tool.name }}</span>
              <span
                v-if="tool.kind"
                class="text-[0.65rem] px-1 rounded bg-violet-500/10 text-violet-500"
              >{{ tool.kind }}</span>
              <span
                v-if="tool.server"
                class="text-[0.65rem] px-1 rounded bg-black/[0.04] text-[var(--semantic-text-muted)]"
              >{{ tool.server }}</span>
              <span
                v-if="tool.equipped === 'session'"
                class="text-[0.65rem] px-1 rounded bg-green-500/10 text-green-500"
              >session</span>
            </div>
            <div
              v-if="tool.summary"
              class="mt-0.5 text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            >{{ tool.summary }}</div>
          </div>
          <div
            v-if="search.hint"
            class="px-2 py-1.5 text-[var(--semantic-text-muted)]"
          >{{ search.hint }}</div>
        </template>
      </template>

      <!-- ── view_tool ── -->
      <template v-else-if="isView">
        <div
          v-if="!view.success"
          class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
        >
          <span class="font-semibold shrink-0">Error:</span>
          <span class="whitespace-pre-wrap break-all">{{ view.error || 'unknown error' }}</span>
        </div>
        <div v-else class="px-2 py-1.5 flex flex-col gap-1.5">
          <div
            v-if="view.description"
            class="whitespace-pre-wrap break-words text-[var(--semantic-text)]"
          >{{ view.description }}</div>
          <div class="flex items-center gap-1.5 flex-wrap text-[var(--semantic-text-muted)]">
            <span v-if="view.kind" class="text-[0.65rem] px-1 rounded bg-violet-500/10 text-violet-500">{{ view.kind }}</span>
            <span v-if="view.server" class="text-[0.65rem] px-1 rounded bg-black/[0.04]">{{ view.server }}</span>
            <span v-if="view.equipped" class="text-[0.65rem] px-1 rounded bg-black/[0.04]">equipped: {{ view.equipped }}</span>
          </div>
          <pre
            v-if="view.prettyParameters"
            class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-words overflow-x-auto leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5"
            data-testid="progressive-tool-parameters"
          >{{ view.prettyParameters }}</pre>
          <div v-if="view.note" class="text-[var(--semantic-text-muted)]">{{ view.note }}</div>
          <div v-if="view.hint" class="text-[var(--semantic-text-muted)]">{{ view.hint }}</div>
        </div>
        <div v-if="!view.success || view.suggestions.length > 0" class="px-2 pb-1.5">
          <div
            v-for="s in view.suggestions"
            :key="s"
            class="text-[var(--color-violet)]"
          >{{ s }}</div>
          <div v-if="view.hint && !view.success" class="text-[var(--semantic-text-muted)]">{{ view.hint }}</div>
        </div>
      </template>

      <!-- ── use_tool ── -->
      <template v-else-if="isUse">
        <div
          v-if="!use.success"
          class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
        >
          <span class="font-semibold shrink-0">Error:</span>
          <span class="whitespace-pre-wrap break-all">{{ use.error || 'unknown error' }}</span>
        </div>
        <div v-else class="px-2 py-1.5 flex flex-col gap-1.5">
          <div class="flex items-center gap-1.5 flex-wrap text-[var(--semantic-text-muted)]">
            <span v-if="use.kind" class="text-[0.65rem] px-1 rounded bg-violet-500/10 text-violet-500">{{ use.kind }}</span>
            <span class="text-[0.65rem] px-1 rounded bg-green-500/10 text-green-500">
              {{ use.inserted ? 'enabled this session' : 'already enabled' }}
            </span>
            <span v-if="use.waitNextTurn" class="text-[0.65rem] px-1 rounded bg-black/[0.04]">takes effect next turn</span>
          </div>
          <pre
            v-if="use.prettyParameters"
            class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-words overflow-x-auto leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5"
            data-testid="progressive-tool-parameters"
          >{{ use.prettyParameters }}</pre>
          <div v-if="use.note" class="text-[var(--semantic-text-muted)]">{{ use.note }}</div>
        </div>
        <div v-if="use.suggestions.length > 0 || (use.hint && !use.success)" class="px-2 pb-1.5">
          <div
            v-for="s in use.suggestions"
            :key="s"
            class="text-[var(--color-violet)]"
          >{{ s }}</div>
          <div v-if="use.hint" class="text-[var(--semantic-text-muted)]">{{ use.hint }}</div>
        </div>
      </template>

      <ToolParameters :parameters="props.parameters" />
    </div>
  </div>
</template>
