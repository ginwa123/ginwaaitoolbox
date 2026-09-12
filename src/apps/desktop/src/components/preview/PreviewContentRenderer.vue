<!--
  PreviewContentRenderer — shared renderer for the rich content of
  a single `show_preview` agent tool output.

  Renders the rich content of a single `show_preview` agent tool
  output inline inside the chat bubble (used by ShowPreview).
  Supports 5 content types (markdown / text / code / image / html)
  without copy-paste drift.

  HTML previews render in a sandboxed iframe that auto-sizes to fit
  content height, plus an "Open in new tab" button
  (data-testid="preview-open-new-tab-button") that opens the HTML
  in a new browser tab via a Blob URL — letting the user see the
  full-width page when the inline view truncates.

  Props:
    - `contentType`: one of 'markdown' | 'text' | 'code' | 'image' | 'html'.
    - `args`: object with `content`, `title`, `caption`, `language` fields.
      `content` is the raw payload. `title` renders above. `caption`
      renders below. `language` is required for `code` (matches the
      schema in show_preview.zig).
    - `variant` (default 'inline'): kept for backward compat, only
      `'inline'` layout is used (compact chat-bubble layout).

  Branch table:

    | content_type  | Render path                                |
    |---------------|---------------------------------------------|
    | markdown      | marked.parse(c) → v-html                    |
    | text          | <pre class="whitespace-pre-wrap"> + escaped |
    | code          | <pre><code class="language-X"> + escaped    |
    | image         | <img :src="data:/http URL only">            |
    | html          | <iframe sandbox="allow-scripts" srcdoc=...> +  |
    |               | (inline only) "Open full preview" → button  |
    | (anything else) | empty container (defensive)              |

  Security note for the `html` branch:
    - iframe gets a NULL origin (no allow-same-origin), so its JS
      cannot read the parent app's cookies, localStorage, or window.
    - no allow-forms (forms render but cannot submit).
    - no allow-top-navigation (window.open blocked).
    This matches the existing DesignElementPreview.vue pattern.

-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { marked } from 'marked'

export interface PreviewArgs {
  content?: string
  title?: string
  language?: string
  caption?: string
}

const props = withDefaults(
  defineProps<{
    contentType: 'markdown' | 'text' | 'code' | 'image' | 'html'
    args: PreviewArgs
    /**
     * Layout variant (kept for backward compat). Only `'inline'`
     * is used — compact chat-bubble layout that auto-resizes to fit
     * the iframe's content height, plus an "Open in new tab" button
     * for HTML content.
     */
    variant?: 'side' | 'inline'
  }>(),
  { variant: 'inline' },
)

const isInline = computed(() => true)

// ─── Iframe ref + auto-resize message handling ──────────────────────
//
// The inline iframe auto-sizes to fit its content via a tiny postMessage
// protocol: a script inside the iframe reports its scrollHeight to the
// parent, which clamps the value (200px ≤ h ≤ 2000px) and sets
// `iframe.style.height`. This way the user sees the full HTML inline
// without a scrollbar.
//
// Why 200px min: empty/short content shouldn't collapse the iframe to
// zero (the surrounding bubble has visible borders).
// Why 2000px max: runaway content (huge dashboards, infinite-scroll pages)
// must not break the chat layout — the user clicks "Open full" for that.

const iframeRef = ref<HTMLIFrameElement | null>(null)
const MIN_IFRAME_HEIGHT = 200
const MAX_IFRAME_HEIGHT = 2000

function onIframeMessage(e: MessageEvent) {
  // Filter by source — only messages from our own auto-resize script.
  if (
    !e.data ||
    typeof e.data !== 'object' ||
    e.data.source !== 'show-preview-auto-resize' ||
    typeof e.data.height !== 'number'
  ) {
    return
  }
  const iframe = iframeRef.value
  if (!iframe) return
  const clampedH = Math.max(MIN_IFRAME_HEIGHT, Math.min(MAX_IFRAME_HEIGHT, e.data.height))
  iframe.style.height = `${clampedH}px`
}



onMounted(() => {
  if (typeof window !== 'undefined') {
    window.addEventListener('message', onIframeMessage)
  }
})

onUnmounted(() => {
  if (typeof window !== 'undefined') {
    window.removeEventListener('message', onIframeMessage)
  }
})

