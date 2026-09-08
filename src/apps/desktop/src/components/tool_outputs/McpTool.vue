<!--
  McpTool — universal renderer for ANY `mcp_*` agent tool.

  The registry name is `mcp_<server>_<tool>` (see
  `prompts_build_messages_for_agent_prompt.zig::convertMcpToolsToAgentTools`):
  e.g. `mcp_graphify_graph_stats`, `mcp_db_query`. One component serves all
  servers — no per-server card needed.

  Backend wire shape (`handle_tool.zig`):
    success: RAW server text (NOT a `<tool>` envelope) — e.g. plain text or JSON.
    failure: `wrapToolOutput(..., success=false, err, "")` envelope.
  `ChatView.innerToolData` passes the inner `<data>` on envelope success and
  falls back to full content otherwise, so this component receives EITHER the
  raw output OR a full error envelope. `parseMcp` tolerates both (see
  `toolOutputParser.ts`).

  Header (always visible, via ToolCardHeader):
    `mcp_graphify_graph_stats → graphify · graph_stats · 3L ✓`
    `mcp_db_query → error ✗` (failure)

  Expanded body (click header to toggle):
    Success: `<pre>` with JSON-pretty output when parseable, else raw text.
    Failure: red error block.
    Non-empty JSON args render via shared ToolParameters below the output.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { parseMcp } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  toolName: string
  parameters?: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseMcp(props.toolName, props.content))

const primary = computed(() => {
  const { server, subTool } = parsed.value
  if (server && subTool) return `${server} · ${subTool}`
  if (subTool) return subTool
  if (server) return server
  return props.toolName
})

const rightMeta = computed(() => {
  if (!parsed.value.success) return 'Error'
  const lines = parsed.value.lineCount
  return `${lines}L`
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
  >
    <ToolCardHeader
      :tool-name="props.toolName"
      :primary="primary"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :show-open-in-editor="false"
      :copy-value="parsed.prettyOutput"
      :right-meta="rightMeta"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div v-if="!parsed.success" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error || 'unknown error' }}</span>
      </div>
      <pre
        v-else
        class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-words overflow-x-auto leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5"
        data-testid="mcp-tool-output"
      >{{ parsed.prettyOutput || '(empty)' }}</pre>
      <ToolParameters :parameters="props.parameters" />
    </div>
  </div>
</template>
