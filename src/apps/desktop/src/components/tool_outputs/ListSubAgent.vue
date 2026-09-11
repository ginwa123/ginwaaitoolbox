<!--
  ListSubAgent — tool output component for the `list_sub_agent` agent tool.

  Renders the XML envelope produced by the backend `list_sub_agent` tool.
  Purely presentational: no API calls, no store mutations, no navigation.

  Wire shape (whole role=tool message in `message.content`, inner envelope
  parsed here — self-contained `:message="msg"` idiom, copied from
  GetPlan.vue):
    Populated:
      <list_sub_agent><profile>P</profile><count>N</count><sub_agents>
        <sub_agent><name>..</name><model>..</model><url_style>..</url_style>
        <thinking>..</thinking><temperature>..</temperature>
        [<max_capacity_tokens>..</max_capacity_tokens>]
        [<compaction_threshold_percent>..</compaction_threshold_percent>]
        [<thinking_budget_tokens>..</thinking_budget_tokens>]
        [<reasoning_effort>..</reasoning_effort>]
        <system_prompt><![CDATA[full text]]></system_prompt></sub_agent>
      ...</sub_agents></list_sub_agent>
    Empty:
      <list_sub_agent><profile>P</profile><empty/></list_sub_agent>

  String fields may be empty; optional numeric tags may be ABSENT (means
  'inherits profile default') — absent tags render NO cells. api_key /
  base_url NEVER appear on the wire and are never parsed or rendered here
  (defense in depth: even an injected tag is ignored).

  Header (always visible, via ToolCardHeader):
    `list_sub_agent ✓` — primary "N subagents", right-meta "profile <name>"
    `list_sub_agent ✓ (empty)` — primary "No subagents", right-meta
      "profile <name>"

  Expanded body (click header to toggle): per-row name (bold) +
  model/url_style muted meta + tuning grid (only tags present in the
  envelope) + FULL system_prompt in a per-row <details> block
  (scrollable, NOT truncated).
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { tryUnwrapToolOutput } from '../../helpers/unwrapToolOutput'

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

/** One parsed <sub_agent> row. `has*` flags record tag PRESENCE so the
 *  tuning grid renders only tags present in the envelope (absent =
 *  'inherits profile default', no empty cells). api_key / base_url are
 *  deliberately absent — never parsed, never rendered. */
interface SubAgentRow {
  name: string
  model: string
  urlStyle: string
  thinking: string
  hasThinking: boolean
  temperature: string
  hasTemperature: boolean
  maxCapacityTokens: string | null
  compactionThresholdPercent: string | null
  thinkingBudgetTokens: string | null
  reasoningEffort: string | null
  systemPrompt: string
}

interface ParsedListSubAgent {
  /** True when no `<error>` tag is present. */
  success: boolean
  /** True when the backend returned `<empty/>` (or no rows parsed). */
  isEmpty: boolean
  /** Profile name, or 'unknown' when `<profile>` is absent. */
  profile: string
  rows: SubAgentRow[]
  error: string | null
}

const props = defineProps<{
  message: ToolMessageLike
}>()

const isExpanded = ref(false)

/**
 * Envelope `<parameters>` for this tool message.
 * `list_sub_agent` takes no input, so this is `{}` on the real wire and
 * <ToolParameters> renders nothing (its hasArgs guard skips '' / '{}').
 * Derived here — NOT threaded as a prop — because this component takes
 * `:message` (whole role=tool message), never `:content`/`:parameters`.
 */
const envelopeParams = computed(() => tryUnwrapToolOutput(props.message.content)?.parameters ?? '{}')

/**
 * Find the inner `<list_sub_agent>...</list_sub_agent>` envelope anywhere
 * inside `message.content`. The dispatcher passes the raw tool message,
 * whose content is the full `<tool>...</tool>` envelope; we strip the
 * wrapper here so the component is self-contained. Falls back to the raw
 * content for legacy callers that pass just the inner envelope directly.
 */
function findInnerEnvelope(content: string): string {
  const match = content.match(/<list_sub_agent>([\s\S]*?)<\/list_sub_agent>/)
  return match && match[1] !== undefined ? match[1] : content
}

