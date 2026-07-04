<script setup lang="ts">
import { computed, ref, watch, onUnmounted } from 'vue'
import { marked } from 'marked'
import { tryUnwrapToolOutput } from '@/helpers/unwrapToolOutput'

// ─── Resize state (preview-panel-resize design) ─────────────────────────
//
// Self-contained resize: the component owns its width state + drag
// listeners + localStorage persistence. No parent (ChatView.vue)
// coordination needed. Mirrors the RightSidebar.vue resize pattern
// (src/apps/desktop/src/components/RightSidebar.vue:20-64).
//
// Bounds rationale:
//   - MIN 240: below this, markdown/code content becomes unreadable
//     and the tab strip / header overlap. Matches RightSidebar's 200
//     floor + a small margin for the header.
//   - NO UPPER BOUND: user explicitly requested "full screen" —
//     the panel can grow to fill the entire viewport. The chat column
//     (flex-1 min-w-0) absorbs the rest and shrinks to 0; the user
//     recovers via the existing chevron collapse button.
const MIN_PREVIEW_WIDTH = 240
const DEFAULT_PREVIEW_WIDTH = 480
const PREVIEW_WIDTH_STORAGE_KEY = 'nalar-preview-panel-width'

const loadPreviewPanelWidth = (): number => {
  if (typeof localStorage === 'undefined') return DEFAULT_PREVIEW_WIDTH
  const saved = localStorage.getItem(PREVIEW_WIDTH_STORAGE_KEY)
  if (saved === null) return DEFAULT_PREVIEW_WIDTH
  const parsed = parseInt(saved, 10)
  if (isNaN(parsed) || parsed < MIN_PREVIEW_WIDTH) return DEFAULT_PREVIEW_WIDTH
  return parsed
}

const savePreviewPanelWidth = (width: number) => {
  if (typeof localStorage === 'undefined') return
  try {
    localStorage.setItem(PREVIEW_WIDTH_STORAGE_KEY, String(width))
  } catch {
    // localStorage may throw in private-mode or quota-exceeded
    // scenarios; silently ignore so the in-memory drag still works.
    // Matches AppLayout.vue:599-603 (kanban-column resize pattern).
  }
}

const localWidth = ref(loadPreviewPanelWidth())

// Resize interaction state. The drag math is the standard
// `startWidth + (startX - clientX)` formula — moving the cursor
// LEFT grows the panel (panel is on the right, handle on left edge).
const isResizing = ref(false)
const resizeStartX = ref(0)
const resizeStartWidth = ref(0)

const startResize = (e: MouseEvent) => {
  isResizing.value = true
  resizeStartX.value = e.clientX
  resizeStartWidth.value = localWidth.value
  // Document-level listeners — NOT on the handle — so a fast drag
  // doesn't outrun the handle. Pattern matches Sidebar.vue:200-225
  // and AppLayout.vue:552-604 (kanban-column resize).
  document.addEventListener('mousemove', handleResize)
  document.addEventListener('mouseup', stopResize)
  document.body.style.cursor = 'ew-resize'
  document.body.style.userSelect = 'none'
}

const handleResize = (e: MouseEvent) => {
  if (!isResizing.value) return
  const delta = resizeStartX.value - e.clientX
  // No upper clamp — user wants "full screen". Only floor at MIN.
  const newWidth = Math.max(MIN_PREVIEW_WIDTH, resizeStartWidth.value + delta)
  localWidth.value = newWidth
}

const stopResize = () => {
  if (!isResizing.value) return
  isResizing.value = false
  document.removeEventListener('mousemove', handleResize)
  document.removeEventListener('mouseup', stopResize)
  document.body.style.cursor = ''
  document.body.style.userSelect = ''
  // Persist on release (not during drag — dragging fires 60+ events/sec
  // and localStorage.setItem is synchronous + slow enough to noticeably
  // drag the resize interaction). One write per gesture. Matches
  // AppLayout.vue:585-604.
  savePreviewPanelWidth(localWidth.value)
}

// Cleanup: remove listeners even if a drag is mid-gesture (e.g. user
// navigates away mid-drag). Prevents orphan document listeners.
// Matches Sidebar.vue:227-229.
onUnmounted(() => {
  stopResize()
})

interface PreviewItem {
  id: string
  content: string
  tool_call_id?: string
}

const props = defineProps<{
  previews: PreviewItem[]
  collapsed?: boolean
  /**
   * When the parent (ChatView) wants the panel to focus a specific
   * preview — e.g. because the user clicked a `show_preview` tool
   * message bubble in the chat — it passes the preview's `id` here.
   * The watcher below finds that preview in `previews` and jumps
   * `activeIndex` to it. The parent's responsibility is to also
   * clear `previewPanelCollapsed` and `previewPanelDismissed` so
   * the panel is visible; this prop only controls which TAB is
   * active. Set to `null`/`undefined` to fall back to the default
   * behavior (newest preview when a new one lands).
   */
  focusId?: string | null
}>()

const emit = defineEmits<{
  'update:collapsed': [value: boolean]
  'dismiss': []
}>()

