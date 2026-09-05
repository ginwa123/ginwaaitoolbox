<script setup lang="ts">
import { computed, ref } from 'vue'
import { extractParam } from '../../helpers/extractParam'

/**
 * ReadCompactedMessages — renders the rich `<read_compacted_messages>`
 * envelope returned by the `read_compacted_messages` tool. The tool is the
 * ONLY way an agent can recover messages dropped by long-context
 * compaction (see `read_compacted_messages.zig`), so surfacing it as a
 * structured card matters: a raw-XML dump in the chat is unreadable.
 *
 * Two output shapes, both well-formed by construction:
 *
 *   Success:
 *     <read_compacted_messages mode="index|full">
 *       <session_id>...</session_id>
 *       <count>N</count>
 *       <message_index>
 *         <entry>
 *           <id>h_xxx</id>
 *           <role>user|assistant|tool</role>
 *           <created_at>YYYY-MM-DD HH:MM:SS</created_at>
 *           <preview>... (always, ≤100 chars)</preview>
 *           <tool_call_id>...</tool_call_id>   <!-- only for tool role -->
 *           <tool_name>...</tool_name>         <!-- only for tool role -->
 *           <content>...</content>             <!-- only when mode=full AND id in message_ids -->
 *         </entry>
 *         ...
 *       </message_index>
 *     </read_compacted_messages>
 *
 *   Error:
 *     <read_compacted_messages><error>...</error></read_compacted_messages>
 *
 * Parsing uses regex (matches the pattern in ReadFile/ListSkills/Search)
 * because the backend emits well-formed XML and regex is plenty for this
 * fixed shape. DOMParser (used by CompactionCard) would also work but is
 * heavier than necessary here.
 */

interface MessageEntry {
  id: string
  role: string
  created_at?: string
  preview: string
  tool_call_id?: string
  tool_name?: string
  content?: string
}

const props = defineProps<{
  content: string
  expanded?: boolean
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// ── Parse the outer envelope ────────────────────────────────────────────────

const mode = computed((): 'index' | 'full' | 'unknown' => {
  const match = props.content.match(/<read_compacted_messages\s+mode="([^"]+)"/)
  if (!match || !match[1]) {
    // No mode attribute — could be error envelope (root has no attributes).
    return 'unknown'
  }
  return match[1] === 'full' ? 'full' : 'index'
})

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayMode = computed((): string | null => {
  if (mode.value !== 'unknown') return mode.value
  return extractParam(props.parameters, 'mode')
})
const isRunning = computed(() => props.content.trim() === '' && displayMode.value !== null)

