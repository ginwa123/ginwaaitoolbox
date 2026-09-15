<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { extractParam } from '../../helpers/extractParam'

/**
 * ReadWorkspaceSession — renders the rich `<read_workspace_session>`
 * envelope returned by the `read_workspace_session` tool (see
 * `read_workspace_session.zig`). The tool is the LLM's window into
 * OTHER chat sessions in its own workspace — list, FTS search,
 * per-session read, and search-within — so surfacing it as a
 * structured card matters: a raw-XML dump in the chat is unreadable.
 *
 * Four output shapes, all well-formed by construction:
 *
 *   behavior="list" (workspace session discovery):
 *     <read_workspace_session behavior="list" limit="M">
 *       <count>K</count>
 *       <total_count>T</total_count>
 *       <sessions>
 *         <session>
 *           <id>s_xxx</id>
 *           <name>...</name>
 *           <status>active</status>
 *           <message_count>N</message_count>
 *           <last_activity>...</last_activity>
 *           <preview>...latest human message...</preview>
 *         </session>
 *         ...
 *       </sessions>
 *     </read_workspace_session>
 *
 *   behavior="search" | "search-within" (FTS results):
 *     <read_workspace_session behavior="search" offset="N" limit="M">
 *       <query>...FTS query...</query>
 *       [<session_id>s_xxx</session_id>]  <!-- search-within only -->
 *       <count>K</count>
 *       <total_count>T</total_count>
 *       <results>
 *         <entry>
 *           <id>h_xxx</id>
 *           <session_id>s_xxx</session_id>
 *           <session_name>...</session_name>
 *           <role>user|assistant|tool</role>
 *           <created_at>...</created_at>
 *           <snippet>...with [match] markers around hits...</snippet>
 *         </entry>
 *         ...
 *       </results>
 *     </read_workspace_session>
 *
 *   behavior="read" (per-session message index):
 *     <read_workspace_session behavior="read" order="asc|desc">
 *       <session_id>s_xxx</session_id>
 *       <count>K</count>
 *       <total_count>T</total_count>
 *       <message_index>
 *         <entry>
 *           <id>h_xxx</id>
 *           <role>user|assistant|tool</role>
 *           <created_at>...</created_at>
 *           <preview>...first 100 chars...</preview>
 *           <tool_call_id>...</tool_call_id>  <!-- only for tool role -->
 *           <tool_name>...</tool_name>         <!-- only for tool role -->
 *           <content truncated="0|1">...</content>  <!-- only for requested message_ids -->
 *         </entry>
 *         ...
 *       </message_index>
 *     </read_workspace_session>
 *
 *   Denied (cross-workspace target):
 *     <read_workspace_session><denied session_id="s_xxx">...</denied></read_workspace_session>
 *
 *   Error:
 *     <read_workspace_session><error>...</error></read_workspace_session>
 *
 * Parsing uses regex (consistent with Search.vue / ListSkills.vue) —
 * the backend emits well-formed XML and regex is plenty for this
 * fixed shape.
 */

// ── Shared types ──────────────────────────────────────────────────────────

interface WorkspaceSession {
  id: string
  name: string
  status: string
  message_count: number
  last_activity?: string
  preview: string
}

interface SearchEntry {
  id: string
  session_id: string
  session_name: string
  role: string
  created_at?: string
  /** Raw snippet with `[match]` markers around hits — we render these
   *  as a highlighted span rather than raw text. */
  snippet: string
}

interface ReadEntry {
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

type Behavior = 'list' | 'search' | 'search-within' | 'read' | 'denied' | 'error' | 'unknown'

const behavior = computed((): Behavior => {
  if (/<denied[\s>]/.test(props.content)) return 'denied'
  if (/<error>/.test(props.content)) return 'error'
  const attrMatch = props.content.match(/<read_workspace_session\s+behavior="([^"]+)"/)
  if (attrMatch && attrMatch[1]) {
    const b = attrMatch[1]
    if (b === 'list' || b === 'search' || b === 'search-within' || b === 'read') return b
  }
  return 'unknown'
})

