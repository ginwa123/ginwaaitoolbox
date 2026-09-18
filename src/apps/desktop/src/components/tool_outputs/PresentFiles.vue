<!--
  PresentFiles — tool output component for the `present_files` agent tool.

  Renders the XML envelope produced by `executePresentFilesToString` in
  `src/modules/agent/tools/present_files.zig`. The component is
  presentational except for plain `<a href>` / `<img src>` / `<iframe src>`
  links to the download endpoint (`GET /api/files/download`, cookie-based
  auth so no JS fetch/blob dance is needed — except the text branch, which
  fetches source over same-origin `fetch` so cookies ride along):

  Success:
    <present_files>
      <status>presented</status>
      <count>2</count>
      <files>
        <file path="/abs/a.txt" bytes="12" mime="text/plain; charset=utf-8" label="notes"/>
        <file path="/abs/b.jpg" bytes="48211" mime="image/jpeg" label="b.jpg"/>
      </files>
    </present_files>
  Error:
    <present_files><error>file not found: ...</error></present_files>

  Per-file rendering (inline preview + download):
    - image/* mimes: thumbnail in the row + full-width preview below
      (click either → fullscreen `ImagePreview` modal). Filename + ⬇
      button download (`disposition=attachment`).
    - text/html: fetched source rendered into a sandboxed `srcdoc`
      iframe (fixed 480px height) + "Open in new tab" action. Same
      sandbox contract as the former `show_preview` html branch
      (allow-scripts only: no allow-same-origin, no allow-forms, no
      top navigation). Fetched via same-origin `fetch` (cookies ride
      along) because the download endpoint's response carries the
      server's default framing headers (`X-Frame-Options: DENY` +
      `frame-ancestors 'none'`), which refuse a direct
      `<iframe src=downloadUrl>` navigation while leaving top-level
      "Open in new tab" working.
    - application/pdf: fetched as a Blob and embedded via an object
      URL (same framing-header reason as html) + "Open in new tab".
    - video/*: native `<video controls>`. audio/*: native `<audio controls>`.
    - video/*: native `<video controls>`. audio/*: native `<audio controls>`.
    - text-like (text/*, application/json, application/javascript):
      fetched source (≤ 512 KB, sliced to 200k chars) rendered via
      `PreviewContentRenderer` — markdown for `.md`, code + language for
      known code extensions, plain text otherwise.
    - everything else: generic 📄 row (icon + name + size + mime + ⬇).

  Header (always visible):
    `present_files → N files ✓` (success)
    `present_files → <error_message> ✗` (failure)

  Style matches the rest of tool_outputs (ReadFile, GenerateImage):
  monospace, rounded-md, border + soft card bg, violet tool-name,
  ✗/✓ status indicators, expand/collapse `+`/`−` toggle.
-->
<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import ImagePreview from '../preview/ImagePreview.vue'
import PreviewContentRenderer from '../preview/PreviewContentRenderer.vue'
import {
  normalizeToolContent,
  parsePresentFiles,
  isPreviewableImage,
  basenameOfPath,
  formatBytes,
  type ParsedPresentFile,
} from './_shared/toolOutputParser'
import { fileDownloadUrl } from '../../api'

const props = defineProps<{
  /**
   * The inner `<data>` XML from the present_files tool's `<tool>`
   * envelope (already unwrapped by the parent's
   * `tryUnwrapToolOutput` pipeline). Always XML — never JSON.
   */
  content: unknown
  /**
   * The session id — threaded into the download/preview URLs as
   * `?session_id=` so the backend can sandbox paths to the session
   * working directory. Falls back to `chatId` at the call site.
   */
  sessionId: string
  /**
   * Whether the row is already expanded in the parent chat.
   */
  expanded?: boolean
  /**
   * Session working directory (for the header's open-in-editor hint).
   */
  cwd?: string
  /**
   * The JSON-stringified tool-call arguments. Rendered collapsed via
   * ToolParameters for parity with the other cards.
   */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parsePresentFiles(normalized.value.data)
  if (normalized.value.error) {
    return { ...p, error: normalized.value.error }
  }
  return p
})
const fullscreenSrc = ref<string | null>(null)

const files = computed((): ParsedPresentFile[] => parsed.value.files)

const displayName = (f: ParsedPresentFile): string =>
  f.label && f.label.trim() !== '' ? f.label : basenameOfPath(f.path)

const downloadUrl = (f: ParsedPresentFile): string =>
  fileDownloadUrl(props.sessionId, f.path, 'attachment')

