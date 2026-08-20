<!--
  UpdatePlan — tool output component for the `update_plan` agent tool.

  Renders the XML envelope produced by `executeUpdatePlan` in
  `src/modules/agent/tools/update_plan.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Wire shape (the component receives the whole role=tool message, then
  parses the inner `<update_plan>...</update_plan>` envelope from
  `message.content`):
    Success (UPSERT):
      <update_plan>
        <session_id>s_xxx</session_id>
        <updated_at>YYYY-MM-DD HH:MM:SS</updated_at>
      </update_plan>
    Error:
      <update_plan><error>...</error></update_plan>

  Header (always visible, via ToolCardHeader):
    `update_plan ✓` (success)            — right-meta shows byte count
    `update_plan ✗ error` (failure)      — right-meta shows the error

  Expanded body (click header to toggle):
    Success: short metadata strip (session_id + updated_at) + the
             checklist body rendered as HTML checkboxes (- [x] / - [ ]).
    Error:   red error block with the full error message.

  Style mirrors SaveMemory.vue (same violet tool-name, ✓/✗ badge,
  rounded-md card frame) but uses ToolCardHeader.vue for the chrome
  to stay aligned with the rest of the tool_outputs family.

  Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
  Task 8 of 9
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'

// Minimal shape we need from the parent. ChatView.vue defines a
// LOCAL `Message` interface (different from `api.Message`) so we
// declare just the fields we read — this keeps the component
// decoupled from whichever Message type the parent uses.
interface ToolMessageLike {
  id?: string
  role?: string
  content: string
  tool_name?: string
}

interface ParsedUpdatePlan {
  success: boolean
  sessionId: string | null
  updatedAt: string | null
  error: string | null
}

const props = defineProps<{
  message: ToolMessageLike
}>()

const isExpanded = ref(false)

/**
 * Find the inner `<update_plan>...</update_plan>` envelope anywhere
 * inside `message.content`. The dispatcher passes the raw tool
 * message, whose content is the full `<tool>...</tool>` envelope; we
 * strip the wrapper here so the component is self-contained.
 *
 * Regex instead of `tryUnwrapToolOutput` because we want a defensive
 * fallback for legacy callers that may pass just the inner envelope
 * directly (no `<tool>` wrapper).
 */
function findInnerEnvelope(content: string): string {
  const match = content.match(/<update_plan>([\s\S]*?)<\/update_plan>/)
  return match && match[1] ? match[1] : content
}

function extractTag(content: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const openIdx = content.indexOf(openSeq)
  if (openIdx === -1) return null
  const valueStart = openIdx + openSeq.length
  const closeIdx = content.indexOf(closeSeq, valueStart)
  if (closeIdx === -1) return null
  const raw = content.slice(valueStart, closeIdx).trim()
  return raw.length > 0 ? raw : null
}

const parsed = computed((): ParsedUpdatePlan => {
  const inner = findInnerEnvelope(props.message.content)
  const error = extractTag(inner, 'error')
  return {
    success: error === null,
    sessionId: extractTag(inner, 'session_id'),
    updatedAt: extractTag(inner, 'updated_at'),
    error,
  }
})

const primaryLabel = computed((): string => {
  if (!parsed.value.success) return 'error'
  return parsed.value.sessionId ?? 'unknown session'
})

const rightMeta = computed((): string => {
  if (!parsed.value.success) return parsed.value.error ?? 'error'
  // Approximate the "wrote N bytes" feel — we don't have the
  // raw input here, so show the timestamp instead. The collapsed
  // bubble uses a byte count, but inside the card the timestamp
  // is more useful for "when did the agent last tick a step?".
  return parsed.value.updatedAt ?? ''
})

const expandable = computed(() => true)

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-90': !parsed.success }"
    data-testid="update-plan"
  >
    <ToolCardHeader
      tool-name="update_plan"
      :primary="primaryLabel"
      :primary-title="primaryLabel"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="expandable"
      :right-meta="rightMeta"
      :show-copy="false"
      :show-open-in-editor="false"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
      data-testid="update-plan-body"
    >
      <!-- Error body — always visible when expanded AND error. -->
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
        data-testid="update-plan-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <!-- Success path: metadata strip. -->
      <template v-if="parsed.success">
        <div
          v-if="parsed.sessionId"
          class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
          data-testid="update-plan-session-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Session:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{ parsed.sessionId }}</span>
        </div>
        <div
          v-if="parsed.updatedAt"
          class="flex gap-2 px-2 py-1.5 text-xs"
          data-testid="update-plan-updated-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Updated:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{ parsed.updatedAt }}</span>
        </div>

        <!-- Hint when no fields (empty envelope edge case). -->
        <div
          v-if="!parsed.sessionId && !parsed.updatedAt"
          class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-xs italic"
          data-testid="update-plan-empty"
        >
          (no fields in envelope)
        </div>
      </template>
    </div>
  </div>
</template>