const isCollapsed = ref(props.collapsed ?? false)
watch(() => props.collapsed, (v) => { isCollapsed.value = v ?? false })

const activeIndex = ref(0)
watch(() => props.previews.length, (newLen, oldLen) => {
  if (newLen > (oldLen ?? 0)) activeIndex.value = newLen - 1
  if (activeIndex.value >= newLen) activeIndex.value = Math.max(0, newLen - 1)
})

// When the parent sets `focusId` (user clicked a `show_preview`
// message bubble), find the matching preview by id and jump to it.
// No-op when focusId is null/undefined or doesn't match any current
// preview (the user may have clicked a bubble for a preview that
// has since been filtered out — e.g. after a chat switch wiped
// previews). Falls through silently; the panel keeps whatever
// `activeIndex` already had.
watch(() => props.focusId, (fid) => {
  if (!fid) return
  const idx = props.previews.findIndex((p) => p.id === fid)
  if (idx !== -1) activeIndex.value = idx
})

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

const activePreview = computed(() => props.previews[activeIndex.value] ?? null)
const activeContentType = computed(() => findTag(activePreview.value?.content ?? '', 'content_type') ?? 'text')
const activePreviewId = computed(() => findTag(activePreview.value?.content ?? '', 'preview_id') ?? '')

interface Args { content_type?: string; content?: string; title?: string; language?: string; caption?: string }
const activeArgs = computed<Args>(() => {
  const p = activePreview.value
  if (!p) return {}
  // Extract the show_preview tool-call arguments from the wrapper
  // envelope. The backend stores the input inside the
  // `<parameters>...</parameters>` tag of the `<tool>...</tool>`
  // envelope (see tool_registry.wrapToolOutput). After my backend fix
  // for the `<parameters>` double-wrap, the inner content is XML
  // (converted by jsonArgsToXml), NOT raw JSON — so we must read it
  // with findTag, not JSON.parse. The JSON.parse fallback handles
  // the rare case of legacy rows still in raw-JSON form.
  const unwrapped = tryUnwrapToolOutput(p.content)
  if (!unwrapped?.parameters) return {}
  const paramsXml = unwrapped.parameters
  // Try XML-based extraction first (current backend behavior).
  const fromXml: Args = {
    content_type: findTag(paramsXml, 'content_type') ?? undefined,
    content: findTag(paramsXml, 'content') ?? undefined,
    title: findTag(paramsXml, 'title') ?? undefined,
    language: findTag(paramsXml, 'language') ?? undefined,
    caption: findTag(paramsXml, 'caption') ?? undefined,
  }
  if (fromXml.content) return fromXml
  // Fallback: try JSON (legacy raw-JSON rows, if any exist).
  try {
    const parsed = JSON.parse(paramsXml) as Args
    if (parsed && typeof parsed === 'object') return parsed
  } catch {
    /* not JSON — fall through */
  }
  return {}
})

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

const renderedContent = computed<string>(() => {
  const ct = activeContentType.value
  const c = activeArgs.value.content ?? ''
  if (ct === 'markdown') {
    try { return marked.parse(c, { async: false }) as string } catch { return `<pre>${escapeHtml(c)}</pre>` }
  }
  if (ct === 'text') return `<pre class="whitespace-pre-wrap break-all">${escapeHtml(c)}</pre>`
  if (ct === 'code') {
    const lang = activeArgs.value.language ?? 'plaintext'
    return `<pre><code class="language-${escapeHtml(lang)}">${escapeHtml(c)}</code></pre>`
  }
  return ''
})

const imageSrc = computed<string | null>(() => {
  if (activeContentType.value !== 'image') return null
  const c = activeArgs.value.content ?? ''
  if (c.startsWith('data:') || c.startsWith('http://') || c.startsWith('https://')) return c
  return null
})

const ICONS: Record<string, string> = { markdown: 'M', text: 'T', code: 'C', image: 'I' }

function tabLabel(p: PreviewItem): string {
  const ct = findTag(p.content, 'content_type') ?? 'text'
  const icon = ICONS[ct] ?? '?'
  let title = ''
  const unwrapped = tryUnwrapToolOutput(p.content)
  if (unwrapped?.parameters) {
    try {
      const parsed = JSON.parse(unwrapped.parameters)
      if (parsed?.title) title = String(parsed.title)
    } catch { /* ignore */ }
  }
  if (title) return `${icon} ${title.length > 16 ? title.slice(0, 16) + '...' : title}`
  return `${icon} ${ct}`
}

const toggleCollapse = () => { isCollapsed.value = !isCollapsed.value; emit('update:collapsed', isCollapsed.value) }
const dismiss = () => { emit('dismiss') }
</script>