const previewUrl = (f: ParsedPresentFile): string =>
  fileDownloadUrl(props.sessionId, f.path, 'inline')

const isImage = (f: ParsedPresentFile): boolean => isPreviewableImage(f.mime)

const mimeLower = (f: ParsedPresentFile): string => f.mime.toLowerCase()

const isHtml = (f: ParsedPresentFile): boolean =>
  mimeLower(f).includes('text/html') ||
  f.path.toLowerCase().endsWith('.html') ||
  f.path.toLowerCase().endsWith('.htm')

const isPdf = (f: ParsedPresentFile): boolean =>
  mimeLower(f).includes('application/pdf') || f.path.toLowerCase().endsWith('.pdf')

const isVideo = (f: ParsedPresentFile): boolean => mimeLower(f).startsWith('video/')

const isAudio = (f: ParsedPresentFile): boolean => mimeLower(f).startsWith('audio/')

const CODE_LANG_BY_EXT: Record<string, string> = {
  '.zig': 'zig',
  '.ts': 'typescript',
  '.tsx': 'typescript',
  '.js': 'javascript',
  '.mjs': 'javascript',
  '.jsx': 'javascript',
  '.py': 'python',
  '.json': 'json',
  '.css': 'css',
  '.sh': 'bash',
  '.rs': 'rust',
  '.go': 'go',
  '.java': 'java',
  '.vue': 'vue',
}

const extOf = (f: ParsedPresentFile): string => {
  const base = basenameOfPath(f.path)
  const dot = base.lastIndexOf('.')
  return dot === -1 ? '' : base.slice(dot).toLowerCase()
}

/** Text-like files render fetched source inline (not just a row). */
const isTextLike = (f: ParsedPresentFile): boolean => {
  if (isHtml(f)) return false
  const m = mimeLower(f)
  if (m.startsWith('text/')) return true
  if (m.includes('application/json') || m.includes('application/javascript')) return true
  return extOf(f) in CODE_LANG_BY_EXT
}

type TextRendererType = 'markdown' | 'text' | 'code'

const textRendererType = (f: ParsedPresentFile): TextRendererType => {
  const ext = extOf(f)
  if (ext === '.md' || mimeLower(f).includes('markdown')) return 'markdown'
  if (ext in CODE_LANG_BY_EXT) return 'code'
  return 'text'
}

const textLanguage = (f: ParsedPresentFile): string | undefined => {
  if (textRendererType(f) !== 'code') return undefined
  return CODE_LANG_BY_EXT[extOf(f)] ?? 'plaintext'
}

/** Inline text fetch budget: skip huge files, slice the rest. */
const MAX_INLINE_TEXT_BYTES = 512 * 1024
const MAX_INLINE_TEXT_CHARS = 200_000

interface TextState {
  status: 'loading' | 'ready' | 'error' | 'skipped'
  content: string
  truncated: boolean
  error: string | null
}

const textByPath = ref<Record<string, TextState>>({})

async function fetchTextFor(f: ParsedPresentFile): Promise<void> {
  const key = f.path
  if (textByPath.value[key]) return
  if (!isTextLike(f)) return
  if (f.bytes > MAX_INLINE_TEXT_BYTES) {
    textByPath.value[key] = {
      status: 'skipped',
      content: '',
      truncated: false,
      error: null,
    }
    return
  }
  textByPath.value[key] = { status: 'loading', content: '', truncated: false, error: null }
  try {
    const res = await fetch(previewUrl(f))
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const raw = await res.text()
    const truncated = raw.length > MAX_INLINE_TEXT_CHARS
    textByPath.value[key] = {
      status: 'ready',
      content: truncated ? raw.slice(0, MAX_INLINE_TEXT_CHARS) : raw,
      truncated,
      error: null,
    }
  } catch (e) {
    textByPath.value[key] = {
      status: 'error',
      content: '',
      truncated: false,
      error: e instanceof Error ? e.message : 'fetch failed',
    }
  }
}

/** Inline HTML fetch budget: the whole doc lives in memory as srcdoc. */
const MAX_INLINE_HTML_BYTES = 1024 * 1024
/** Inline PDF fetch budget: the whole file lives in memory as a Blob. */
const MAX_INLINE_PDF_BYTES = 20 * 1024 * 1024

interface HtmlState {
  status: 'loading' | 'ready' | 'error' | 'skipped'
  content: string
  error: string | null
}