// ─── Auto-resize script (prepended to the iframe srcdoc) ────────────
//
// This script is injected at the start of the iframe's srcdoc so it runs
// at parse time. It measures the iframe's content scrollHeight and
// posts it back to the parent on every layout change (load, resize,
// DOM mutation). The parent's `onIframeMessage` updates `iframe.style.height`
// to match.
//
// Security note: the iframe has `sandbox="allow-scripts"`. The script
// runs in a NULL-origin context (no cookies, no localStorage, no parent
// DOM access). It only does `parent.postMessage(...)` — no network, no
// eval, no escape. The parent only adjusts `iframe.style.height` — no
// other side effects. The protocol is safe.
const AUTO_RESIZE_SCRIPT = `<script>(function(){
var REPORT_SOURCE = 'show-preview-auto-resize';
function report(){
  try {
    var de = document.documentElement;
    var body = document.body;
    var h = Math.max(
      de ? de.scrollHeight : 0,
      body ? body.scrollHeight : 0,
      de ? de.offsetHeight : 0,
      body ? body.offsetHeight : 0
    );
    // 2026-08-29: also report scrollWidth so the parent can show a
    // hint when the preview content is wider than the chat column.
    var w = Math.max(
      de ? de.scrollWidth : 0,
      body ? body.scrollWidth : 0,
      de ? de.offsetWidth : 0,
      body ? body.offsetWidth : 0
    );
    parent.postMessage({ source: REPORT_SOURCE, height: h, width: w }, '*');
  } catch(e) {}
}
function init(){
  report();
  window.addEventListener('load', report);
  window.addEventListener('resize', report);
  if (document.body && typeof MutationObserver !== 'undefined') {
    try {
      new MutationObserver(report).observe(document.body, { childList: true, subtree: true });
    } catch(e) {}
  }
}
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
})();<` + `/script>`

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

// markdown / text / code branch (consumed via v-html). The other
// branches (`image`, `html`) render via dedicated elements below
// — the v-html string is empty for them so we don't double-render.
const renderedContent = computed<string>(() => {
  const ct = props.contentType
  const c = props.args.content ?? ''
  if (ct === 'markdown') {
    try {
      return marked.parse(c, { async: false }) as string
    } catch {
      return `<pre>${escapeHtml(c)}</pre>`
    }
  }
  if (ct === 'text') {
    return `<pre class="whitespace-pre-wrap break-all">${escapeHtml(c)}</pre>`
  }
  if (ct === 'code') {
    const lang = props.args.language ?? 'plaintext'
    return `<pre><code class="language-${escapeHtml(lang)}">${escapeHtml(c)}</code></pre>`
  }
  // 'image' and 'html' render via dedicated template branches.
  return ''
})

// XSS guard for image: only data: URLs and http(s) URLs are allowed.
// Other payloads (e.g. javascript:) silently render nothing — the
// underlying `imageSrc` computed returns null in that case.
const imageSrc = computed<string | null>(() => {
  if (props.contentType !== 'image') return null
  const c = props.args.content ?? ''
  if (c.startsWith('data:') || c.startsWith('http://') || c.startsWith('https://')) {
    return c
  }
  return null
})

/**
 * Build the iframe's `srcdoc` value from the user HTML.
 *
 * CRITICAL: do NOT manually escape `<`, `>`, `&`, `"` here. The browser's
 * `setAttribute('srcdoc', value)` path automatically encodes those four
 * characters for the attribute value, then the iframe's own parser
 * decodes them back when loading the document. Manually escaping here
 * produces DOUBLE-escaped HTML.
 *
 * Vue's reactive `:srcdoc` binding calls setAttribute for us.
 *
 * Also wraps the HTML in:
 *   1. A tiny `<style>` reset so the preview doesn't get a default-
 *      margin surprise from the browser body.
 *   2. The AUTO_RESIZE_SCRIPT (prepended BEFORE the user's HTML) which
 *      sets up the postMessage protocol that makes the iframe auto-size
 *      to fit its content height. Follows the sandboxed-iframe pattern.
 */
const htmlSrcDoc = computed<string | null>(() => {
  if (props.contentType !== 'html') return null
  const raw = props.args.content ?? ''
  return `${AUTO_RESIZE_SCRIPT}<style>html,body{margin:0;padding:0;background:#fff;}</style>${raw}`
})

// ─── Open in new tab ───────────────────────────────────────────────
//
// HTML previews offer an "Open in new tab" action that builds a Blob
// URL from the raw HTML and opens it via window.open. The iframe
// stays sandboxed (NULL origin); the new tab gets the full viewport
// width for wide content.
function openInNewTab() {
  if (typeof window === 'undefined' || typeof URL === 'undefined') return
  try {
    const raw = props.args.content ?? ''
    const blob = new Blob([raw], { type: 'text/html' })
    const url = URL.createObjectURL(blob)
    window.open(url, '_blank', 'noopener')
    // Revoke after a delay so the new tab has time to load.
    window.setTimeout(() => {
      try { URL.revokeObjectURL(url) } catch { /* ignore */ }
    }, 60_000)
  } catch { /* ignore — popup blocked or blob unsupported */ }
}
</script>