/** Plain-text inner tag (no CDATA expected). Null when ABSENT. */
function tagText(block: string, tag: string): string | null {
  const match = block.match(new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`))
  return match && match[1] !== undefined ? match[1].trim() : null
}

/** system_prompt body: CDATA-wrapped full text, with a plain-text fallback. */
function promptText(block: string): string {
  const cdata = block.match(/<system_prompt>[\s\S]*?<!\[CDATA\[([\s\S]*?)\]\]>[\s\S]*?<\/system_prompt>/)
  if (cdata && cdata[1] !== undefined) return cdata[1]
  const plain = tagText(block, 'system_prompt')
  return plain ?? ''
}

function parseRow(block: string): SubAgentRow {
  const maxCap = tagText(block, 'max_capacity_tokens')
  const compactPct = tagText(block, 'compaction_threshold_percent')
  const budget = tagText(block, 'thinking_budget_tokens')
  const effort = tagText(block, 'reasoning_effort')
  const thinking = tagText(block, 'thinking')
  const temperature = tagText(block, 'temperature')
  return {
    name: tagText(block, 'name') ?? '',
    model: tagText(block, 'model') ?? '',
    urlStyle: tagText(block, 'url_style') ?? '',
    thinking: thinking ?? '',
    hasThinking: thinking !== null,
    temperature: temperature ?? '',
    hasTemperature: temperature !== null,
    maxCapacityTokens: maxCap,
    compactionThresholdPercent: compactPct,
    thinkingBudgetTokens: budget,
    reasoningEffort: effort,
    systemPrompt: promptText(block),
  }
}

const parsed = computed((): ParsedListSubAgent => {
  const inner = findInnerEnvelope(props.message.content)
  const errorMatch = inner.match(/<error>([\s\S]*?)<\/error>/)
  if (errorMatch && errorMatch[1]) {
    return {
      success: false,
      isEmpty: false,
      profile: tagText(inner, 'profile') ?? 'unknown',
      rows: [],
      error: errorMatch[1].trim(),
    }
  }
  const profile = tagText(inner, 'profile') ?? 'unknown'
  if (/<empty\s*\/?>/.test(inner)) {
    return { success: true, isEmpty: true, profile, rows: [], error: null }
  }
  const rows: SubAgentRow[] = []
  const rowRe = /<sub_agent>([\s\S]*?)<\/sub_agent>/g
  let m: RegExpExecArray | null
  while ((m = rowRe.exec(inner)) !== null) {
    if (m[1] !== undefined) rows.push(parseRow(m[1]))
  }
  if (rows.length === 0) {
    return { success: true, isEmpty: true, profile, rows: [], error: null }
  }
  return { success: true, isEmpty: false, profile, rows, error: null }
})

const primaryLabel = computed((): string => {
  if (!parsed.value.success) return 'error'
  if (parsed.value.isEmpty) return 'No subagents'
  const n = parsed.value.rows.length
  return `${n} ${n === 1 ? 'subagent' : 'subagents'}`
})

const rightMeta = computed((): string => {
  if (!parsed.value.success) return parsed.value.error ?? 'error'
  return `profile ${parsed.value.profile}`
})

const expandable = computed(() => true)

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-90': !parsed.success }"
    data-testid="list-sub-agent"
  >
    <ToolCardHeader
      tool-name="list_sub_agent"
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
      data-testid="list-sub-agent-body"
    >
      <!-- Error body — always visible when expanded AND error. -->
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
        data-testid="list-sub-agent-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <!-- Empty result (valid response, no subagents on this profile). -->
      <div
        v-else-if="parsed.isEmpty"
        class="px-3 py-3 text-center text-[var(--semantic-text-muted)] text-xs"
        data-testid="list-sub-agent-empty"
      >
        No subagents on profile {{ parsed.profile }}.
      </div>

      <!-- Populated rows. -->
      <div
        v-else
        class="px-3 py-2 space-y-2"
      >
        <div
          v-for="(row, idx) in parsed.rows"
          :key="idx"
          class="rounded border border-[var(--color-border)] px-2 py-1.5"
          :data-testid="`list-sub-agent-row-${idx}`"
        >
          <!-- Name (bold) + model/url_style muted meta. -->
          <div class="flex items-baseline gap-2 min-w-0">
            <span class="font-semibold text-[var(--semantic-text)] truncate">{{ row.name }}</span>
            <span class="text-[var(--semantic-text-muted)] truncate">{{ row.model }} · {{ row.urlStyle }}</span>
          </div>
          <!-- Tuning grid — ONLY tags present in the envelope. -->
          <div class="mt-1 grid grid-cols-2 gap-x-3 gap-y-0.5 text-[var(--semantic-text-muted)]">
            <span v-if="row.hasThinking">thinking: {{ row.thinking }}</span>
            <span v-if="row.hasTemperature">temperature: {{ row.temperature }}</span>
            <span v-if="row.maxCapacityTokens !== null" data-tuning="max_capacity_tokens">max_capacity_tokens: {{ row.maxCapacityTokens }}</span>
            <span v-if="row.compactionThresholdPercent !== null" data-tuning="compaction_threshold_percent">compaction_threshold_percent: {{ row.compactionThresholdPercent }}</span>
            <span v-if="row.thinkingBudgetTokens !== null" data-tuning="thinking_budget_tokens">thinking_budget_tokens: {{ row.thinkingBudgetTokens }}</span>
            <span v-if="row.reasoningEffort !== null" data-tuning="reasoning_effort">reasoning_effort: {{ row.reasoningEffort }}</span>
          </div>
          <!-- FULL system_prompt in an expandable collapsible block. -->
          <details
            class="mt-1"
            :data-testid="`list-sub-agent-prompt-${idx}`"
          >
            <summary class="cursor-pointer text-[var(--color-violet)]">system_prompt</summary>
            <pre
              class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words text-[var(--semantic-text)]"
              :data-testid="`list-sub-agent-prompt-body-${idx}`"
            >{{ row.systemPrompt }}</pre>
          </details>
        </div>
      </div>
      <!--
        Envelope params: collapsed <details>, rendered only
        when non-empty (ToolParameters v-ifs on hasArgs). Today this
        is always '{}' for list_sub_agent (no-input tool) so nothing shows.
      -->
      <ToolParameters :parameters="envelopeParams" />
    </div>
  </div>
</template>
