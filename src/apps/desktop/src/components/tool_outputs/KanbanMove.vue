<!--
  KanbanMove — tool output component for the `kanban_move_task` agent tool.

  Renders the XML envelope produced by `executeKanbanMoveTaskToString` in
  `src/modules/agent/tools/kanban_move_task.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Two response shapes are possible:
    Success:
      <kanban_move>
        <success>true</success>
        <task_id>task_1782549179378</task_id>
        <task_name>fix-blocking-sse-call</task_name>
        <column_id>col_1782442554114534970</column_id>
        <column_name>in progress</column_name>
        <position>0</position>
      </kanban_move>
    Error:
      <kanban_move>
        <success>false</success>
        <error>TaskNotFound: task_9999</error>
      </kanban_move>

  Header (always visible):
    `kanban_move_task → <task_name> · <column_name> ✓`   (success)
    `kanban_move_task → error ✗`                         (failure)

  Expanded body (click header to toggle):
    Success: Task row (id + name), Column row (id + name), Position.
    Error:   Red error block with the full error message.

  Style is consistent with the rest of the tool_outputs components
  (ReadFile, SetGitWorktree, ListSkills): monospace, rounded-md,
  border + soft card bg, violet tool-name, ✗/✓ status indicators,
  expand/collapse `+`/`−` toggle on the right.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { extractParam } from '../../helpers/extractParam'

const props = defineProps<{
  content: string
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). The backend input
   *  shape (`KanbanMoveTaskInput`) uses `task_id` + `target_column_id` /
   *  `target_column_name` — none of which appear in the result envelope
   *  until the move completes. Used as a fallback so a still-running tool
   *  (empty content) shows its target instead of "unknown". */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// ---- Parsers ---------------------------------------------------------------

const isSuccess = computed(() => {
  const match = props.content.match(/<success>([\s\S]*?)<\/success>/)
  return match?.[1]?.trim() === 'true'
})

const taskId = computed(() => {
  const match = props.content.match(/<task_id>([\s\S]*?)<\/task_id>/)
  if (match?.[1]?.trim()) return match[1].trim()
  return extractParam(props.parameters, 'task_id')
})

const taskName = computed(() => {
  const match = props.content.match(/<task_name>([\s\S]*?)<\/task_name>/)
  if (match?.[1]?.trim()) return match[1].trim()
  // Best effort: the input shape has no `task_name` — fall back to the
  // raw `task_id` the tool was called with so the header shows something
  // meaningful while running.
  return extractParam(props.parameters, 'task_name') ?? extractParam(props.parameters, 'task_id')
})

const columnId = computed(() => {
  const match = props.content.match(/<column_id>([\s\S]*?)<\/column_id>/)
  if (match?.[1]?.trim()) return match[1].trim()
  return extractParam(props.parameters, 'target_column_id') ?? extractParam(props.parameters, 'column_id')
})

const columnName = computed(() => {
  const match = props.content.match(/<column_name>([\s\S]*?)<\/column_name>/)
  if (match?.[1]?.trim()) return match[1].trim()
  // Best effort across both input + envelope naming (`target_column_name`
  // is the backend input field; `column_name` covers JSON callers).
  return (
    extractParam(props.parameters, 'column_name') ??
    extractParam(props.parameters, 'target_column_name') ??
    extractParam(props.parameters, 'target_column_id')
  )
})

const position = computed(() => {
  const match = props.content.match(/<position>([\s\S]*?)<\/position>/)
  return match?.[1]?.trim() ?? null
})

const errorMessage = computed(() => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  return match?.[1]?.trim() ?? null
})

// ---- Derived display values ------------------------------------------------

// Running: result envelope is still empty (no <success> yet).
const isRunning = computed(() => props.content.trim() === '')

const statusIndicator = computed(() => (isRunning.value ? '…' : isSuccess.value ? '✓' : '✗'))

// Header label: "<task_name> · <column_name>" on success (or while running,
// from the parameters fallback), "error" on failure.
// We trim+strip the kanban_move wrapper so the user sees "fix-blocking-sse-call"
// not the raw XML.
const headerLabel = computed(() => {
  if (!isSuccess.value && !isRunning.value) return 'error'
  const name = taskName.value ?? 'unknown task'
  const col = columnName.value ?? 'unknown column'
  return `${name} · ${col}`
})

// Hover title shows the task + column ids so power users can copy them.
const headerTitle = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? ''
  return `task: ${taskId.value ?? ''} · column: ${columnId.value ?? ''}`
})

const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copyTaskId = async (e: Event) => {
  e.stopPropagation()
  if (taskId.value) {
    await navigator.clipboard.writeText(taskId.value)
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-90': !isSuccess && !isRunning }"
    data-testid="kanban-move"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">kanban_move_task</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-xs"
        :title="headerTitle"
      >
        {{ headerLabel }}
      </span>

      <!-- Status indicator -->
      <span class="text-xs font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Live badge (tool call underway, envelope still empty) -->
      <span
        v-if="isRunning"
        data-testid="kanban-move-running"
        class="text-[0.65rem] text-yellow-500 animate-pulse shrink-0"
      >
        running…
      </span>

      <!-- Copy task_id button (only on success — there's something to copy) -->
      <button
        v-if="isSuccess && taskId"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copyTaskId"
        title="Copy task id"
      >
        ⎘
      </button>

      <!-- Toggle indicator -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Error message -->
      <div
        v-if="errorMessage"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Success path: task / column / position rows -->
      <template v-if="isSuccess">
        <div
          v-if="taskName"
          class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Task:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{ taskName }}</span>
          <span
            v-if="taskId"
            class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)] text-[0.65rem] truncate"
            :title="taskId"
          >
            ({{ taskId }})
          </span>
        </div>

        <div
          v-if="columnName"
          class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Column:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{ columnName }}</span>
          <span
            v-if="columnId"
            class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)] text-[0.65rem] truncate"
            :title="columnId"
          >
            ({{ columnId }})
          </span>
        </div>

        <div
          v-if="position !== null"
          class="flex gap-2 px-2 py-1.5 text-xs"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Position:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{ position }}</span>
        </div>
      </template>
    </div>
  </div>
</template>