<!--
  SaveMemory — tool output component for the `save_memory` agent tool.

  Renders the XML envelope produced by `executeSaveMemory` in
  `src/modules/agent/tools/memory.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Three response shapes are possible (inner data extracted by
  `ChatView.innerToolData`, so this component receives the inner
  `<save_memory>...</save_memory>` body):
    Success (UPSERT):
      <save_memory>
        <id>mem_aabbcc...</id>
        <created_at>YYYY-MM-DD HH:MM:SS</created_at>
        <updated_at>YYYY-MM-DD HH:MM:SS</updated_at>
      </save_memory>
    Empty/missing fields (stale DB row or partial envelope):
      <save_memory><id>...</id></save_memory> — still a success; missing
      timestamp fields render as muted "—" placeholders.
    Error:
      <save_memory><error>...</error></save_memory>

  Header (always visible):
    `save_memory → <id> ✓` (success)        — id truncated with ellipsis
    `save_memory → error ✗`                 (failure)

  Expanded body (click header to toggle):
    Success: three rows (id + copy, created_at, updated_at).
    Error:   red error block with the full error message.

  Style is consistent with the rest of the tool_outputs components
  (KanbanMove, KanbanList, ReadWorkspaceSession): monospace, rounded-md,
  border + soft card bg, violet tool-name, ✗/✓ status indicators,
  expand/collapse `+`/`−` toggle on the right.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { extractParam } from '../../helpers/extractParam'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent } from './_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Used as a fallback
   *  so a still-running tool (empty content) shows its target id. */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// ---- Parsers ---------------------------------------------------------------

function asRecord(v: unknown): Record<string, unknown> {
  if (typeof v === 'string') {
    try {
      const p: unknown = JSON.parse(v)
      return typeof p === 'object' && p !== null && !Array.isArray(p)
        ? (p as Record<string, unknown>)
        : {}
    } catch {
      return {}
    }
  }
  return typeof v === 'object' && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {}
}

function strOrNull(v: unknown): string | null {
  if (v === null || v === undefined) return null
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

const normalized = computed(() => normalizeToolContent(props.content))
const dataRecord = computed(() => asRecord(normalized.value.data))

const errorMessage = computed(() => normalized.value.error ?? strOrNull(dataRecord.value.error))

const memoryId = computed(() => {
  const id = strOrNull(dataRecord.value.id)
  if (id) return id
  // In-progress fallback: the result envelope is still empty, so show the
  // id the tool was called with (from the `parameters` prop).
  return extractParam(props.parameters, 'id')
})

// Running: result envelope is still empty (no error, no id).
const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const isRunning = computed(() => isEmptyContent(props.content))

const createdAt = computed(() => strOrNull(dataRecord.value.created_at))

const updatedAt = computed(() => strOrNull(dataRecord.value.updated_at))

// ---- Derived display values ------------------------------------------------

const isSuccess = computed(() => errorMessage.value === null)

const statusIndicator = computed(() => (isRunning.value ? '…' : isSuccess.value ? '✓' : '✗'))

// Header label: "<id>" on success (truncated), "error" on failure.
// We trim+strip the save_memory wrapper so the user sees the mem_<id>
// not the raw XML.
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

const toggle = () => {
  // Always expandable on success (3 timestamp rows) or error (1 row).
  // On empty/missing envelopes (no id + no error) we still allow
  // expansion so the user sees "what's in here" — but it's a no-op
  // visually when there are no fields.
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
    data-testid="save-memory"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">save_memory</span>
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
        data-testid="save-memory-running"
        class="text-[0.65rem] text-yellow-500 animate-pulse shrink-0"
      >
        running…
      </span>

      <!-- Copy id button (only on success — there's something to copy) -->
      <button
        v-if="isSuccess && memoryId"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copyId"
        title="Copy memory id"
        data-testid="save-memory-copy-id"
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
        data-testid="save-memory-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Success path: id + created_at + updated_at rows -->
      <template v-if="isSuccess">
        <div
          v-if="memoryId"
          class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
          data-testid="save-memory-id-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Id:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            memoryId
          }}</span>
        </div>

        <div
          v-if="createdAt"
          class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
          data-testid="save-memory-created-at-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Created:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            createdAt
          }}</span>
        </div>

        <div
          v-if="updatedAt"
          class="flex gap-2 px-2 py-1.5 text-xs"
          data-testid="save-memory-updated-at-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Updated:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            updatedAt
          }}</span>
        </div>

        <!-- Edge case: empty envelope (no id, no timestamps). Show a
             muted hint so the user knows the card is empty, not stuck. -->
        <div
          v-if="!memoryId && !createdAt && !updatedAt"
          class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-xs italic"
          data-testid="save-memory-empty"
        >
          (no fields in envelope)
        </div>
      </template>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