const sessionId = computed((): string | null => {
  const match = props.content.match(/<session_id>([\s\S]*?)<\/session_id>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

const count = computed((): number | null => {
  const match = props.content.match(/<count>(\d+)<\/count>/)
  if (!match || !match[1]) return null
  return parseInt(match[1], 10)
})

const errorMessage = computed((): string | null => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// ── Parse the <message_index><entry> rows ───────────────────────────────────

const entries = computed((): MessageEntry[] => {
  const results: MessageEntry[] = []
  // `<entry>...</entry>` blocks are direct children of `<message_index>`.
  // Using `[\s\S]*?` (lazy) so we match each entry separately rather than
  // greedily absorbing everything between the first <entry> and the last
  // </entry>.
  const entryRegex = /<entry>([\s\S]*?)<\/entry>/g
  let m
  while ((m = entryRegex.exec(props.content)) !== null) {
    const body = m[1]
    if (body === undefined) continue

    const idMatch = body.match(/<id>([\s\S]*?)<\/id>/)
    const roleMatch = body.match(/<role>([\s\S]*?)<\/role>/)
    const createdAtMatch = body.match(/<created_at>([\s\S]*?)<\/created_at>/)
    const previewMatch = body.match(/<preview>([\s\S]*?)<\/preview>/)
    const toolCallIdMatch = body.match(/<tool_call_id>([\s\S]*?)<\/tool_call_id>/)
    const toolNameMatch = body.match(/<tool_name>([\s\S]*?)<\/tool_name>/)
    const contentMatch = body.match(/<content>([\s\S]*?)<\/content>/)

    results.push({
      id: (idMatch?.[1] ?? '').trim(),
      role: (roleMatch?.[1] ?? 'unknown').trim(),
      created_at: createdAtMatch?.[1]?.trim() || undefined,
      preview: (previewMatch?.[1] ?? '').trim(),
      tool_call_id: toolCallIdMatch?.[1]?.trim() || undefined,
      tool_name: toolNameMatch?.[1]?.trim() || undefined,
      content: contentMatch?.[1]?.trim() || undefined,
    })
  }
  return results
})

// ── Header summary text ─────────────────────────────────────────────────────

const summaryText = computed((): string => {
  if (errorMessage.value) return errorMessage.value

  const parts: string[] = []
  const effectiveMode = mode.value !== 'unknown' ? mode.value : displayMode.value
  parts.push(effectiveMode && effectiveMode !== 'unknown' ? `${effectiveMode} mode` : 'read')
  if (count.value !== null) {
    parts.push(`${count.value} ${count.value === 1 ? 'message' : 'messages'}`)
  }
  if (sessionId.value) {
    parts.push(sessionId.value)
  }
  return parts.join(' · ')
})

const isError = computed(() => !!errorMessage.value)
const hasEntries = computed(() => entries.value.length > 0)

// ── Actions ─────────────────────────────────────────────────────────────────

const toggle = () => {
  if (hasEntries.value || isError.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyId = async (e: Event, id: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(id)
}

// Per-entry "show full content" toggle (only meaningful in full mode).
const expandedContentIds = ref<Set<string>>(new Set())
const isContentExpanded = (id: string): boolean => expandedContentIds.value.has(id)
const toggleContent = (id: string): void => {
  // Reassign to trigger reactivity (Vue ref<Set> requires a new Set
  // instance for reactivity to detect the change).
  const next = new Set(expandedContentIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedContentIds.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="isError ? 'border-red-500/50 opacity-90' : ''"
    data-testid="read-compacted-messages"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">
        read_compacted_messages
      </span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-xs"
        :title="summaryText"
      >
        {{ summaryText }}
      </span>

      <span
        v-if="isError"
        class="text-red-500 text-[0.65rem] font-medium shrink-0"
      >
        Error
      </span>

      <span v-if="isRunning" data-testid="read-compacted-messages-running" class="text-[0.65rem] text-yellow-500 animate-pulse shrink-0">running…</span>

      <!-- Toggle indicator: hidden when there's nothing to expand -->
      <span
        v-if="hasEntries || isError"
        class="w-4 text-center text-[var(--semantic-text-muted)] text-sm shrink-0"
      >
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <!-- Error body -->
      <div
        v-if="isError"
        class="px-3 py-2 text-red-500 text-[0.72rem] break-words"
        data-testid="rcm-error"
      >
        {{ errorMessage }}
      </div>

      <!-- Empty result (valid response, 0 entries) -->
      <div
        v-else-if="!hasEntries"
        class="px-3 py-4 text-center text-[var(--semantic-text-muted)] text-xs"
        data-testid="rcm-empty"
      >
        No messages found
      </div>

      <!-- Entry list -->
      <ul
        v-else
        class="divide-y divide-[var(--color-border)]"
        data-testid="rcm-entries"
      >
        <li
          v-for="entry in entries"
          :key="entry.id || entry.preview"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="rcm-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Role badge -->
            <span
              class="role-badge shrink-0"
              :class="`role-${entry.role}`"
              data-testid="rcm-entry-role"
            >
              {{ entry.role }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code
                class="entry-id"
                :title="entry.id"
                data-testid="rcm-entry-id"
              >
                {{ entry.id }}
              </code>
              <button
                class="copy-btn"
                @click="(e) => copyId(e, entry.id)"
                title="Copy message id"
              >
                ⎘
              </button>
            </div>

            <!-- Timestamp -->
            <span
              v-if="entry.created_at"
              class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0"
              :title="`Created at ${entry.created_at}`"
            >
              {{ entry.created_at }}
            </span>

            <!-- Tool extras (only for tool role) -->
            <span
              v-if="entry.tool_call_id"
              class="tool-pill"
              :title="`Tool call id: ${entry.tool_call_id}`"
              data-testid="rcm-entry-tool-call-id"
            >
              {{ entry.tool_call_id }}
            </span>
            <span
              v-if="entry.tool_name"
              class="tool-pill tool-name-pill"
              :title="`Tool: ${entry.tool_name}`"
              data-testid="rcm-entry-tool-name"
            >
              {{ entry.tool_name }}
            </span>
          </div>

          <!-- Preview -->
          <p
            v-if="entry.preview"
            class="mt-1 ml-0 text-[0.72rem] text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :title="entry.preview"
          >
            {{ entry.preview }}
          </p>

          <!-- Full content (only present in mode='full') -->
          <div v-if="entry.content" class="mt-1">
            <button
              class="content-toggle"
              type="button"
              :data-testid="`rcm-toggle-content-${entry.id}`"
              @click="toggleContent(entry.id)"
            >
              <span class="content-toggle-icon">{{ isContentExpanded(entry.id) ? '▼' : '▶' }}</span>
              <span>{{ isContentExpanded(entry.id) ? 'Hide content' : 'Show content' }}</span>
            </button>
            <pre
              v-if="isContentExpanded(entry.id)"
              class="content-body"
              data-testid="rcm-entry-content"
            >{{ entry.content }}</pre>
          </div>
        </li>
      </ul>
    </div>
  </div>
</template>

<style scoped>
.role-badge {
  font-size: 9px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  padding: 2px 6px;
  border-radius: 4px;
  min-width: 64px;
  text-align: center;
}

.role-user {
  background-color: rgba(34, 197, 94, 0.15);
  color: rgb(34, 197, 94);
}

.role-assistant {
  background-color: rgba(99, 102, 241, 0.15);
  color: rgb(99, 102, 241);
}

.role-tool {
  background-color: rgba(234, 179, 8, 0.15);
  color: rgb(234, 179, 8);
}

.role-unknown {
  background-color: var(--semantic-card-bg);
  color: var(--semantic-text-muted);
}

.entry-id {
  font-family: monospace;
  font-size: 10px;
  color: var(--semantic-text-dim);
  max-width: 100px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.copy-btn {
  padding: 0 2px;
  border: none;
  background: transparent;
  cursor: pointer;
  color: var(--semantic-text-muted);
  opacity: 0;
  transition: opacity 0.15s;
}

.group:hover .copy-btn {
  opacity: 1;
}

.copy-btn:hover {
  color: var(--color-violet);
}

.tool-pill {
  font-family: monospace;
  font-size: 10px;
  background-color: var(--semantic-card-bg);
  padding: 1px 5px;
  border-radius: 3px;
  color: var(--semantic-text-dim);
  white-space: nowrap;
}

.tool-name-pill {
  background-color: rgba(99, 102, 241, 0.12);
  color: rgb(99, 102, 241);
}

.content-toggle {
  background: none;
  border: none;
  cursor: pointer;
  font: inherit;
  font-size: 10px;
  font-weight: 600;
  color: var(--semantic-text-muted);
  padding: 0;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  text-transform: uppercase;
  letter-spacing: 0.4px;
}

.content-toggle:hover {
  color: var(--color-violet);
}

.content-toggle-icon {
  font-size: 8px;
  width: 10px;
  text-align: center;
}

.content-body {
  margin: 6px 0 0 0;
  padding: 8px 10px;
  background-color: var(--semantic-card-bg);
  border-radius: 4px;
  border: 1px solid var(--color-border);
  font-family: monospace;
  font-size: 11px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
  max-height: 320px;
  overflow-y: auto;
}
</style>