<template>
  <div class="preview-content-renderer">
    <div
      v-if="args.title"
      class="text-sm font-semibold text-[var(--semantic-text)] mb-2 pb-2 border-b border-dashed border-[var(--color-border)]"
    >
      {{ args.title }}
      <span
        v-if="args.language && contentType === 'code'"
        class="ml-2 text-xs text-[var(--semantic-text-muted)] font-normal"
      >[{{ args.language }}]</span>
    </div>

    <div
      v-if="contentType === 'image'"
      class="flex justify-center bg-black/[0.04] p-2 rounded"
    >
      <img
        v-if="imageSrc"
        :src="imageSrc"
        :alt="args.title || args.caption || 'Preview image'"
        class="max-w-full max-h-96 object-contain"
        @error="(e) => { (e.target as HTMLImageElement).style.display = 'none' }"
      />
      <div v-else class="text-xs text-red-500 italic">
        Image source invalid (expected data: URL or http(s) URL)
      </div>
    </div>

    <!--
      HTML iframe container — auto-sized via the postMessage protocol
      in AUTO_RESIZE_SCRIPT (see <script setup>). The script reports
      the iframe's content height to the parent, which sets
      `iframe.style.height` accordingly (clamped 200-2000px).
      The action row below the iframe offers "Open in new tab" for
      full-width viewing.
    -->
    <div
      v-else-if="contentType === 'html' && htmlSrcDoc"
      data-testid="preview-html-container"
      class="max-w-full rounded overflow-hidden border border-[var(--color-border)] bg-white"
    >
      <iframe
        ref="iframeRef"
        sandbox="allow-scripts"
        :srcdoc="htmlSrcDoc"
        style="min-height: 200px"
        class="w-full border-0 block"
        :title="args.title || 'HTML preview'"
        data-testid="preview-html-iframe"
      />
      <div class="flex items-center justify-end gap-2 px-2 py-1.5 border-t border-[var(--color-border)] bg-black/[0.02]">
        <button
          type="button"
          class="px-2 py-0.5 rounded border border-[var(--color-border)] bg-[var(--semantic-card-bg)] hover:bg-[var(--color-violet)]/20 hover:border-[var(--color-violet)]/60 hover:text-[var(--color-violet)] text-[var(--semantic-text)] text-xs cursor-pointer transition-colors"
          data-testid="preview-open-new-tab-button"
          title="Open HTML preview in a new browser tab"
          @click.stop="openInNewTab"
        >↗ Open in new tab</button>
      </div>
    </div>

    <!--
      Markdown / text / code / image content (non-html) flow through
      the v-else branch below.
    -->
    <div
      v-else
      class="text-xs text-[var(--semantic-text)] markdown-content"
      v-html="renderedContent"
    />

    <div
      v-if="args.caption"
      class="mt-2 pt-2 text-xs italic text-[var(--semantic-text-muted)] border-t border-dashed border-[var(--color-border)]"
    >
      {{ args.caption }}
    </div>
  </div>
</template>

<style scoped>
.markdown-content :deep(pre) {
  background: var(--color-code-bg, rgba(0, 0, 0, 0.05));
  padding: 0.5rem;
  border-radius: 0.25rem;
  overflow-x: auto;
}
.markdown-content :deep(code) {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.75rem;
}
.markdown-content :deep(h1) {
  font-size: 1.25rem;
  font-weight: 700;
  margin: 0.5rem 0;
}
.markdown-content :deep(h2) {
  font-size: 1.1rem;
  font-weight: 600;
  margin: 0.4rem 0;
}
.markdown-content :deep(h3) {
  font-size: 1rem;
  font-weight: 600;
  margin: 0.3rem 0;
}
.markdown-content :deep(p) {
  margin: 0.25rem 0;
  line-height: 1.4;
}
.markdown-content :deep(ul),
.markdown-content :deep(ol) {
  margin: 0.25rem 0 0.25rem 1.5rem;
}
.markdown-content :deep(a) {
  color: var(--color-violet);
  text-decoration: underline;
}
.markdown-content :deep(table) {
  border-collapse: collapse;
  margin: 0.5rem 0;
}
.markdown-content :deep(th),
.markdown-content :deep(td) {
  border: 1px solid var(--color-border);
  padding: 0.25rem 0.5rem;
}
</style>