<template>
  <div
    v-if="previews.length > 0"
    class="preview-side-panel relative flex flex-col border-l border-[var(--color-border)] bg-[var(--semantic-bg)] transition-all duration-200"
    :class="isCollapsed ? 'w-8' : 'shrink-0'"
    :style="isCollapsed ? undefined : { width: localWidth + 'px' }"
    data-testid="preview-side-panel"
  >
    <div v-if="isCollapsed" class="flex-1 flex flex-col items-center justify-start pt-4 gap-2">
      <button class="px-1 py-2 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-[var(--color-violet)]" :title="`${previews.length} preview(s)`" @click="toggleCollapse">
        <span class="block text-lg">&#9654;</span>
        <span class="block text-[0.65rem] mt-2" style="writing-mode: vertical-rl;">{{ previews.length }}</span>
      </button>
    </div>
    <template v-else>
      <div class="flex items-center gap-1 px-2 py-1 border-b border-[var(--color-border)]">
        <button class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-[var(--color-violet)] text-sm" title="Collapse panel" @click="toggleCollapse">&#9664;</button>
        <span class="text-[var(--color-violet)] font-semibold text-xs flex-1 truncate">Preview</span>
        <span class="text-[0.65rem] text-[var(--semantic-text-muted)]">{{ activeIndex + 1 }} of {{ previews.length }}</span>
        <button class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-red-500" title="Dismiss panel" @click="toggleCollapse">&#10005;</button>
      </div>
      <!--
        Resize handle: 1px-wide vertical bar on the LEFT edge of the
        panel (panel is on the right; handle on left → dragging left
        grows the panel). Colors match RightSidebar.vue:208-211:
        transparent at rest, violet @ 30% on hover, violet @ 50%
        during active drag. Hidden when collapsed (nothing to drag).
      -->
      <div
        v-if="!isCollapsed"
        data-testid="preview-resize-handle"
        class="absolute top-0 left-0 h-full w-1 cursor-ew-resize z-10 transition-colors"
        :class="isResizing ? 'bg-[var(--color-violet)]/50' : 'bg-transparent hover:bg-[var(--color-violet)]/30'"
        @mousedown="startResize"
      />
      <div v-if="previews.length > 1" class="flex flex-wrap gap-1 px-2 py-1 border-b border-[var(--color-border)] bg-black/[0.02]">
        <button
          v-for="(p, i) in previews"
          :key="p.id"
          class="px-2 py-1 rounded text-xs font-mono border"
          :class="i === activeIndex ? 'bg-[var(--color-violet)]/15 text-[var(--color-violet)] border-[var(--color-violet)]/40' : 'bg-transparent text-[var(--semantic-text-muted)] border-[var(--color-border)] hover:border-[var(--color-violet)]/40'"
          :title="`Preview ${i + 1}: ${findTag(p.content, 'preview_id') ?? ''}`"
          @click="activeIndex = i"
        >{{ tabLabel(p) }}</button>
      </div>
      <div v-if="activePreview" class="flex-1 overflow-y-auto p-3">
        <div v-if="activeArgs.title" class="text-sm font-semibold text-[var(--semantic-text)] mb-2 pb-2 border-b border-dashed border-[var(--color-border)]">
          {{ activeArgs.title }}
          <span v-if="activeArgs.language" class="ml-2 text-xs text-[var(--semantic-text-muted)] font-normal">[{{ activeArgs.language }}]</span>
        </div>
        <div v-if="activeContentType === 'image'" class="flex justify-center bg-black/[0.04] p-2 rounded">
          <img v-if="imageSrc" :src="imageSrc" :alt="activeArgs.title || activeArgs.caption || 'Preview image'" class="max-w-full max-h-96 object-contain" @error="(e) => { (e.target as HTMLImageElement).style.display = 'none' }" />
          <div v-else class="text-xs text-red-500 italic">Image source invalid (expected data: URL or http(s) URL)</div>
        </div>
        <div v-else class="text-xs text-[var(--semantic-text)] markdown-content" v-html="renderedContent" />
        <div v-if="activeArgs.caption" class="mt-2 pt-2 text-xs italic text-[var(--semantic-text-muted)] border-t border-dashed border-[var(--color-border)]">
          {{ activeArgs.caption }}
        </div>
        <div class="mt-3 pt-2 text-[0.65rem] text-[var(--semantic-text-dim)] font-mono">
          {{ activeContentType }} · preview_id: {{ activePreviewId }}
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.markdown-content :deep(pre) { background: var(--color-code-bg, rgba(0,0,0,0.05)); padding: 0.5rem; border-radius: 0.25rem; overflow-x: auto; }
.markdown-content :deep(code) { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 0.75rem; }
.markdown-content :deep(h1) { font-size: 1.25rem; font-weight: 700; margin: 0.5rem 0; }
.markdown-content :deep(h2) { font-size: 1.1rem; font-weight: 600; margin: 0.4rem 0; }
.markdown-content :deep(h3) { font-size: 1rem; font-weight: 600; margin: 0.3rem 0; }
.markdown-content :deep(p) { margin: 0.25rem 0; line-height: 1.4; }
.markdown-content :deep(ul), .markdown-content :deep(ol) { margin: 0.25rem 0 0.25rem 1.5rem; }
.markdown-content :deep(a) { color: var(--color-violet); text-decoration: underline; }
.markdown-content :deep(table) { border-collapse: collapse; margin: 0.5rem 0; }
.markdown-content :deep(th), .markdown-content :deep(td) { border: 1px solid var(--color-border); padding: 0.25rem 0.5rem; }
</style>
