<!--
  SaveMemory — tool output component for the `save_memory` agent tool.

  Renders the envelope produced by `executeSaveMemory` in
  `src/modules/agent/tools/memory.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Two response shapes are possible (inner data extracted by
  `ChatView.innerToolData`, so this component receives the `data`
  payload of the `save_memory` result):
    Success (append-only INSERT):
      { "id": "mem_aabbcc...", "created_at": "...", "updated_at": "..." }
    Empty/missing fields (stale DB row or partial envelope):
      { "id": "..." } — still a success; missing timestamp fields render
      as absent rows.
    Error:
      { "error": "..." }

  **The body comes from the tool-call arguments, not from `data`.**
  `executeSaveMemory` deliberately does NOT echo the stored body back —
  a memory is 1 KiB–1 MiB, so a result echo would burn the LLM's context
  on a value the model itself just authored. The card therefore reads
  `content` / `tags` from the `parameters` prop (the persisted tool-call
  envelope), falling back to `data.content` / `data.tags` in case a future
  backend does echo them. This mirrors `WriteFile.vue`, which renders the
  written file body from `parameters` and hides it from the Arguments
  block via `:exclude`.

  Header (always visible):
    `save_memory → <id> · <content preview> ✓`   (success)
    `save_memory → error ✗`                      (failure)
  Hover shows the full body (capped) so the note can be read without
  expanding.

  Expanded body (click header to toggle):
    Success: id (copy) · tags chips · created_at · updated_at · the
             stored body in a scrollable `pre` with a size badge and a
             copy button.
    Error:   red error block with the full error message.

  Bodies above `MAX_DISPLAY_CHARS` are clipped for display with an
  explicit "N more characters not shown" note; the copy button always
  copies the FULL body.

  Style is consistent with the rest of the tool_outputs components
  (LoadMemory, KanbanMove, ReadWorkspaceSession): monospace, rounded-md,
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
   *  so a still-running tool (empty content) shows its target id, and as
   *  the primary source of the saved body (the result does not echo it). */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

/** Body longer than this is clipped in the card. A memory can be up to
 *  1 MiB; a chat card has no business rendering all of it. The copy
 *  button still yields the full body. */
const MAX_DISPLAY_CHARS = 20000

/** How much of the body the header's hover tooltip reveals. */
const MAX_TOOLTIP_CHARS = 500

// The body is rendered above as readable text — hide it from the Arguments
// block so the expanded card doesn't repeat a 1 KiB–1 MiB blob as escaped
// JSON (same trick `WriteFile.vue` uses for a written file).
const ARGS_EXCLUDE = ['content']

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

/** Tool-call args as an object, or null when the payload is XML/raw. */
const paramsObj = computed((): Record<string, unknown> | null => {
  const raw = (props.parameters ?? '').trim()
  if (!raw) return null
  try {
    const obj: unknown = JSON.parse(raw)
    if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) return null
    return obj as Record<string, unknown>
  } catch {
    return null
  }
})

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

// ---- The saved body + tags -------------------------------------------------
//
// Precedence: result `data` first (a future backend may echo the stored
// row), then the tool-call args. `content` is the memory body; it can be
// an empty string only for a rejected call, which never reaches success.

const savedContent = computed((): string | null => {
  const fromData = strOrNull(dataRecord.value.content)
  if (fromData !== null) return fromData
  const obj = paramsObj.value
  if (obj) {
    const v = obj['content']
    if (typeof v === 'string') return v
    if (v != null) return String(v)
    return null
  }
  return extractParam(props.parameters, 'content')
})

/** Tags as individual chips. `splitTagsString` in
 *  `src/modules/agent/tools/memory.zig` accepts `||`, `|`, `,` and
 *  space; mirror that order so the chips match what was stored. */
const savedTags = computed((): string[] => {
  let raw: string | null = null
  const fromData = dataRecord.value.tags
  if (typeof fromData === 'string') raw = fromData
  else if (Array.isArray(fromData)) raw = fromData.join('||')
  if (raw === null || raw.trim() === '') {
    raw = extractParam(props.parameters, 'tags')
  }
  if (raw === null || raw.trim() === '') return []
  return raw
    .split(/\|+|,|\s+/)
    .map((t) => t.trim())
    .filter((t) => t.length > 0)
})

// ---- Derived display values ------------------------------------------------

const isSuccess = computed(() => errorMessage.value === null)

const statusIndicator = computed(() => (isRunning.value ? '…' : isSuccess.value ? '✓' : '✗'))

/** One-line form of the body for the header: newlines collapsed so a
 *  multi-line note still renders on the single-line header row. */
const contentOneLine = computed(() => (savedContent.value ?? '').replace(/\s+/g, ' ').trim())

/** Header label: "<id> · <preview>" on success, "error" on failure. The
 *  id stays first — it is the row's identity — and the preview answers
 *  "what did it actually save?" without an extra click. */
const headerLabel = computed(() => {
  if (!isSuccess.value) return 'error'
  const id = memoryId.value ?? 'unknown'
  const preview = contentOneLine.value
  if (preview === '') return id
  return `${id} · ${truncateMiddle(preview, 48)}`
})

/** Hover title: the full id (no truncation) plus the body capped at
 *  MAX_TOOLTIP_CHARS, so power users can hover-read the note without
 *  expanding. On error, the full error text. */
const headerTitle = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? ''
  const parts: string[] = []
  if (memoryId.value) parts.push(memoryId.value)
  if (contentOneLine.value) parts.push(clip(contentOneLine.value, MAX_TOOLTIP_CHARS))
  return parts.join('\n')
})

// ---- Body rendering --------------------------------------------------------

/** What the card actually renders — clipped for display only. */
const displayContent = computed(() => clip(savedContent.value ?? '', MAX_DISPLAY_CHARS))

/** Characters dropped by the display clip (0 when the body fits). */
const hiddenChars = computed(() => (savedContent.value ?? '').length - displayContent.value.length)

const contentLineCount = computed(() => {
  const c = savedContent.value
  if (c === null || c === '') return 0
  return c.split('\n').length
})

/** "1.4 KB · 18 lines" — size + shape of the stored body. */
const contentSizeLabel = computed(() => {
  const c = savedContent.value
  if (c === null) return ''
  const lines = contentLineCount.value
  return `${formatBytes(utf8Len(c))} · ${lines} ${lines === 1 ? 'line' : 'lines'}`
})

const hasBody = computed(() => {
  const c = savedContent.value
  return c !== null && c !== ''
})

// ---- Actions ---------------------------------------------------------------

const toggle = () => {
  // Always expandable on success (3 timestamp rows + the body) or error
  // (1 row). On empty/missing envelopes (no id + no error) we still allow
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

// Copies the FULL body, not the display-clipped excerpt.
const copyContent = async () => {
  const c = savedContent.value
  if (c !== null) {
    await navigator.clipboard.writeText(c)
  }
}

// ---- Helpers ---------------------------------------------------------------

function clip(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) : s
}

/** UTF-8 byte length without allocating a copy of the (up to 1 MiB)
 *  body — `TextEncoder.encode` would materialise the whole byte array
 *  just to read its length. */
function utf8Len(s: string): number {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i)
    if (code < 0x80) n += 1
    else if (code < 0x800) n += 2
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      // Surrogate pair → one 4-byte code point.
      n += 4
      i++
    } else n += 3
  }
  return n
}

/** Truncate `s` to `max` chars, keeping both ends (a memory's tail
 *  usually carries the "so what", its head the subject). */
function truncateMiddle(s: string, max: number): string {
  if (s.length <= max) return s
  const half = Math.max(2, Math.floor((max - 1) / 2))
  return `${s.slice(0, half)}…${s.slice(s.length - half)}`
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
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
      <span class="text-[var(--color-violet)] font-semibold text-dense">save_memory</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-dense"
        :title="headerTitle"
        data-testid="save-memory-header-label"
      >
        {{ headerLabel }}
      </span>

      <!-- Status indicator -->
      <span class="text-dense font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Live badge (tool call underway, envelope still empty) -->
      <span
        v-if="isRunning"
        data-testid="save-memory-running"
        class="text-micro text-yellow-500 animate-pulse shrink-0"
      >
        running…
      </span>

      <!-- Copy id button (only on success — there's something to copy) -->
      <button
        v-if="isSuccess && memoryId"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-lead transition-opacity"
        @click="copyId"
        title="Copy memory id"
        data-testid="save-memory-copy-id"
      >
        ⎘
      </button>

      <!-- Toggle indicator -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Error message -->
      <div
        v-if="errorMessage"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense"
        data-testid="save-memory-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Success path: id + tags + created_at + updated_at + body rows -->
      <template v-if="isSuccess">
        <div
          v-if="memoryId"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="save-memory-id-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Id:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            memoryId
          }}</span>
        </div>

        <!-- Tags chips (mirrors LoadMemory's per-entry chips). -->
        <div
          v-if="savedTags.length > 0"
          class="flex gap-1 items-start px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="save-memory-tags-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Tags:</span>
          <span class="flex flex-wrap gap-1 min-w-0">
            <span
              v-for="(tag, i) in savedTags"
              :key="`${tag}-${i}`"
              class="tag-chip"
              :title="`tag: ${tag}`"
              :data-testid="`save-memory-tag-${i}`"
            >
              {{ tag }}
            </span>
          </span>
        </div>

        <div
          v-if="createdAt"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="save-memory-created-at-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Created:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            createdAt
          }}</span>
        </div>

        <div
          v-if="updatedAt"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="save-memory-updated-at-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Updated:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            updatedAt
          }}</span>
        </div>

        <!-- The stored body — the whole point of the card. -->
        <div v-if="hasBody" class="px-2 py-1.5" data-testid="save-memory-content-row">
          <div class="flex items-center gap-2 mb-1">
            <span class="font-semibold text-[var(--semantic-text-muted)] shrink-0">Content:</span>
            <span
              class="text-micro text-[var(--semantic-text-dim)] shrink-0"
              :data-testid="`save-memory-content-size`"
            >
              {{ contentSizeLabel }}
            </span>
            <span class="flex-1" />
            <button
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:!text-violet-500 text-lead transition-opacity"
              @click.stop="copyContent"
              title="Copy the full memory body"
              data-testid="save-memory-copy-content"
            >
              ⎘
            </button>
          </div>
          <pre class="content-body" data-testid="save-memory-content">{{ displayContent }}</pre>
          <p
            v-if="hiddenChars > 0"
            class="mt-1 text-micro text-orange-500"
            data-testid="save-memory-content-clipped"
          >
            … {{ hiddenChars.toLocaleString() }} more characters not shown — use ⎘ to copy the full
            body
          </p>
        </div>

        <!-- Edge case: empty envelope (no id, no timestamps, no body). Show a
             muted hint so the user knows the card is empty, not stuck. -->
        <div
          v-if="!memoryId && !createdAt && !updatedAt && !hasBody"
          class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-dense italic"
          data-testid="save-memory-empty"
        >
          (no fields in envelope)
        </div>
      </template>
      <ToolParameters :parameters="parameters" :exclude="ARGS_EXCLUDE" />
    </div>
  </div>
</template>

<style scoped>
/* Mirrors LoadMemory.vue's per-entry tags + content body so the two memory
   cards read as one family. Scoped so nothing leaks. */
.tag-chip {
  font-family: monospace;
  font-size: var(--text-micro);
  background-color: rgba(99, 102, 241, 0.12);
  color: rgb(99, 102, 241);
  padding: 1px 5px;
  border-radius: 3px;
  white-space: nowrap;
}

.content-body {
  margin: 0;
  padding: 8px 10px;
  background-color: var(--semantic-card-bg);
  border-radius: 4px;
  border: 1px solid var(--color-border);
  font-family: monospace;
  font-size: var(--text-meta);
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
  max-height: 320px;
  overflow-y: auto;
}
</style>