const htmlByPath = ref<Record<string, HtmlState>>({})

async function fetchHtmlFor(f: ParsedPresentFile): Promise<void> {
  const key = f.path
  if (htmlByPath.value[key]) return
  if (!isHtml(f)) return
  if (f.bytes > MAX_INLINE_HTML_BYTES) {
    htmlByPath.value[key] = { status: 'skipped', content: '', error: null }
    return
  }
  htmlByPath.value[key] = { status: 'loading', content: '', error: null }
  try {
    const res = await fetch(previewUrl(f))
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    htmlByPath.value[key] = { status: 'ready', content: await res.text(), error: null }
  } catch (e) {
    htmlByPath.value[key] = {
      status: 'error',
      content: '',
      error: e instanceof Error ? e.message : 'fetch failed',
    }
  }
}

/**
 * Build the HTML iframe's `srcdoc` value. Do NOT escape `<`, `>`, `&`,
 * `"` here — Vue's `:srcdoc` binding goes through setAttribute, which
 * encodes them, and the iframe parser decodes them back (same contract
 * as PreviewContentRenderer's html branch). The margin reset keeps
 * unstyled docs flush like the previous direct-navigation render.
 */
function htmlSrcDoc(f: ParsedPresentFile): string {
  const raw = htmlByPath.value[f.path]?.content ?? ''
  return `<style>html,body{margin:0;padding:0;background:#fff;}</style>${raw}`
}

interface PdfState {
  status: 'loading' | 'ready' | 'error' | 'skipped'
  url: string | null
  error: string | null
}

const pdfByPath = ref<Record<string, PdfState>>({})

async function fetchPdfFor(f: ParsedPresentFile): Promise<void> {
  const key = f.path
  if (pdfByPath.value[key]) return
  if (!isPdf(f)) return
  if (f.bytes > MAX_INLINE_PDF_BYTES) {
    pdfByPath.value[key] = { status: 'skipped', url: null, error: null }
    return
  }
  pdfByPath.value[key] = { status: 'loading', url: null, error: null }
  try {
    const res = await fetch(previewUrl(f))
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const blob = await res.blob()
    const url = URL.createObjectURL(blob)
    pdfByPath.value[key] = { status: 'ready', url, error: null }
  } catch (e) {
    pdfByPath.value[key] = {
      status: 'error',
      url: null,
      error: e instanceof Error ? e.message : 'fetch failed',
    }
  }
}

onUnmounted(() => {
  for (const key of Object.keys(pdfByPath.value)) {
    const url = pdfByPath.value[key]?.url
    if (url) {
      try {
        URL.revokeObjectURL(url)
      } catch {
        // ignore — test doubles / already-revoked URLs
      }
    }
  }
})

function maybeFetchVisibleTexts(): void {
  if (!isExpanded.value) return
  for (const f of files.value) {
    if (isTextLike(f)) void fetchTextFor(f)
    else if (isHtml(f)) void fetchHtmlFor(f)
    else if (isPdf(f)) void fetchPdfFor(f)
  }
}

watch([isExpanded, files], () => maybeFetchVisibleTexts(), { immediate: true })

const fileMeta = (f: ParsedPresentFile): string => `${formatBytes(f.bytes)} · ${f.mime}`

const headerPrimary = computed((): string | null => {
  if (parsed.value.error) return null
  const n = files.value.length
  return n === 1 ? (displayName(files.value[0]!) ?? '1 file') : `${n} files`
})

