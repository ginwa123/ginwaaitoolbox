<script setup lang="ts">
import { computed, ref } from 'vue'
import { extractParam } from '../../helpers/extractParam'

/**
 * SearchHistory — renders the rich `<search_history>` envelope returned by the
 * `search_history` tool (see `search_history.zig`). The tool is the LLM's
 * primary window into the full conversation history on disk — both the
 * FTS5 search (mode="text") and the per-session browse (mode="session")
 * variants — so surfacing it as a structured card matters: a raw-XML
 * dump in the chat is unreadable, and (worse) the previous dispatch
 * fell through to the generic `tool-expandable` div which rendered it
 * inside a `diff search_history` block with empty BEFORE/AFTER columns.
 *
 * Two output shapes, both well-formed by construction:
 *
 *   mode="text" (FTS5 search results):
 *     <search_history mode="text" offset="N" limit="M">
 *       <query>...FTS5 query...</query>
 *       <count>K</count>
 *       <total_count>T</total_count>
 *       <results>
 *         <entry>
 *           <id>h_xxx</id>
 *           <session_id>s_xxx</session_id>
 *           <role>user|assistant|tool</role>
 *           <created_at>YYYY-MM-DD HH:MM:SS</created_at>
 *           <snippet>...with [match] markers around hits...</snippet>
 *         </entry>
 *         ...
 *       </results>
 *     </search_history>
 *
 *   mode="session" (per-session message index):
 *     <search_history mode="session" order="asc|desc">
 *       <session_id>s_xxx</session_id>
 *       <count>K</count>
 *       <total_count>T</total_count>
 *       <message_index>
 *         <entry>
 *           <id>h_xxx</id>
 *           <role>user|assistant|tool</role>
 *           <created_at>YYYY-MM-DD HH:MM:SS</created_at>
 *           <preview>...first 100 chars...</preview>
 *           <tool_call_id>...</tool_call_id>  <!-- only for tool role -->
 *           <tool_name>...</tool_name>         <!-- only for tool role -->
 *           <content truncated="0|1">...</content>  <!-- only for requested message_ids -->
 *         </entry>
 *         ...
 *       </message_index>
 *     </search_history>
 *
 *   Error:
 *     <search_history><error>...</error></search_history>
 *
 * Parsing uses regex (consistent with ReadCompactedMessages / Search.vue /
 * ListSkills.vue) — the backend emits well-formed XML and regex is plenty
 * for this fixed shape.
 */

// ── Shared types ──────────────────────────────────────────────────────────

interface TextEntry {
  id: string
  session_id: string
  role: string
  created_at?: string
  /** Raw snippet with `[match]` markers around hits — we render these
   *  as a highlighted span rather than raw text. */
  snippet: string
}

interface SessionEntry {
  id: string
  role: string
  created_at?: string
  preview: string
  tool_call_id?: string
  tool_name?: string
  /** Present only when the caller passed `message_ids` and the LLM wants
   *  the full body. `truncated` is true if the body was clipped to
   *  `MAX_FULL_CONTENT_BYTES` (16 KB) by the backend. */
  content?: string
  content_truncated?: boolean
}

const props = defineProps<{
  content: string
  expanded?: boolean
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// ── Parse outer envelope ─────────────────────────────────────────────────

const mode = computed((): 'text' | 'session' | 'error' | 'unknown' => {
  // Try attribute-form first (success: <search_history mode="...">).
  const attrMatch = props.content.match(/<search_history\s+mode="([^"]+)"/)
  if (attrMatch && attrMatch[1]) {
    return attrMatch[1] === 'session' ? 'session' : 'text'
  }
  // No mode attribute → root has no attrs → error envelope
  // (<search_history><error>...</error></search_history>).
  return 'unknown'
})

