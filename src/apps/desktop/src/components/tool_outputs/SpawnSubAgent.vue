<script setup lang="ts">
import { computed, ref } from 'vue'
import type { SubAgentArgs } from '../../helpers/parseSpawnSubAgentArgs'
import type { SubAgentProgress } from '../../helpers/subagentProgress'

const props = defineProps<{
  content: string
  expanded?: boolean
  subAgentArgs?: SubAgentArgs[] | null
  /**
   * 2026-08-23 spawn-subagent-live-progress: live per-sub-agent
   * progress fed from ChatView's per-tool_call_id map. When set
   * AND `content` has no parsed <results> envelope, the component
   * renders these rows directly (auto-expanded — no toggle needed).
   *
   * When `content` contains an envelope (after the tool result
   * lands), the parsed-results view wins and this prop is ignored —
   * the envelope is the source of truth on completion. The map is
   * then deleted from ChatView via `clearProgressFor(tool_call_id)`.
   */
  progress?: SubAgentProgress[] | null
}>()

const emit = defineEmits<{
  /**
   * Fired when the user clicks 👁 on a sub-agent row. The parent
   * (ChatView) opens <SubAgentPeekPanel> with this payload.
   */
  peek: [payload: { sessionId: string; agentName: string; instruction: string }]
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse agents from <agent> tags
interface AgentResult {
  name: string
  success: boolean
  response: string | null
  error: string | null
  sessionId: string | null
  /** True when the requested agent_name was not found in
   * LlmConfig.sub_agents and a random name was used as a fallback. */
  randomFallback: boolean
}

const agents = computed((): AgentResult[] => {
  const results: AgentResult[] = []
  // Note: capture group 4 = `random_fallback="..."` attribute. Default
  // to "false" when absent so legacy results (pre-feature) parse
  // cleanly.
  const agentRegex = /<agent name="([^"]*)" success="([^"]*)"(?: random_fallback="([^"]*)")?>([\s\S]*?)<\/agent>/g
  let match

  while ((match = agentRegex.exec(props.content)) !== null) {
    const name = match[1] ?? ''
    const success = match[2] === 'true'
    const randomFallback = match[3] === 'true'
    const agentContent = match[4] ?? ''

    // Extract session_id, response or error
    const sessionIdMatch = agentContent.match(/<session_id>([\s\S]*?)<\/session_id>/)
    const responseMatch = agentContent.match(/<response>([\s\S]*?)<\/response>/)
    const errorMatch = agentContent.match(/<error>([\s\S]*?)<\/error>/)

    results.push({
      name,
      success,
      sessionId: sessionIdMatch?.[1]?.trim() ?? null,
      response: responseMatch?.[1]?.trim() ?? null,
      error: errorMatch?.[1]?.trim() ?? null,
      randomFallback,
    })
  }

  return results
})

// Parse summary
const summary = computed(() => {
  const match = props.content.match(/<summary succeeded="(\d+)" failed="(\d+)" \/>/)
  if (match?.[1] && match?.[2]) {
    return {
      succeeded: parseInt(match[1], 10),
      failed: parseInt(match[2], 10),
    }
  }
  return null
})

// Success count
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const successCount = computed(() => {
  return agents.value.filter(a => a.success).length
})

// Failure count
const failedCount = computed(() => {
  return agents.value.filter(a => !a.success).length
})

// Expanded agents set
const expandedAgents = ref<Set<number>>(new Set())

const toggleAgent = (idx: number) => {
  const newSet = new Set(expandedAgents.value)
  if (newSet.has(idx)) {
    newSet.delete(idx)
  } else {
    newSet.add(idx)
  }
  expandedAgents.value = newSet
}

const toggle = () => {
  // In live-progress mode the body is already shown — toggle is a no-op.
  if (inLiveMode.value) return
  if (agents.value.length > 0) {
    isExpanded.value = !isExpanded.value
  }
}

// Copy agent response
const copyResponse = async (e: Event, response: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(response)
}

