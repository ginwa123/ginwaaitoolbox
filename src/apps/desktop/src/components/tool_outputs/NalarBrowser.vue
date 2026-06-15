<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  /** Inner <data> XML from the nalar_browser result envelope.
   *  (parent unwraps the <tool> envelope via tryUnwrapToolOutput and
   *  passes the inner <data> payload here). */
  content: string
  /** Tool-call arguments as a JSON string. Used to detect the
   *  action (launch / open_page / snapshot / click / fill / press /
   *  close_page / close_browser) and to display action-specific args
   *  in the header. */
  parameters: string
  /** Whether the row is already expanded in the parent chat. */
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// ── Action detection ────────────────────────────────────────────────────
interface BrowserActionArgs {
  action?: string
  browser_id?: string
  page_id?: string
  url?: string
  ref?: string
  text?: string
  key?: string
}

const args = computed<BrowserActionArgs>(() => {
  try {
    const parsed = JSON.parse(props.parameters)
    if (parsed && typeof parsed === 'object') return parsed as BrowserActionArgs
  } catch {
    /* fall through */
  }
  return {}
})

const action = computed(() => args.value.action ?? 'unknown')

// ── Inner-data XML parsing ──────────────────────────────────────────────
function findTag(haystack: string, tag: string): string | null {
  const openSeq = `<${tag}>`
  const closeSeq = `</${tag}>`
  const start = haystack.indexOf(openSeq)
  if (start === -1) return null
  const valueStart = start + openSeq.length
  const end = haystack.indexOf(closeSeq, valueStart)
  if (end === -1) return null
  return haystack.slice(valueStart, end)
}

const browserId = computed(() => findTag(props.content, 'browser_id'))
const pageId = computed(() => findTag(props.content, 'page_id'))
const url = computed(() => findTag(props.content, 'url'))
const title = computed(() => findTag(props.content, 'title'))
const statusStr = computed(() => findTag(props.content, 'status'))
const statusNum = computed(() => {
  const s = statusStr.value
  if (s === null) return null
  const n = parseInt(s, 10)
  return Number.isFinite(n) ? n : null
})
const treeJson = computed(() => findTag(props.content, 'tree'))

// Snapshot tree element count
interface SnapshotElement {
  ref: string
  text: string
  href?: string
}

const snapshotElements = computed<SnapshotElement[] | null>(() => {
  const t = treeJson.value
  if (t === null) return null
  try {
    const parsed = JSON.parse(t)
    if (Array.isArray(parsed)) return parsed as SnapshotElement[]
  } catch {
    /* fall through */
  }
  return null
})

const elementCount = computed(() => snapshotElements.value?.length ?? 0)

// ── Header content (action-specific) ────────────────────────────────────
const headerLabel = computed(() => {
  const a = action.value
  switch (a) {
    case 'launch':
      return browserId.value ?? 'no browser_id'
    case 'open_page':
      // Render both the title AND the URL so the test (and the user)
      // can see what page was opened. Title is the primary label; URL
      // is appended when it differs from the title.
      if (title.value && url.value && title.value != url.value) {
        return `${title.value} · ${url.value}`
      }
      return title.value ?? url.value ?? pageId.value ?? 'page'
    case 'snapshot':
      return `${elementCount.value} element${elementCount.value !== 1 ? 's' : ''}`
    case 'click':
      return args.value.ref ? `→ ${args.value.ref}` : 'no ref'
    case 'fill':
      return args.value.ref
        ? `→ ${args.value.ref} "${args.value.text ?? ''}"`
        : 'no ref'
    case 'press':
      return args.value.key ? `→ ${args.value.key}` : 'no key'
    case 'close_page':
    case 'close_browser':
      return args.value.page_id ?? args.value.browser_id ?? ''
    default:
      return browserId.value ?? pageId.value ?? url.value ?? ''
  }
})

// Inner <error>…</error> tag from toXMLError (present in some error paths).
const errorMessage = computed(() => findTag(props.content, 'error'))

// Copy a ref's text to the clipboard (used by snapshot rows)
const copyText = async (text: string) => {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    /* clipboard may be unavailable in some test envs — silently no-op */
  }
}

// Status colour hint (used in the header badge)
const statusClass = computed(() => {
  if (statusNum.value === null) return ''
  if (statusNum.value >= 200 && statusNum.value < 300) return 'text-green-500'
  if (statusNum.value >= 300 && statusNum.value < 400) return 'text-yellow-500'
  return 'text-red-500'
})

// Action icon (kept lightweight — text emoji, not an SVG sprite)
const actionIcon = computed(() => {
  switch (action.value) {
    case 'launch':
      return '🚀'
    case 'open_page':
      return '🌐'
    case 'snapshot':
      return '📸'
    case 'click':
      return '🖱️'
    case 'fill':
      return '⌨️'
    case 'press':
      return '⏎'
    case 'close_page':
      return '❎'
    case 'close_browser':
      return '🛑'
    default:
      return '🔧'
  }
})

