<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { marked } from 'marked'

interface PreviewItem {
  id: string
  content: string
  parameters?: string
  tool_call_id?: string
}

const props = defineProps<{
  previews: PreviewItem[]
  collapsed?: boolean
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
  if (!p?.parameters) return {}
  try { return JSON.parse(p.parameters) as Args } catch { return {} }
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
  if (p.parameters) {
    try {
      const parsed = JSON.parse(p.parameters)
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
    class="preview-side-panel flex flex-col border-l border-[var(--color-border)] bg-[var(--semantic-bg)] transition-all duration-200"
    :class="isCollapsed ? 'w-8' : 'w-[480px]'"
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
        <button class="px-1 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] hover:text-red-500" title="Dismiss panel" @click="dismiss">&#10005;</button>
      </div>
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