// ─── Live-progress rendering (2026-08-23) ──────────────────────────────
//
// Source-of-truth precedence: parsed envelope (from content) > live
// progress (from props). The parsed-envelope view never changes
// post-completion, while progress is ephemeral. Live mode is "on"
// whenever progress is non-empty AND no envelope has been parsed yet.
//
// Live rows render inside the same `<div v-if="isExpanded">` slot
// (auto-shown) so the existing card chrome is reused: badge, peek
// button, inherited-context chip, etc. Behavioural differences:
//   - Header counts show running/done/failed instead of ✓N ✗N
//   - Rows render even when expandedAgents is empty
//   - The toggle caret becomes a no-op (replaces '+' with nothing)
//   - Failed rows get the red error styling immediately

const liveProgress = computed(() => props.progress ?? [])

const inLiveMode = computed(
  () => liveProgress.value.length > 0 && agents.value.length === 0,
)

const liveSummary = computed(() => {
  const rows = liveProgress.value
  return {
    running: rows.filter(r => r.status === 'running').length,
    done: rows.filter(r => r.status === 'done').length,
    failed: rows.filter(r => r.status === 'failed').length,
  }
})

/**
 * Emit a peek event for one sub-agent row. In live-progress mode,
 * rows carry `sessionId` (set by `applyProgressEvent` once the
 * `launched` event arrives with `subagent_session_id`). Same payload
 * shape as the parsed-envelope peek so ChatView's
 * <SubAgentPeekPanel> doesn't need to branch.
 */
function peekLiveAgent(idx: number, row: SubAgentProgress) {
  if (!row.sessionId) return
  const instruction = props.subAgentArgs?.[idx]?.instruction ?? ''
  emit('peek', {
    sessionId: row.sessionId,
    agentName: row.name,
    instruction,
  })
}

function peekAgent(idx: number, agent: { sessionId: string | null; name: string }) {
  if (!agent.sessionId) return
  const instruction = props.subAgentArgs?.[idx]?.instruction ?? ''
  emit('peek', {
    sessionId: agent.sessionId,
    agentName: agent.name,
    instruction,
  })
}

// Count of agents
const agentCount = computed(() => agents.value.length)

// True when at least one sub-agent has a non-`none` inherited_context mode.
const hasInheritedContext = computed(() => {
  if (!props.subAgentArgs) return false
  return props.subAgentArgs.some(
    a => a.inherited_context && a.inherited_context !== 'none'
  )
})

// Human-readable description of the inherited_context mode for the badge tooltip.
function describeInheritedContext(mode: string): string {
  if (mode === 'all') return 'all parent messages'
  if (mode === 'since_last_user') return 'from the last user message onward'
  const m = mode.match(/^last:(\d+)$/)
  if (m) return `last ${m[1]} parent messages (default 10 if unspecified)`
  return mode
}

// Format elapsed_ms as a short chip (e.g. "12s", "1m 03s"). Defensive
// against negative / NaN values from clock skew between thread entry
// and the backend emit.
function formatElapsed(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return ''
  const totalSec = Math.floor(ms / 1000)
  if (totalSec < 60) return `${totalSec}s`
  const m = Math.floor(totalSec / 60)
  const s = totalSec % 60
  return `${m}m ${s.toString().padStart(2, '0')}s`
}
</script>

