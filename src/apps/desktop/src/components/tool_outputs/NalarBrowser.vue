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

    <!-- Chunk 2 will fill the body. Empty for now so toggle is observable. -->
    <div
      v-if="isExpanded"
      data-testid="nalar-browser-body"
      class="border-t border-[var(--color-border)]"
    ></div>
  </div>
</template>