const queryText = computed((): string | null => {
  const match = props.content.match(/<query>([\s\S]*?)<\/query>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayBehavior = computed((): string | null => {
  if (behavior.value !== 'unknown') return behavior.value
  if (extractParam(props.parameters, 'query')) return 'search'
  if (extractParam(props.parameters, 'session_id')) return 'read'
  return null
})
const displayQuery = computed(
  (): string | null => queryText.value ?? extractParam(props.parameters, 'query'),
)
const displaySessionId = computed(
  (): string | null => sessionId.value ?? extractParam(props.parameters, 'session_id'),
)
const isRunning = computed(() => props.content.trim() === '' && displayBehavior.value !== null)

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
  const match = props.content.match(/<read_workspace_session[^>]*\soffset="(\d+)"/)
  if (!match || !match[1]) return null
  return parseInt(match[1], 10)
})

const order = computed((): string | null => {
  const match = props.content.match(/<read_workspace_session[^>]*\sorder="([^"]+)"/)
  if (!match || !match[1]) return null
  return match[1]
})

const errorMessage = computed((): string | null => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

const deniedSessionId = computed((): string | null => {
  const attrMatch = props.content.match(/<denied[^>]*\ssession_id="([^"]+)"/)
  if (attrMatch && attrMatch[1]) return attrMatch[1]
  return null
})