<template>
  <div 
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': failedCount > 0 || liveSummary.failed > 0 }"
  >
    <!-- Header -->
    <div 
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">spawn_sub_agent</span>
      <span class="flex-1 truncate text-left text-[var(--color-violet)] font-medium" :title="(inLiveMode ? liveProgress.length : agentCount) + ' sub-agent(s)'">
        <template v-if="inLiveMode">
          {{ liveProgress.length }} sub-agent{{ liveProgress.length !== 1 ? 's' : '' }}
        </template>
        <template v-else>
          {{ agentCount }} sub-agent{{ agentCount !== 1 ? 's' : '' }}
        </template>
      </span>
      <span
        v-if="hasInheritedContext"
        class="text-[10px] text-[var(--color-violet)] opacity-70 whitespace-nowrap"
        title="At least one sub-agent was spawned with parent conversation history"
      >
        ↻ with parent history
      </span>
      <!-- Live-progress summary (2026-08-23) -->
      <span v-if="inLiveMode" class="flex items-center gap-1.5">
        <span v-if="liveSummary.running > 0" class="text-[var(--semantic-text-muted)] font-semibold" data-testid="running-count">
          {{ liveSummary.running }} running
        </span>
        <span v-if="liveSummary.done > 0" class="text-green-500 font-semibold" data-testid="done-count">
          ✓ {{ liveSummary.done }}
        </span>
        <span v-if="liveSummary.failed > 0" class="text-red-500 font-semibold" data-testid="failed-count">
          ✗ {{ liveSummary.failed }}
        </span>
      </span>
      <!-- Final-envelope summary -->
      <span v-else-if="summary" class="flex items-center gap-1.5">
        <span v-if="summary.succeeded > 0" class="text-green-500 font-semibold">
          ✓ {{ summary.succeeded }}
        </span>
        <span v-if="summary.failed > 0" class="text-red-500 font-semibold">
          ✗ {{ summary.failed }}
        </span>
      </span>
      <!-- Toggle caret: hidden in live mode (body is always shown). -->
      <span v-if="!inLiveMode && (agentCount > 0 || agents.length > 0)" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded || inLiveMode" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <div class="divide-y divide-[var(--color-border)]">
        <!-- LIVE PROGRESS rows (2026-08-23) — shown until the
             <results> envelope replaces props.content. Mirrors the
             shape of the parsed-envelope rows below for visual
             consistency. -->
        <template v-if="inLiveMode">
          <div
            v-for="(row, idx) in liveProgress"
            :key="`live-${idx}`"
            class="overflow-hidden"
          >
            <div
              class="group flex items-center gap-1 px-2 py-1.5 select-none hover:bg-violet-500/5"
              :class="{ 'bg-red-500/5': row.status === 'failed' }"
            >
              <span
                class="w-2 h-2 rounded-full shrink-0"
                :class="
                  row.status === 'done'
                    ? 'bg-green-500'
                    : row.status === 'failed'
                    ? 'bg-red-500'
                    : 'bg-yellow-500 animate-pulse'
                "
                :data-testid="`live-dot-${idx}`"
              ></span>
              <span class="text-[var(--semantic-text)] font-medium text-xs">{{ row.name || `agent_${idx}` }}</span>
              <span
                v-if="subAgentArgs?.[idx]?.inherited_context && subAgentArgs[idx].inherited_context !== 'none'"
                class="text-[10px] px-1.5 py-0.5 rounded font-mono whitespace-nowrap"
                style="background-color: var(--color-violet); color: white; opacity: 0.85;"
                :title="`Parent history: ${describeInheritedContext(subAgentArgs[idx].inherited_context!)}`"
              >
                parent: {{ subAgentArgs[idx].inherited_context }}
              </span>
              <span
                v-if="row.sessionId"
                class="text-[var(--semantic-text-muted)] text-xs font-mono truncate max-w-[120px]"
                :title="row.sessionId"
              >
                {{ row.sessionId }}
              </span>
              <span
                v-if="formatElapsed(row.elapsedMs)"
                class="text-[10px] text-[var(--semantic-text-muted)] whitespace-nowrap"
              >
                {{ formatElapsed(row.elapsedMs) }}
              </span>
              <button
                v-if="row.sessionId"
                class="text-[var(--semantic-text-muted)] hover:text-[var(--color-violet)] px-1 rounded text-xs leading-none"
                data-testid="peek-button"
                :title="`Peek into ${row.name}'s progress`"
                @click.stop="peekLiveAgent(idx, row)"
              >
                👁
              </button>
              <span class="flex-1"></span>
              <span
                v-if="row.status === 'done'"
                class="text-xs text-green-500"
              >
                done
              </span>
              <span
                v-else-if="row.status === 'failed'"
                class="text-xs text-red-500"
              >
                failed
              </span>
              <span
                v-else
                class="text-xs text-[var(--semantic-text-muted)]"
                data-testid="running-badge"
              >
                running
              </span>
            </div>
          </div>
        </template>
        <!-- PARSED <results> rows (pre-existing) — shown when an
             envelope is present in props.content. Takes precedence
             over live-progress once the tool completes. -->
        <div 
          v-for="(agent, idx) in agents" 
          :key="`env-${idx}`"
          class="overflow-hidden"
        >
          <!-- Agent header -->
          <div 
            class="group flex items-center gap-1 px-2 py-1.5 cursor-pointer select-none hover:bg-violet-500/5"
            :class="{ 'bg-red-500/5': !agent.success }"
            @click="toggleAgent(idx)"
          >
            <span 
              class="w-2 h-2 rounded-full shrink-0"
              :class="agent.success ? 'bg-green-500' : 'bg-red-500'"
            ></span>
            <span class="text-[var(--semantic-text)] font-medium text-xs">{{ agent.name }}</span>
            <span
              v-if="agent.randomFallback"
              class="text-[10px] px-1.5 py-0.5 rounded font-mono whitespace-nowrap"
              style="background-color: var(--semantic-text-muted); color: white; opacity: 0.85;"
              title="Requested agent_name was not found in LlmConfig.sub_agents; a random name was used and the orchestrator's default model was applied."
            >
              random
            </span>
            <span v-if="agent.sessionId" class="text-[var(--semantic-text-muted)] text-xs font-mono truncate max-w-[120px]" :title="agent.sessionId">
              {{ agent.sessionId }}
            </span>
            <span
              v-if="subAgentArgs?.[idx]?.inherited_context && subAgentArgs[idx].inherited_context !== 'none'"
              class="text-[10px] px-1.5 py-0.5 rounded font-mono whitespace-nowrap"
              style="background-color: var(--color-violet); color: white; opacity: 0.85;"
              :title="`Parent history: ${describeInheritedContext(subAgentArgs[idx].inherited_context!)}`"
            >
              parent: {{ subAgentArgs[idx].inherited_context }}
            </span>
            <!-- 👁 peek button — opens <SubAgentPeekPanel> in ChatView.
                 Emits the sub-agent's sessionId + the parsed
                 instruction so the panel can stream its progress
                 without leaving the parent chat. -->
            <button
              v-if="agent.sessionId"
              class="text-[var(--semantic-text-muted)] hover:text-[var(--color-violet)] px-1 rounded text-xs leading-none"
              data-testid="peek-button"
              :title="`Peek into ${agent.name}'s progress`"
              @click.stop="peekAgent(idx, agent)"
            >
              👁
            </button>
            <span class="flex-1"></span>
            <span 
              v-if="agent.success" 
              class="text-xs text-green-500"
            >
              success
            </span>
            <span 
              v-else 
              class="text-xs text-red-500"
            >
              failed
            </span>
            <button 
              v-if="agent.response && expandedAgents.has(idx)"
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
              @click.stop="copyResponse($event, agent.response!)" 
              title="Copy response"
            >
              ⎘
            </button>
            <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
              {{ expandedAgents.has(idx) ? '−' : '+' }}
            </span>
          </div>

          <!-- Expanded agent response/error -->
          <div v-if="expandedAgents.has(idx) && agent.response" class="px-3 py-2 bg-black/[0.02]">
            <pre 
              class="whitespace-pre-wrap break-all text-xs leading-relaxed max-h-64 overflow-y-auto"
              style="color: var(--semantic-text);"
            >{{ agent.response }}</pre>
          </div>
          <div v-if="expandedAgents.has(idx) && agent.error" class="px-3 py-2 bg-red-500/5">
            <pre 
              class="whitespace-pre-wrap break-all text-xs leading-relaxed text-red-500"
            >{{ agent.error }}</pre>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