const queryText = computed((): string | null => {
  const match = props.content.match(/<query>([\s\S]*?)<\/query>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayMode = computed((): string | null => {
  if (mode.value !== 'unknown') return mode.value
  return extractParam(props.parameters, 'mode')
})
const displayQuery = computed((): string | null => queryText.value ?? extractParam(props.parameters, 'query'))
const isRunning = computed(() => props.content.trim() === '' && (displayMode.value !== null || displayQuery.value !== null))

const sessionId = computed((): string | null => {
  const match = props.content.match(/<session_id>([\s\S]*?)<\/session_id>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

/** Returned-page size (count of entries in *this* response). */
const count = computed((): number | null => {
  const match = props.content.match(/<count>(\d+)<\/count>/)
  if (!match || !match[1]) return null
  return parseInt(match[1], 10)
})

/** Total rows matching the WHERE clause (before LIMIT/OFFSET). Used by
 *  the LLM to know whether more pages exist. We surface this too so the
 *  user can see "showing 20 of 47" at a glance. */
const totalCount = computed((): number | null => {
  const match = props.content.match(/<total_count>(\d+)<\/total_count>/)
  if (!match || !match[1]) return null
  return parseInt(match[1], 10)
})

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const offset = computed((): number | null => {
  const match = props.content.match(/<search_history[^>]*\soffset="(\d+)"/)
  if (!match || !match[1]) return null
  return parseInt(match[1], 10)
})

const order = computed((): string | null => {
  const match = props.content.match(/<search_history[^>]*\sorder="([^"]+)"/)
  if (!match || !match[1]) return null
  return match[1]
})

const errorMessage = computed((): string | null => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// ── Parse entries ────────────────────────────────────────────────────────

const textEntries = computed((): TextEntry[] => {
  const results: TextEntry[] = []
  const entryRegex = /<entry>([\s\S]*?)<\/entry>/g
  let m
  while ((m = entryRegex.exec(props.content)) !== null) {
    const body = m[1]
    if (body === undefined) continue

    const idMatch = body.match(/<id>([\s\S]*?)<\/id>/)
    const sidMatch = body.match(/<session_id>([\s\S]*?)<\/session_id>/)
    const roleMatch = body.match(/<role>([\s\S]*?)<\/role>/)
    const createdAtMatch = body.match(/<created_at>([\s\S]*?)<\/created_at>/)
    const snippetMatch = body.match(/<snippet>([\s\S]*?)<\/snippet>/)

    results.push({
      id: (idMatch?.[1] ?? '').trim(),
      session_id: (sidMatch?.[1] ?? '').trim(),
      role: (roleMatch?.[1] ?? 'unknown').trim(),
      created_at: createdAtMatch?.[1]?.trim() || undefined,
      snippet: (snippetMatch?.[1] ?? '').trim(),
    })
  }
  return results
})

const sessionEntries = computed((): SessionEntry[] => {
  const results: SessionEntry[] = []
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

    // Content block has an optional `truncated="0|1"` attribute — match
    // it before the closing tag.
    const contentMatch = body.match(/<content(?:\s+truncated="([01])")?\s*>([\s\S]*?)<\/content>/)

    results.push({
      id: (idMatch?.[1] ?? '').trim(),
      role: (roleMatch?.[1] ?? 'unknown').trim(),
      created_at: createdAtMatch?.[1]?.trim() || undefined,
      preview: (previewMatch?.[1] ?? '').trim(),
      tool_call_id: toolCallIdMatch?.[1]?.trim() || undefined,
      tool_name: toolNameMatch?.[1]?.trim() || undefined,
      content: contentMatch?.[2]?.trim() || undefined,
      content_truncated: contentMatch?.[1] === '1',
    })
  }
  return results
})

// ── Header summary text ──────────────────────────────────────────────────

const summaryText = computed((): string => {
  if (errorMessage.value) return errorMessage.value

  const parts: string[] = []
  const effectiveMode = mode.value !== 'unknown' ? mode.value : displayMode.value
  const effectiveQuery = queryText.value ?? displayQuery.value
  if (mode.value === 'text') {
    parts.push('text search')
    if (queryText.value) parts.push(`"${truncateMiddle(queryText.value, 48)}"`)
  } else if (mode.value === 'session') {
    parts.push('session')
    if (sessionId.value) parts.push(truncateMiddle(sessionId.value, 32))
    if (order.value) parts.push(`order=${order.value}`)
  } else if (effectiveMode) {
    parts.push(effectiveMode === 'session' ? 'session' : 'text search')
    if (effectiveQuery) parts.push(`"${truncateMiddle(effectiveQuery, 48)}"`)
  } else {
    parts.push('search_history')
  }

  // Counters: "20 of 47" when paginated, just "47" when all fit.
  const c = count.value
  const t = totalCount.value
  if (c !== null && t !== null && t !== c) {
    parts.push(`${c} of ${t}`)
  } else if (c !== null) {
    parts.push(`${c} ${c === 1 ? 'entry' : 'entries'}`)
  }

  return parts.join(' · ')
})

const isError = computed(() => !!errorMessage.value)
const hasEntries = computed(() =>
  mode.value === 'text'
    ? textEntries.value.length > 0
    : sessionEntries.value.length > 0,
)

// ── Actions ──────────────────────────────────────────────────────────────

const toggle = () => {
  if (hasEntries.value || isError.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyId = async (e: Event, id: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(id)
}

// Per-session-entry "show full content" toggle. We only show the
// full <content> when the user explicitly expands it — keeps the
// bubble compact even when one entry happens to be huge.
const expandedContentIds = ref<Set<string>>(new Set())
const isContentExpanded = (id: string): boolean => expandedContentIds.value.has(id)
const toggleContent = (id: string): void => {
  const next = new Set(expandedContentIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedContentIds.value = next
}

// ── Helpers ──────────────────────────────────────────────────────────────

/** Truncate `s` to `max` chars, keeping both ends (more useful for
 *  long paths/queries than a pure tail ellipsis). */
function truncateMiddle(s: string, max: number): string {
  if (s.length <= max) return s
  const half = Math.max(2, Math.floor((max - 1) / 2))
  return `${s.slice(0, half)}…${s.slice(s.length - half)}`
}

/** Parse a snippet that uses `[match]…[/match]` markers into a list
 *  of (text, isMatch) segments for Vue rendering. We strip the
 *  closing tags by checking whether the next char is '['. */
function parseSnippet(snippet: string): { text: string; match: boolean }[] {
  const out: { text: string; match: boolean }[] = []
  let i = 0
  while (i < snippet.length) {
    if (snippet[i] === '[') {
      const end = snippet.indexOf(']', i + 1)
      if (end !== -1 && snippet[end + 1] === '[') {
        // `[…][…]` — two consecutive tags with no content between,
        // skip and let the next iter handle the opening bracket.
        // (Doesn't happen in practice; defensive.)
        i = end + 1
        continue
      }
      if (end !== -1 && snippet.slice(i + 1, end) === '/match') {
        // closing marker — end current matched segment
        i = end + 1
        continue
      }
      if (end !== -1 && snippet.slice(i + 1, end) === 'match') {
        // opening marker — start matched segment
        out.push({ text: '', match: true })
        i = end + 1
        continue
      }
    }
    // Find next '[' or end of string.
    const nextBracket = snippet.indexOf('[', i + 1)
    const chunk = nextBracket === -1 ? snippet.slice(i) : snippet.slice(i, nextBracket)
    if (chunk.length > 0) {
      const last = out[out.length - 1]
      if (last && last.match) {
        last.text += chunk
      } else {
        out.push({ text: chunk, match: false })
      }
    }
    i = nextBracket === -1 ? snippet.length : nextBracket
  }
  return out
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="isError ? 'border-red-500/50 opacity-90' : ''"
    data-testid="search-history"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">search_history</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-xs"
        :title="summaryText"
      >
        {{ summaryText }}
      </span>

      <!-- "showing N of M" badge when paginated -->
      <span
        v-if="count !== null && totalCount !== null && totalCount !== count"
        class="text-[0.65rem] font-medium px-1.5 py-0.5 rounded bg-violet-500/10 text-[var(--color-violet)] shrink-0"
        :title="`Page contains ${count} entries out of ${totalCount} total matches`"
        data-testid="search-history-page-badge"
      >
        {{ count }} of {{ totalCount }}
      </span>

      <span
        v-if="isError"
        class="text-red-500 text-[0.65rem] font-medium shrink-0"
      >
        Error
      </span>

      <span v-if="isRunning" data-testid="search-history-running" class="text-[0.65rem] text-yellow-500 animate-pulse shrink-0">running…</span>

      <span
        v-if="hasEntries || isError"
        class="w-4 text-center text-[var(--semantic-text-muted)] text-sm shrink-0"
      >
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Error body — always visible (not gated by isExpanded) so the
         user sees the failure without an extra click. -->
    <div
      v-if="isError"
      class="border-t border-[var(--color-border)] px-3 py-2 text-red-500 text-[0.72rem] break-words"
      data-testid="search-history-error"
    >
      {{ errorMessage }}
    </div>

    <!-- Empty-result hint — always visible when there's no error but also
         no entries. Saves the user a click to discover "no results". -->
    <div
      v-else-if="!hasEntries"
      class="border-t border-[var(--color-border)] px-3 py-4 text-center text-[var(--semantic-text-muted)] text-xs"
      data-testid="search-history-empty"
    >
      <template v-if="mode === 'text'">
        No matches for "{{ queryText }}"
      </template>
      <template v-else>
        No messages in {{ sessionId }}
      </template>
    </div>

    <!-- Entry list — only when expanded and there are entries. -->
    <div
      v-if="isExpanded && hasEntries && !isError"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <!-- mode="text": FTS5 results -->
      <ul
        v-if="mode === 'text'"
        class="divide-y divide-[var(--color-border)]"
        data-testid="search-history-text-entries"
      >
        <li
          v-for="(entry, idx) in textEntries"
          :key="entry.id || idx"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="search-history-text-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Role badge -->
            <span
              class="role-badge shrink-0"
              :class="`role-${entry.role}`"
              :data-testid="`text-entry-role-${idx}`"
            >
              {{ entry.role }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code
                class="entry-id"
                :title="entry.id"
                :data-testid="`text-entry-id-${idx}`"
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

            <!-- Session id (truncated) -->
            <span
              v-if="entry.session_id"
              class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0 max-w-[140px] truncate"
              :title="entry.session_id"
            >
              in {{ entry.session_id }}
            </span>

            <!-- Timestamp -->
            <span
              v-if="entry.created_at"
              class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0"
              :title="`Created at ${entry.created_at}`"
            >
              {{ entry.created_at }}
            </span>
          </div>

          <!-- Snippet with [match] markers highlighted -->
          <p
            v-if="entry.snippet"
            class="mt-1 ml-0 text-[0.72rem] text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :data-testid="`text-entry-snippet-${idx}`"
          >
            <template v-for="(seg, segIdx) in parseSnippet(entry.snippet)" :key="segIdx">
              <mark v-if="seg.match" class="bg-yellow-500/30 text-inherit rounded px-0.5">
                {{ seg.text }}
              </mark>
              <span v-else>{{ seg.text }}</span>
            </template>
          </p>
        </li>
      </ul>

      <!-- mode="session": message index -->
      <ul
        v-else
        class="divide-y divide-[var(--color-border)]"
        data-testid="search-history-session-entries"
      >
        <li
          v-for="(entry, idx) in sessionEntries"
          :key="entry.id || idx"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="search-history-session-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Role badge -->
            <span
              class="role-badge shrink-0"
              :class="`role-${entry.role}`"
              :data-testid="`session-entry-role-${idx}`"
            >
              {{ entry.role }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code
                class="entry-id"
                :title="entry.id"
                :data-testid="`session-entry-id-${idx}`"
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
              :data-testid="`session-entry-tool-call-id-${idx}`"
            >
              {{ entry.tool_call_id }}
            </span>
            <span
              v-if="entry.tool_name"
              class="tool-pill tool-name-pill"
              :title="`Tool: ${entry.tool_name}`"
              :data-testid="`session-entry-tool-name-${idx}`"
            >
              {{ entry.tool_name }}
            </span>
          </div>

          <!-- Preview (always present when not in error) -->
          <p
            v-if="entry.preview"
            class="mt-1 ml-0 text-[0.72rem] text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :data-testid="`session-entry-preview-${idx}`"
          >
            {{ entry.preview }}
          </p>

          <!-- Full content (only present when caller passed message_ids) -->
          <div v-if="entry.content" class="mt-1">
            <button
              class="content-toggle"
              type="button"
              :data-testid="`session-entry-toggle-content-${idx}`"
              @click="toggleContent(entry.id)"
            >
              <span class="content-toggle-icon">{{ isContentExpanded(entry.id) ? '▼' : '▶' }}</span>
              <span>
                {{ isContentExpanded(entry.id) ? 'Hide content' : 'Show content' }}
                <span
                  v-if="entry.content_truncated"
                  class="text-orange-500"
                  title="Backend truncated this content to fit context budget"
                >
                  (truncated)
                </span>
              </span>
            </button>
            <pre
              v-if="isContentExpanded(entry.id)"
              class="content-body"
              :data-testid="`session-entry-content-${idx}`"
            >{{ entry.content }}</pre>
          </div>
        </li>
      </ul>
    </div>
  </div>
</template>

<style scoped>
/* Mirrors the role-badge / pill styles in ReadCompactedMessages.vue.
   Kept local (scoped) so the styles don't leak; if a third component
   needs them, hoist to a shared `tool-card-styles.css` later. */
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