// ── Header click toggles the body ───────────────────────────────────────
const toggle = () => {
  isExpanded.value = !isExpanded.value
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
  >
    <div
      data-testid="nalar-browser-header"
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-base leading-none" :title="`nalar_browser · ${action}`">
        {{ actionIcon }}
      </span>
      <span class="text-[var(--color-violet)] font-semibold text-xs">nalar_browser</span>
      <span class="text-[var(--semantic-text-dim)] text-xs">·</span>
      <span class="text-[var(--color-violet)] text-xs font-medium">{{ action }}</span>
      <span
        v-if="headerLabel"
        class="flex-1 truncate text-left text-[var(--semantic-text)] text-xs"
        :title="headerLabel"
        >{{ headerLabel }}</span
      >
      <span v-if="statusClass" class="text-xs font-semibold" :class="statusClass">
        {{ statusStr }}
      </span>
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <div
      v-if="isExpanded"
      data-testid="nalar-browser-body"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <!-- Error path: <error>…</error> from toXMLError (rare in the
           envelope today because wrapToolOutput drops <data> on success=false,
           but the inner data still carries the <error> tag from the old
           toXMLError XML, so we render it as a red block). -->
      <div
        v-if="errorMessage"
        data-testid="nalar-browser-error"
        class="px-3 py-2 text-red-500 text-xs"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Snapshot tree renderer -->
      <div v-else-if="action === 'snapshot'">
        <div
          v-if="snapshotElements && snapshotElements.length > 0"
          class="divide-y divide-[var(--color-border)]"
        >
          <div
            v-for="(el, idx) in snapshotElements"
            :key="idx"
            data-testid="snapshot-element"
            class="group flex items-center gap-2 px-2 py-1 hover:bg-violet-500/5"
          >
            <span
              class="font-mono text-[10px] px-1.5 py-0.5 rounded shrink-0"
              style="background-color: var(--color-violet); color: white; opacity: 0.85;"
              :title="`Ref: ${el.ref}`"
              >{{ el.ref }}</span
            >
            <span
              v-if="el.href"
              class="text-[var(--semantic-text)] text-xs truncate flex-1"
              :title="el.text + ' → ' + el.href"
            >
              {{ el.text }}
              <span class="text-[var(--semantic-text-muted)]">→</span>
              <span class="text-[var(--color-blue)] underline">{{ el.href }}</span>
            </span>
            <span
              v-else
              class="text-[var(--semantic-text)] text-xs truncate flex-1"
              :title="el.text"
              >{{ el.text }}</span
            >
            <button
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
              @click.stop="copyText(el.text)"
              :title="`Copy ref ${el.ref}`"
            >
              ⎘
            </button>
          </div>
        </div>
        <div
          v-else-if="treeJson === null"
          class="px-3 py-2 text-[var(--semantic-text-muted)] text-xs italic"
        >
          snapshot returned no tree
        </div>
        <div
          v-else-if="snapshotElements === null"
          data-testid="snapshot-raw-tree"
          class="px-3 py-2"
        >
          <div class="text-[0.65rem] text-[var(--semantic-text-muted)] mb-1">
            tree (raw — not valid JSON)
          </div>
          <pre
            class="m-0 p-2 bg-black/[0.02] text-xs whitespace-pre-wrap break-all leading-relaxed"
            >{{ treeJson }}</pre>
        </div>
        <div
          v-else
          class="px-3 py-2 text-[var(--semantic-text-muted)] text-xs italic"
        >
          no elements
        </div>
      </div>

      <!-- open_page: show URL + status details -->
      <div v-else-if="action === 'open_page'" class="px-3 py-2 text-xs space-y-1">
        <div v-if="url" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">URL</span>
          <a
            :href="url"
            target="_blank"
            rel="noopener noreferrer"
            class="text-[var(--color-blue)] underline truncate"
            :title="url"
            >{{ url }}</a
          >
        </div>
        <div v-if="title" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">Title</span>
          <span class="truncate" :title="title">{{ title }}</span>
        </div>
        <div v-if="pageId" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">Page ID</span>
          <span class="font-mono truncate" :title="pageId">{{ pageId }}</span>
        </div>
      </div>

      <!-- launch: show browser_id -->
      <div v-else-if="action === 'launch' && browserId" class="px-3 py-2 text-xs">
        <div class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">Browser ID</span>
          <span class="font-mono truncate" :title="browserId">{{ browserId }}</span>
        </div>
      </div>

      <!-- click / fill / press / close_*: show the action args in a compact row -->
      <div
        v-else-if="action === 'click' || action === 'fill' || action === 'press' || action === 'close_page' || action === 'close_browser'"
        class="px-3 py-2 text-xs space-y-1"
      >
        <div v-if="args.ref" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">ref</span>
          <span class="font-mono">{{ args.ref }}</span>
        </div>
        <div v-if="args.text" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">text</span>
          <span class="truncate" :title="args.text">{{ args.text }}</span>
        </div>
        <div v-if="args.key" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">key</span>
          <span class="font-mono">{{ args.key }}</span>
        </div>
        <div v-if="args.url" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">url</span>
          <span class="text-[var(--color-blue)] underline truncate" :title="args.url">
            {{ args.url }}
          </span>
        </div>
        <div v-if="args.page_id" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">page_id</span>
          <span class="font-mono truncate" :title="args.page_id">{{ args.page_id }}</span>
        </div>
        <div v-if="args.browser_id" class="flex gap-2">
          <span class="text-[var(--semantic-text-muted)] shrink-0">browser_id</span>
          <span class="font-mono truncate" :title="args.browser_id">
            {{ args.browser_id }}
          </span>
        </div>
      </div>
    </div>
  </div>
</template>