const deniedMessage = computed((): string | null => {
  const match = props.content.match(/<denied[^>]*>([\s\S]*?)<\/denied>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// ── Parse entries ────────────────────────────────────────────────────────

const listSessions = computed((): WorkspaceSession[] => {
  const results: WorkspaceSession[] = []
  const entryRegex = /<session>([\s\S]*?)<\/session>/g
  let m
  while ((m = entryRegex.exec(props.content)) !== null) {
    const body = m[1]
    if (body === undefined) continue

    const idMatch = body.match(/<id>([\s\S]*?)<\/id>/)
    const nameMatch = body.match(/<name>([\s\S]*?)<\/name>/)
    const statusMatch = body.match(/<status>([\s\S]*?)<\/status>/)
    const countMatch = body.match(/<message_count>(\d+)<\/message_count>/)
    const activityMatch = body.match(/<last_activity>([\s\S]*?)<\/last_activity>/)
    const previewMatch = body.match(/<preview>([\s\S]*?)<\/preview>/)

    results.push({
      id: (idMatch?.[1] ?? '').trim(),
      name: (nameMatch?.[1] ?? '').trim(),
      status: (statusMatch?.[1] ?? '').trim(),
      message_count: countMatch?.[1] ? parseInt(countMatch[1], 10) : 0,
      last_activity: activityMatch?.[1]?.trim() || undefined,
      preview: (previewMatch?.[1] ?? '').trim(),
    })
  }
  return results
})

const searchEntries = computed((): SearchEntry[] => {
  const results: SearchEntry[] = []
  const entryRegex = /<entry>([\s\S]*?)<\/entry>/g
  let m
  while ((m = entryRegex.exec(props.content)) !== null) {
    const body = m[1]
    if (body === undefined) continue

    const idMatch = body.match(/<id>([\s\S]*?)<\/id>/)
    const sidMatch = body.match(/<session_id>([\s\S]*?)<\/session_id>/)
    const snameMatch = body.match(/<session_name>([\s\S]*?)<\/session_name>/)
    const roleMatch = body.match(/<role>([\s\S]*?)<\/role>/)
    const createdAtMatch = body.match(/<created_at>([\s\S]*?)<\/created_at>/)
    const snippetMatch = body.match(/<snippet>([\s\S]*?)<\/snippet>/)

    results.push({
      id: (idMatch?.[1] ?? '').trim(),
      session_id: (sidMatch?.[1] ?? '').trim(),
      session_name: (snameMatch?.[1] ?? '').trim(),
      role: (roleMatch?.[1] ?? 'unknown').trim(),
      created_at: createdAtMatch?.[1]?.trim() || undefined,
      snippet: (snippetMatch?.[1] ?? '').trim(),
    })
  }
  return results
})

const readEntries = computed((): ReadEntry[] => {
  const results: ReadEntry[] = []
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
  if (behavior.value === 'denied') {
    return deniedSessionId.value
      ? `denied · ${truncateMiddle(deniedSessionId.value, 32)} not in your workspace`
      : 'denied · session not in your workspace'
  }

  const parts: string[] = []
  const b = behavior.value !== 'unknown' ? behavior.value : displayBehavior.value
  if (b === 'list') {
    parts.push('workspace sessions')
  } else if (b === 'search' || b === 'search-within') {
    parts.push(b === 'search-within' ? 'search within session' : 'workspace search')
    const q = queryText.value ?? displayQuery.value
    if (q) parts.push(`"${truncateMiddle(q, 48)}"`)
    const sid = sessionId.value ?? displaySessionId.value
    if (b === 'search-within' && sid) parts.push(truncateMiddle(sid, 32))
  } else if (b === 'read') {
    parts.push('session')
    const sid = sessionId.value ?? displaySessionId.value
    if (sid) parts.push(truncateMiddle(sid, 32))
    if (order.value) parts.push(`order=${order.value}`)
  } else {
    parts.push('read_workspace_session')
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
const isDenied = computed(() => behavior.value === 'denied')
const hasEntries = computed(() => {
  if (behavior.value === 'list') return listSessions.value.length > 0
  if (behavior.value === 'search' || behavior.value === 'search-within')
    return searchEntries.value.length > 0
  return readEntries.value.length > 0
})
const hasArgs = computed(() => {
  const v = (props.parameters ?? '').trim()
  return v !== '' && v !== '{}'
})

// ── Actions ──────────────────────────────────────────────────────────────

const toggle = () => {
  if (hasEntries.value || isError.value || isDenied.value || hasArgs.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyId = async (e: Event, id: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(id)
}

// Per-read-entry "show full content" toggle. We only show the
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
    data-testid="read-workspace-session"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">read_workspace_session</span>
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
        data-testid="read-workspace-session-page-badge"
      >
        {{ count }} of {{ totalCount }}
      </span>

      <span v-if="isError" class="text-red-500 text-[0.65rem] font-medium shrink-0"> Error </span>

      <span v-if="isDenied" class="text-yellow-500 text-[0.65rem] font-medium shrink-0">
        Denied
      </span>

      <span
        v-if="isRunning"
        data-testid="read-workspace-session-running"
        class="text-[0.65rem] text-yellow-500 animate-pulse shrink-0"
        >running…</span
      >

      <span
        v-if="hasEntries || isError || isDenied || hasArgs"
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
      data-testid="read-workspace-session-error"
    >
      {{ errorMessage }}
    </div>

    <!-- Denied body — always visible. The target session is outside the
         caller's workspace; no content is ever rendered here. -->
    <div
      v-else-if="isDenied"
      class="border-t border-[var(--color-border)] px-3 py-2 text-yellow-500 text-[0.72rem] break-words"
      data-testid="read-workspace-session-denied"
    >
      {{ deniedMessage ?? 'Session is not in your workspace.' }}
      <span v-if="deniedSessionId" class="text-[var(--semantic-text-muted)]"
        >({{ deniedSessionId }})</span
      >
    </div>

    <!-- Empty-result hint — always visible when there's no error but also
         no entries. Saves the user a click to discover "no results". -->
    <div
      v-else-if="!hasEntries"
      class="border-t border-[var(--color-border)] px-3 py-4 text-center text-[var(--semantic-text-muted)] text-xs"
      data-testid="read-workspace-session-empty"
    >
      <template v-if="behavior === 'list'"> No other sessions in your workspace </template>
      <template v-else-if="behavior === 'search' || behavior === 'search-within'">
        No matches for "{{ queryText }}"
      </template>
      <template v-else> No messages in {{ sessionId }} </template>
    </div>

    <!-- Entry list — only when expanded and there are entries. -->
    <div
      v-if="isExpanded && hasEntries && !isError && !isDenied"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <!-- behavior="list": workspace sessions -->
      <ul
        v-if="behavior === 'list'"
        class="divide-y divide-[var(--color-border)]"
        data-testid="read-workspace-session-list-entries"
      >
        <li
          v-for="(session, idx) in listSessions"
          :key="session.id || idx"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="read-workspace-session-list-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Session name -->
            <span
              class="font-semibold text-[var(--semantic-text)] text-xs truncate max-w-[200px]"
              :title="session.name || session.id"
              :data-testid="`list-entry-name-${idx}`"
            >
              {{ session.name || session.id }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code class="entry-id" :title="session.id" :data-testid="`list-entry-id-${idx}`">
                {{ session.id }}
              </code>
              <button
                class="copy-btn"
                @click="(e) => copyId(e, session.id)"
                title="Copy session id"
              >
                ⎘
              </button>
            </div>

            <!-- Status -->
            <span
              v-if="session.status"
              class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0"
            >
              {{ session.status }}
            </span>

            <!-- Message count -->
            <span
              class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0"
              :title="`${session.message_count} messages`"
            >
              {{ session.message_count }} msgs
            </span>

            <!-- Last activity -->
            <span
              v-if="session.last_activity"
              class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0"
              :title="`Last activity ${session.last_activity}`"
            >
              {{ session.last_activity }}
            </span>
          </div>

          <!-- Preview -->
          <p
            v-if="session.preview"
            class="mt-1 ml-0 text-[0.72rem] text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :data-testid="`list-entry-preview-${idx}`"
          >
            {{ session.preview }}
          </p>
        </li>
      </ul>

      <!-- behavior="search" | "search-within": FTS results -->
      <ul
        v-else-if="behavior === 'search' || behavior === 'search-within'"
        class="divide-y divide-[var(--color-border)]"
        data-testid="read-workspace-session-search-entries"
      >
        <li
          v-for="(entry, idx) in searchEntries"
          :key="entry.id || idx"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="read-workspace-session-search-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Role badge -->
            <span
              class="role-badge shrink-0"
              :class="`role-${entry.role}`"
              :data-testid="`search-entry-role-${idx}`"
            >
              {{ entry.role }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code class="entry-id" :title="entry.id" :data-testid="`search-entry-id-${idx}`">
                {{ entry.id }}
              </code>
              <button class="copy-btn" @click="(e) => copyId(e, entry.id)" title="Copy message id">
                ⎘
              </button>
            </div>

            <!-- Session name + id (truncated) -->
            <span
              v-if="entry.session_name || entry.session_id"
              class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0 max-w-[140px] truncate"
              :title="entry.session_id"
            >
              in {{ entry.session_name || entry.session_id }}
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
            :data-testid="`search-entry-snippet-${idx}`"
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

      <!-- behavior="read": message index -->
      <ul
        v-else
        class="divide-y divide-[var(--color-border)]"
        data-testid="read-workspace-session-read-entries"
      >
        <li
          v-for="(entry, idx) in readEntries"
          :key="entry.id || idx"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="read-workspace-session-read-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Role badge -->
            <span
              class="role-badge shrink-0"
              :class="`role-${entry.role}`"
              :data-testid="`read-entry-role-${idx}`"
            >
              {{ entry.role }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code class="entry-id" :title="entry.id" :data-testid="`read-entry-id-${idx}`">
                {{ entry.id }}
              </code>
              <button class="copy-btn" @click="(e) => copyId(e, entry.id)" title="Copy message id">
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
              :data-testid="`read-entry-tool-call-id-${idx}`"
            >
              {{ entry.tool_call_id }}
            </span>
            <span
              v-if="entry.tool_name"
              class="tool-pill tool-name-pill"
              :title="`Tool: ${entry.tool_name}`"
              :data-testid="`read-entry-tool-name-${idx}`"
            >
              {{ entry.tool_name }}
            </span>
          </div>

          <!-- Preview (always present when not in error) -->
          <p
            v-if="entry.preview"
            class="mt-1 ml-0 text-[0.72rem] text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :data-testid="`read-entry-preview-${idx}`"
          >
            {{ entry.preview }}
          </p>

          <!-- Full content (only present when caller passed message_ids) -->
          <div v-if="entry.content" class="mt-1">
            <button
              class="content-toggle"
              type="button"
              :data-testid="`read-entry-toggle-content-${idx}`"
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
              :data-testid="`read-entry-content-${idx}`"
              >{{ entry.content }}</pre>
          </div>
        </li>
      </ul>
      <ToolParameters :parameters="parameters" />
    </div>
    <div v-if="isExpanded && !hasEntries && !isError && !isDenied">
      <ToolParameters :parameters="parameters" />
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
