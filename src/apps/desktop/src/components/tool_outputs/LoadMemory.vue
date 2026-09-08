<!--
  LoadMemory — tool output component for the `load_memory` agent tool.

  Renders the XML envelope produced by `executeLoadMemory` in
  `src/modules/agent/tools/load_memory.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Three response shapes are possible (inner data extracted by
  `ChatView.innerToolData`, so this component receives the inner
  `<load_memory ...>...</load_memory>` body):
    Success with N hits:
      <load_memory query="..." limit="10" offset="0" with_content="0">
        <count>3</count>
        <total_count>7</total_count>
        <results>
          <memory>
            <id>mem_aabbcc...</id>
            <tags>preferences||user</tags>
            <created_at>YYYY-MM-DD HH:MM:SS</created_at>
            <updated_at>YYYY-MM-DD HH:MM:SS</updated_at>
            <snippet>...[match]dark[/match] mode preferred...</snippet>
            <content truncated="0">...</content>          (only when with_content="1")
          </memory>
          ...
        </results>
      </load_memory>
    No hits:
      <load_memory query="..." limit="10" offset="0" with_content="0">
        <count>0</count>
        <total_count>0</total_count>
        <results/>
      </load_memory>
    Error:
      <load_memory><error>...</error></load_memory>

  Header (always visible):
    `load_memory → "<query>" · N of M hits ✓`  (success)
    `load_memory → error ✗`                    (failure)

  Expanded body (click header to toggle):
    Success: per-memory entry — id (with copy), tags chips, timestamps,
    snippet with [match] markers highlighted yellow. Optional `<content>`
    block (only when caller used with_content=true) renders below snippet,
    with a "(truncated)" badge when the backend cut it at the 2 KiB cap.
    No hits: muted "No memories match ..." hint.
    Error:   red error block.

  Style is consistent with the rest of the tool_outputs components
  (SearchHistory is the closest analog — both have FTS5 snippets).
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'

interface MemoryEntry {
  id: string
  tags: string[]
  created_at: string | null
  updated_at: string | null
  snippet: string
  content: string | null
  content_truncated: boolean
}

const props = defineProps<{
  content: string
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Accepted so the
   *  dispatcher can thread call args uniformly; the load result carries
   *  no "unknown" fallback that needs it today. */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// Running: result envelope is still empty (no entries/error yet).
const isRunning = computed(() => props.content.trim() === '')

// ── Parse outer envelope ──────────────────────────────────────────────────

const errorMessage = computed(() => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

const queryText = computed(() => {
  const match = props.content.match(/<load_memory[^>]*\squery="([^"]+)"/)
  if (!match || !match[1]) return null
  return match[1]
})

const withContent = computed(() => {
  return /<load_memory[^>]*\swith_content="1"/.test(props.content)
})

/** Returned-page size (count of entries in *this* response). */
const count = computed((): number | null => {
  const match = props.content.match(/<count>(\d+)<\/count>/)
  if (!match || !match[1]) return null
  return parseInt(match[1], 10)
})

/** Total rows matching the FTS5 query (before LIMIT/OFFSET). The LLM
 *  uses this to know whether more pages exist via offset. */
const totalCount = computed((): number | null => {
  const match = props.content.match(/<total_count>(\d+)<\/total_count>/)
  if (!match || !match[1]) return null
  return parseInt(match[1], 10)
})

// ── Parse entries ─────────────────────────────────────────────────────────

const entries = computed((): MemoryEntry[] => {
  const results: MemoryEntry[] = []
  const entryRegex = /<memory>([\s\S]*?)<\/memory>/g
  let m
  while ((m = entryRegex.exec(props.content)) !== null) {
    const body = m[1]
    if (body === undefined) continue

    const idMatch = body.match(/<id>([\s\S]*?)<\/id>/)
    const tagsMatch = body.match(/<tags>([\s\S]*?)<\/tags>/)
    const createdAtMatch = body.match(/<created_at>([\s\S]*?)<\/created_at>/)
    const updatedAtMatch = body.match(/<updated_at>([\s\S]*?)<\/updated_at>/)
    const snippetMatch = body.match(/<snippet>([\s\S]*?)<\/snippet>/)

    // Content block has an optional `truncated="0|1"` attribute.
    const contentMatch = body.match(/<content(?:\s+truncated="([01])")?\s*>([\s\S]*?)<\/content>/)

    const tagsRaw = (tagsMatch?.[1] ?? '').trim()
    const tags: string[] = tagsRaw.length > 0
      ? tagsRaw.split('||').filter((t) => t.length > 0)
      : []

    results.push({
      id: (idMatch?.[1] ?? '').trim(),
      tags,
      created_at: createdAtMatch?.[1]?.trim() || null,
      updated_at: updatedAtMatch?.[1]?.trim() || null,
      snippet: (snippetMatch?.[1] ?? '').trim(),
      content: contentMatch?.[2]?.trim() ?? null,
      content_truncated: contentMatch?.[1] === '1',
    })
  }
  return results
})

// ── Header summary text ──────────────────────────────────────────────────

const summaryText = computed((): string => {
  if (errorMessage.value) return errorMessage.value

  const parts: string[] = []
  if (queryText.value) parts.push(`"${truncateMiddle(queryText.value, 48)}"`)

  // Counters: "3 of 7" when paginated, just "7" when all fit, "0 hits"
  // when empty.
  const c = count.value
  const t = totalCount.value
  if (c === 0 && (t === 0 || t === null)) {
    parts.push('no hits')
  } else if (c !== null && t !== null && t !== c) {
    parts.push(`${c} of ${t} hits`)
  } else if (c !== null) {
    parts.push(`${c} ${c === 1 ? 'hit' : 'hits'}`)
  }
  if (withContent.value) parts.push('with content')

  return parts.join(' · ')
})

const isError = computed(() => !!errorMessage.value)
const hasEntries = computed(() => entries.value.length > 0)
const hasArgs = computed(() => {
  const v = (props.parameters ?? '').trim()
  return v !== '' && v !== '{}'
})
const isPaginated = computed(() => {
  const c = count.value
  const t = totalCount.value
  return c !== null && t !== null && t !== c
})

// ── Actions ───────────────────────────────────────────────────────────────

const toggle = () => {
  if (hasEntries.value || isError.value || hasArgs.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyId = async (e: Event, id: string) => {
  e.stopPropagation()
  if (id) {
    await navigator.clipboard.writeText(id)
  }
}

// Per-entry "show full content" toggle. Mirrors SearchHistory's
// pattern — we only render <content> when the user explicitly expands
// it, keeping the bubble compact even when one entry is huge.
const expandedContentIds = ref<Set<string>>(new Set())
const isContentExpanded = (id: string): boolean => expandedContentIds.value.has(id)
const toggleContent = (id: string): void => {
  const next = new Set(expandedContentIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedContentIds.value = next
}

// ── Helpers ───────────────────────────────────────────────────────────────

/** Truncate `s` to `max` chars, keeping both ends (more useful for
 *  long queries than a pure tail ellipsis). */
function truncateMiddle(s: string, max: number): string {
  if (s.length <= max) return s
  const half = Math.max(2, Math.floor((max - 1) / 2))
  return `${s.slice(0, half)}…${s.slice(s.length - half)}`
}

/** Parse a snippet that uses `[match]…[/match]` markers into a list
 *  of (text, isMatch) segments for Vue rendering. Same algorithm as
 *  SearchHistory.vue — backend emits the same marker format. */
function parseSnippet(snippet: string): { text: string; match: boolean }[] {
  const out: { text: string; match: boolean }[] = []
  let i = 0
  while (i < snippet.length) {
    if (snippet[i] === '[') {
      const end = snippet.indexOf(']', i + 1)
      if (end !== -1 && snippet[end + 1] === '[') {
        i = end + 1
        continue
      }
      if (end !== -1 && snippet.slice(i + 1, end) === '/match') {
        i = end + 1
        continue
      }
      if (end !== -1 && snippet.slice(i + 1, end) === 'match') {
        out.push({ text: '', match: true })
        i = end + 1
        continue
      }
    }
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
    :class="{ 'border-red-500/50 opacity-90': isError }"
    data-testid="load-memory"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">load_memory</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-xs"
        :title="summaryText"
      >
        {{ summaryText }}
      </span>

      <!-- "showing N of M" badge when paginated -->
      <span
        v-if="isPaginated"
        class="text-[0.65rem] font-medium px-1.5 py-0.5 rounded bg-violet-500/10 text-[var(--color-violet)] shrink-0"
        :title="`Page contains ${count} hits out of ${totalCount} total matches`"
        data-testid="load-memory-page-badge"
      >
        {{ count }} of {{ totalCount }}
      </span>

      <!-- "with content" pill when with_content=true was passed -->
      <span
        v-if="withContent && hasEntries"
        class="text-[0.65rem] font-medium px-1.5 py-0.5 rounded bg-violet-500/10 text-[var(--color-violet)] shrink-0"
        title="Caller passed with_content=true — full bodies are available below"
        data-testid="load-memory-with-content-badge"
      >
        with content
      </span>

      <span
        v-if="isError"
        class="text-red-500 text-[0.65rem] font-medium shrink-0"
      >
        Error
      </span>

      <!-- Live badge (tool call underway, envelope still empty) -->
      <span
        v-if="isRunning"
        data-testid="load-memory-running"
        class="text-[0.65rem] text-yellow-500 animate-pulse shrink-0"
      >
        running…
      </span>

      <span
        v-if="hasEntries || isError || hasArgs"
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
      data-testid="load-memory-error"
    >
      {{ errorMessage }}
    </div>

    <!-- Empty-result hint — always visible when there's no error but
         also no entries. Suppressed while running (an empty envelope is
         "not started", not "no results"). Saves the user a click to
         discover "no results". -->
    <div
      v-else-if="!hasEntries && !isRunning"
      class="border-t border-[var(--color-border)] px-3 py-4 text-center text-[var(--semantic-text-muted)] text-xs"
      data-testid="load-memory-empty"
    >
      No memories match "{{ queryText }}"
    </div>

    <!-- Entry list — only when expanded and there are entries. -->
    <div
      v-if="isExpanded && hasEntries && !isError"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
      data-testid="load-memory-entries"
    >
      <div
        v-for="(entry, idx) in entries"
        :key="entry.id || idx"
        class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5 border-b border-dashed border-[var(--color-border)] last:border-b-0"
        data-testid="load-memory-entry"
      >
        <!-- Top row: id + copy + tags chips + timestamps -->
        <div class="flex items-start gap-2 min-w-0 flex-wrap">
          <!-- ID + copy -->
          <div class="flex items-center gap-1 min-w-0 shrink-0">
            <code
              class="entry-id"
              :title="entry.id"
              :data-testid="`load-memory-entry-id-${idx}`"
            >
              {{ entry.id }}
            </code>
            <button
              class="copy-btn"
              @click="(e) => copyId(e, entry.id)"
              title="Copy memory id"
              :data-testid="`load-memory-entry-copy-${idx}`"
            >
              ⎘
            </button>
          </div>

          <!-- Tags chips -->
          <span
            v-for="(tag, tagIdx) in entry.tags"
            :key="`${entry.id}-tag-${tagIdx}`"
            class="tag-chip"
            :title="`tag: ${tag}`"
            :data-testid="`load-memory-entry-tag-${idx}-${tagIdx}`"
          >
            {{ tag }}
          </span>

          <!-- Created / Updated timestamps -->
          <span
            v-if="entry.created_at"
            class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0"
            :title="`Created at ${entry.created_at}`"
            :data-testid="`load-memory-entry-created-at-${idx}`"
          >
            created {{ entry.created_at }}
          </span>
          <span
            v-if="entry.updated_at"
            class="text-[var(--semantic-text-dim)] text-[0.65rem] shrink-0"
            :title="`Updated at ${entry.updated_at}`"
            :data-testid="`load-memory-entry-updated-at-${idx}`"
          >
            updated {{ entry.updated_at }}
          </span>
        </div>

        <!-- Snippet with [match] markers highlighted -->
        <p
          v-if="entry.snippet"
          class="mt-1 text-[0.72rem] text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
          :data-testid="`load-memory-entry-snippet-${idx}`"
        >
          <template v-for="(seg, segIdx) in parseSnippet(entry.snippet)" :key="segIdx">
            <mark v-if="seg.match" class="bg-yellow-500/30 text-inherit rounded px-0.5">
              {{ seg.text }}
            </mark>
            <span v-else>{{ seg.text }}</span>
          </template>
        </p>

        <!-- Optional full content (only when caller passed with_content=true) -->
        <div v-if="entry.content" class="mt-1">
          <button
            class="content-toggle"
            type="button"
            :data-testid="`load-memory-entry-toggle-content-${idx}`"
            @click="toggleContent(entry.id)"
          >
            <span class="content-toggle-icon">{{ isContentExpanded(entry.id) ? '▼' : '▶' }}</span>
            <span>
              {{ isContentExpanded(entry.id) ? 'Hide content' : 'Show content' }}
              <span
                v-if="entry.content_truncated"
                class="text-orange-500"
                title="Backend truncated this content to fit the 2 KiB context budget"
              >
                (truncated)
              </span>
            </span>
          </button>
          <pre
            v-if="isContentExpanded(entry.id)"
            class="content-body"
            :data-testid="`load-memory-entry-content-${idx}`"
          >{{ entry.content }}</pre>
        </div>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
    <div v-if="isExpanded && !hasEntries && !isError">
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>

<style scoped>
/* Mirrors the styling in SearchHistory.vue (same FTS5 snippet shape).
   Kept local (scoped) so styles don't leak. */
.entry-id {
  font-family: monospace;
  font-size: 10px;
  color: var(--semantic-text-dim);
  max-width: 140px;
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

.tag-chip {
  font-family: monospace;
  font-size: 10px;
  background-color: rgba(99, 102, 241, 0.12);
  color: rgb(99, 102, 241);
  padding: 1px 5px;
  border-radius: 3px;
  white-space: nowrap;
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