const headerMeta = computed((): string => {
  if (parsed.value.error) return 'Error'
  const n = files.value.length
  return n === 1 ? (fileMeta(files.value[0]!) ?? '') : `${n} files`
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}

const openFullscreen = (f: ParsedPresentFile) => {
  fullscreenSrc.value = previewUrl(f)
}

const closeFullscreen = () => {
  fullscreenSrc.value = null
}

const openInNewTab = (f: ParsedPresentFile) => {
  if (typeof window === 'undefined') return
  try {
    window.open(previewUrl(f), '_blank', 'noopener')
  } catch {
    // ignore — popup blocked
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': !!parsed.error }"
    data-testid="present-files-card"
  >
    <ToolCardHeader
      tool-name="present_files"
      :primary="headerPrimary"
      :success="!parsed.error"
      :expanded="isExpanded"
      :expandable="true"
      :cwd="cwd"
      :right-meta="headerMeta"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div v-if="parsed.error" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <div v-else class="flex flex-col gap-1.5 p-2">
        <div
          v-for="(f, idx) in files"
          :key="`${f.path}-${idx}`"
          class="flex flex-col gap-1.5 rounded-md border border-[var(--color-border)] bg-black/[0.02] px-2 py-1.5 hover:bg-violet-500/5"
          :data-testid="`present-files-row-${idx}`"
        >
          <div class="flex items-center gap-2">
            <!-- Image thumbnail: visible BEFORE download. Click → fullscreen. -->
            <img
              v-if="isImage(f)"
              :src="previewUrl(f)"
              :alt="displayName(f)"
              loading="lazy"
              class="h-16 w-16 shrink-0 rounded object-cover cursor-zoom-in border border-[var(--color-border)]"
              :data-testid="`present-files-thumb-${idx}`"
              @click="openFullscreen(f)"
              @error="(e) => ((e.target as HTMLImageElement).style.display = 'none')"
            />
            <span v-else class="shrink-0 text-base leading-none" aria-hidden="true">📄</span>
            <div class="flex min-w-0 flex-1 flex-col">
              <a
                :href="downloadUrl(f)"
                :download="basenameOfPath(f.path)"
                class="truncate font-semibold text-[var(--semantic-text)] hover:text-violet-500 hover:underline"
                :data-testid="`present-files-download-${idx}`"
                :title="f.path"
                >{{ displayName(f) }}</a
              >
              <span class="truncate text-[var(--semantic-text-dim)]">{{ fileMeta(f) }}</span>
            </div>
            <a
              :href="downloadUrl(f)"
              :download="basenameOfPath(f.path)"
              class="shrink-0 rounded px-1.5 py-0.5 text-sm leading-none hover:bg-violet-500/10"
              :data-testid="`present-files-dlbtn-${idx}`"
              :title="`Download ${basenameOfPath(f.path)}`"
              aria-label="Download file"
              >⬇</a
            >
          </div>

          <!-- Inline preview: image (full-width, click → fullscreen). -->
          <div v-if="isImage(f)" class="flex justify-center rounded bg-black/[0.04] p-1.5">
            <img
              :src="previewUrl(f)"
              :alt="displayName(f)"
              loading="lazy"
              class="max-h-80 w-full cursor-zoom-in rounded object-contain"
              :data-testid="`present-files-inline-image-${idx}`"
              @click="openFullscreen(f)"
              @error="(e) => ((e.target as HTMLImageElement).style.display = 'none')"
            />
          </div>

          <!--
            Inline preview: HTML fetched over same-origin fetch and
            rendered into a sandboxed srcdoc iframe. A direct
            `<iframe src=downloadUrl>` is refused by the server's
            framing headers (X-Frame-Options: DENY + frame-ancestors
            'none') while top-level "Open in new tab" keeps working,
            so navigation is never used here.
          -->
          <div
            v-else-if="isHtml(f)"
            class="max-w-full overflow-hidden rounded border border-[var(--color-border)] bg-white"
            :data-testid="`present-files-inline-html-${idx}`"
          >
            <iframe
              v-if="htmlByPath[f.path]?.status === 'ready'"
              :srcdoc="htmlSrcDoc(f)"
              sandbox="allow-scripts"
              style="height: 480px"
              class="block w-full border-0"
              :title="displayName(f)"
            />
            <div
              v-else
              class="flex items-center justify-center px-2 py-8 text-[var(--semantic-text-dim)]"
            >
              <span v-if="!htmlByPath[f.path] || htmlByPath[f.path]!.status === 'loading'"
                >Loading preview…</span
              >
              <span v-else-if="htmlByPath[f.path]!.status === 'skipped'"
                >File too large for inline HTML preview ({{ fileMeta(f) }}) — open in a new tab to
                view.</span
              >
              <span v-else class="text-red-500"
                >Preview failed to load ({{ htmlByPath[f.path]!.error }}) — open in a new tab to
                view.</span
              >
            </div>
            <div
              class="flex items-center justify-end gap-2 border-t border-[var(--color-border)] bg-black/[0.02] px-2 py-1.5"
            >
              <button
                type="button"
                class="cursor-pointer rounded border border-[var(--color-border)] bg-[var(--semantic-card-bg)] px-2 py-0.5 text-xs text-[var(--semantic-text)] transition-colors hover:bg-[var(--color-violet)]/20 hover:border-[var(--color-violet)]/60 hover:text-[var(--color-violet)]"
                :data-testid="`present-files-open-tab-${idx}`"
                :title="`Open ${displayName(f)} in a new browser tab`"
                @click.stop="openInNewTab(f)"
              >
                ↗ Open in new tab
              </button>
            </div>
          </div>

          <!--
            Inline preview: PDF fetched as a Blob and embedded via an
            object URL (same framing-header reason as html — a direct
            `<iframe src=downloadUrl>` is refused inline).
          -->
          <div
            v-else-if="isPdf(f)"
            class="max-w-full overflow-hidden rounded border border-[var(--color-border)] bg-white"
            :data-testid="`present-files-inline-pdf-${idx}`"
          >
            <iframe
              v-if="pdfByPath[f.path]?.status === 'ready' && pdfByPath[f.path]!.url"
              :src="pdfByPath[f.path]!.url!"
              style="height: 480px"
              class="block w-full border-0"
              :title="displayName(f)"
            />
            <div
              v-else
              class="flex items-center justify-center px-2 py-8 text-[var(--semantic-text-dim)]"
            >
              <span v-if="!pdfByPath[f.path] || pdfByPath[f.path]!.status === 'loading'"
                >Loading preview…</span
              >
              <span v-else-if="pdfByPath[f.path]!.status === 'skipped'"
                >File too large for inline PDF preview ({{ fileMeta(f) }}) — open in a new tab to
                view.</span
              >
              <span v-else class="text-red-500"
                >Preview failed to load ({{ pdfByPath[f.path]!.error }}) — open in a new tab to
                view.</span
              >
            </div>
            <div
              class="flex items-center justify-end gap-2 border-t border-[var(--color-border)] bg-black/[0.02] px-2 py-1.5"
            >
              <button
                type="button"
                class="cursor-pointer rounded border border-[var(--color-border)] bg-[var(--semantic-card-bg)] px-2 py-0.5 text-xs text-[var(--semantic-text)] transition-colors hover:bg-[var(--color-violet)]/20 hover:border-[var(--color-violet)]/60 hover:text-[var(--color-violet)]"
                :data-testid="`present-files-open-tab-${idx}`"
                :title="`Open ${displayName(f)} in a new browser tab`"
                @click.stop="openInNewTab(f)"
              >
                ↗ Open in new tab
              </button>
            </div>
          </div>

          <!-- Inline preview: native video / audio players. -->
          <div v-else-if="isVideo(f)" :data-testid="`present-files-inline-video-${idx}`">
            <video
              controls
              :src="previewUrl(f)"
              class="max-h-96 w-full rounded bg-black"
              preload="metadata"
            />
          </div>
          <div v-else-if="isAudio(f)" :data-testid="`present-files-inline-audio-${idx}`">
            <audio controls :src="previewUrl(f)" class="w-full" preload="metadata" />
          </div>

          <!-- Inline preview: fetched text source via the shared renderer. -->
          <div v-else-if="isTextLike(f)" :data-testid="`present-files-inline-text-${idx}`">
            <div
              v-if="!textByPath[f.path] || textByPath[f.path]!.status === 'loading'"
              class="px-1 py-2 text-[var(--semantic-text-dim)]"
            >
              Loading preview…
            </div>
            <div
              v-else-if="textByPath[f.path]!.status === 'skipped'"
              class="px-1 py-2 text-[var(--semantic-text-dim)]"
            >
              File too large for inline text preview ({{ fileMeta(f) }}) — download to view.
            </div>
            <div v-else-if="textByPath[f.path]!.status === 'error'" class="px-1 py-2 text-red-500">
              Preview failed to load ({{ textByPath[f.path]!.error }}) — download to view.
            </div>
            <div v-else class="overflow-hidden rounded border border-[var(--color-border)]">
              <PreviewContentRenderer
                :content-type="textRendererType(f)"
                :args="{ content: textByPath[f.path]!.content, language: textLanguage(f) }"
                variant="inline"
              />
              <div
                v-if="textByPath[f.path]!.truncated"
                class="border-t border-[var(--color-border)] bg-black/[0.02] px-2 py-1 text-[var(--semantic-text-dim)]"
              >
                Truncated for inline display — download for the full file.
              </div>
            </div>
          </div>
        </div>
        <div v-if="files.length === 0" class="px-1 py-0.5 text-[var(--semantic-text-dim)]">
          (no files)
        </div>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>

    <ImagePreview :src="fullscreenSrc ?? ''" @close="closeFullscreen" />
  </div>
</template>
