<!--
  DeleteMemory — tool output component for the `delete_memory` agent tool.

  Renders the XML envelope produced by `executeDeleteMemory` in
  `src/modules/agent/tools/delete_memory.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Three response shapes are possible (inner data extracted by
  `ChatView.innerToolData`, so this component receives the inner
  `<delete_memory>...</delete_memory>` body):
    Success (row deleted):
      <delete_memory>
        <id>mem_aabbcc...</id>
        <deleted>true</deleted>
      </delete_memory>
    Success (idempotent no-op — unknown id):
      <delete_memory>
        <id>ghost</id>
        <deleted>false</deleted>
      </delete_memory>
    Error:
      <delete_memory><error>id is required</error></delete_memory>

  Header (always visible):
    `delete_memory → <id> ✓ removed`     (deleted=true)
    `delete_memory → <id> ✓ not found`   (deleted=false, muted)
    `delete_memory → error ✗`            (failure)

  Expanded body (click header to toggle):
    Success: id row (with copy) + a red-tinted permanence warning.
    Error:   red error block with the full error message.

  Style is consistent with the rest of the tool_outputs components
  (SaveMemory, KanbanMove, SearchHistory): monospace, rounded-md,
  border + soft card bg, violet tool-name, ✗/✓ status indicators,
  expand/collapse `+`/`−` toggle on the right.

  Plan: docs/superpowers/plans/2026-08-24-delete-memory-agent-tool.md (Task 5)
  Task: task_1787546484030_8
-->
<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// ---- Parsers ---------------------------------------------------------------

const errorMessage = computed(() => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

const memoryId = computed(() => {
  const match = props.content.match(/<id>([\s\S]*?)<\/id>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

const deletedFlag = computed(() => {
  const match = props.content.match(/<deleted>([\s\S]*?)<\/deleted>/)
  if (!match || !match[1]) return null
  return match[1].trim() === 'true'
})

// ---- Derived display values ------------------------------------------------

const isSuccess = computed(() => errorMessage.value === null)

const statusIndicator = computed(() => (isSuccess.value ? '✓' : '✗'))

// Header label: "<id>" on success (truncated), "error" on failure.
const headerLabel = computed(() => {
  if (!isSuccess.value) return 'error'
  return memoryId.value ?? 'unknown'
})

// Hover title shows the full id (no truncation) so power users can
// hover-read it without expanding. On error, show the full error text.
const headerTitle = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? ''
  return memoryId.value ?? ''
})

// Status chip text on success — distinguishes "removed" from
// "not found" so the user sees what actually happened.
const statusChip = computed(() => {
  if (!isSuccess.value) return null
  return deletedFlag.value === true ? 'removed' : 'not found'
})

const isRemoved = computed(() => deletedFlag.value === true)

const toggle = () => {
  // Always expandable on success (id row + warning) or error (1 row).
  // On empty envelopes (no id + no error) we still allow expansion so
  // the user can confirm it's a no-op visually.
  isExpanded.value = !isExpanded.value
}

const copyId = async (e: Event) => {
  e.stopPropagation()
  if (memoryId.value) {
    await navigator.clipboard.writeText(memoryId.value)
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-90': !isSuccess }"
    data-testid="delete-memory"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">delete_memory</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-xs"
        :title="headerTitle"
      >
        {{ headerLabel }}
      </span>

      <!-- Status chip (success only) — removed vs not found -->
      <span
        v-if="isRemoved"
        class="px-1.5 py-0.5 text-[10px] font-semibold rounded bg-red-500/15 text-red-600 border border-red-500/30"
        data-testid="delete-memory-status-removed"
      >
        removed
      </span>
      <span
        v-else-if="statusChip === 'not found'"
        class="px-1.5 py-0.5 text-[10px] font-semibold rounded bg-zinc-500/10 text-zinc-500 border border-zinc-500/20"
        data-testid="delete-memory-status-notfound"
      >
        not found
      </span>

      <!-- Status indicator -->
      <span class="text-xs font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Copy id button (only on success — there's something to copy) -->
      <button
        v-if="isSuccess && memoryId"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copyId"
        title="Copy memory id"
        data-testid="delete-memory-copy-id"
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
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
        data-testid="delete-memory-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Success path: id row + permanence warning -->
      <template v-if="isSuccess">
        <div
          v-if="memoryId"
          class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
          data-testid="delete-memory-id-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Id:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{ memoryId }}</span>
        </div>

        <!-- Permanence warning — red-tinted, always shown on success. -->
        <div
          class="flex gap-2 px-2 py-1.5 text-xs text-red-600 bg-red-500/5 border-t border-red-500/20"
          data-testid="delete-memory-warning"
        >
          <span class="font-semibold shrink-0">⚠</span>
          <span class="whitespace-pre-wrap break-all">
            Deletion is permanent. There is no undo, no soft-delete, no recycle bin.
          </span>
        </div>

        <!-- Edge case: empty envelope (no id). Show a muted hint. -->
          <div
            v-if="!memoryId"
            class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-xs italic"
            data-testid="delete-memory-empty"
          >
            (no fields in envelope)
          </div>
      </template>
    </div>
  </div>
</template>