<script setup lang="ts">
/**
 * AgentErrorCard — dedicated renderer for agentic-loop error/retry
 * diagnostics (task_1787663566535_2).
 *
 * The backend emits these over the SAME llm_full SSE event as normal
 * messages, but marks them with is_error=true (workflow.zig's 3
 * diagnostic sites: retry-catch, unexpected finish_reason, and the
 * soft/hard TooManyRetries bails). ChatView routes them here instead of
 * the message list.
 *
 * Message shape (from saveRetryAttemptMessage / bail diagnostics):
 *   [Retry {attempt}/{max}] {error_name} ({source}). Retrying in {delay_ms}ms.
 *   Server said: {server_detail}
 * or the bail variant:
 *   [Agent Nalar System error] workflow halted after {n} consecutive retries.
 *   Reason for last retry: {error} (source: {source}).
 *   Server said: {detail}
 *
 * Purely presentational — parses props.content, no store/API access.
 */
import { computed } from 'vue'

const props = defineProps<{ content: string }>()

// "[Retry 1/10]" → "1/10". Absent on bail diagnostics.
const retryLabel = computed((): string | null => {
  const m = props.content.match(/\[Retry (\d+\/\d+)\]/)
  return m ? m[1]! : null
})

// "Retrying in 10000ms" → "10000ms". Absent when formatting failed.
const delayMs = computed((): string | null => {
  const m = props.content.match(/Retrying in (\d+ms)/)
  return m ? m[1]! : null
})

// Headline = error name + source. Handles both shapes:
//   "... StreamInterrupted (callDynamicAgentNew). Retrying in ..."
//   "Reason for last retry: StreamInterrupted (source: callDynamicAgentNew)."
const headline = computed((): string => {
  const reason = props.content.match(/Reason for last retry:\s*(.+?)\.?\s*$/m)
  if (reason) return reason[1]!.trim()
  // Strip the [Retry n/m] prefix and trailing sentences; keep
  // "{error_name} ({source})".
  const stripped = props.content.replace(/\[Retry \d+\/\d+\]\s*/, '')
  const firstLine = stripped.split('\n')[0] ?? stripped
  const m = firstLine.match(/^(.*?)\.\s*(Retrying|$)/)
  return (m ? m[1]! : firstLine).trim()
})

// Everything after "Server said:" — the raw server detail (HTTP body,
// SSE sample, etc.). May span multiple lines.
const serverDetail = computed((): string | null => {
  const idx = props.content.indexOf('Server said:')
  if (idx === -1) return null
  return props.content.slice(idx + 'Server said:'.length).trim() || null
})
</script>

<template>
  <div
    class="agent-error-card rounded-xl border border-red-500/30 bg-red-500/5 px-3 py-2 text-sm"
    data-testid="agent-error-card"
    role="alert"
  >
    <header class="flex items-center gap-2 select-none">
      <span aria-hidden="true" class="text-red-500">⚠</span>
      <span class="font-medium text-red-500">Agent error</span>
      <span
        v-if="retryLabel"
        class="rounded-full bg-red-500/15 px-2 py-0.5 text-xs text-red-400"
        data-testid="agent-error-retry"
      >retry {{ retryLabel }}</span>
      <span
        v-if="delayMs"
        class="text-xs text-[var(--semantic-text-muted)]"
        data-testid="agent-error-delay"
      >{{ delayMs }}</span>
    </header>

    <div class="mt-1 text-xs text-[var(--semantic-text-muted)]" data-testid="agent-error-headline">
      {{ headline }}
    </div>

    <div
      v-if="serverDetail"
      class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all rounded-lg bg-black/20 px-2 py-1.5 font-mono text-xs text-red-300"
      data-testid="agent-error-detail"
    >{{ serverDetail }}</div>
  </div>
</template>
