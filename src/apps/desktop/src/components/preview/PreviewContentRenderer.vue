<!--
  PreviewContentRenderer — shared renderer for the rich content of
  a single `show_preview` agent tool output.

  This component was extracted from PreviewSidePanel.vue (2026-08-06)
  so that BOTH PreviewSidePanel (right-side panel) AND ShowPreview
  (per-message chat bubble, in inline mode) can render the same
  5-branch content (markdown / text / code / image / html) without
  copy-paste drift.

  Two consumers:
    1. <PreviewSidePanel> — passes `variant="side"` (the default).
       Full-width 480px column with a tall iframe (min-h-480px).
    2. <ShowPreview> — passes `variant="inline"` when the user has
       flipped the display mode to 'inline'. The chat bubble gets a
       shorter max-h-[320px] iframe + an "Open full preview" button
       (data-testid="preview-open-full-button") that opens the
       HTML in a new browser tab via a Blob URL — letting the user
       see the full-width page when the inline view truncates.

  Props:
    - `contentType`: one of 'markdown' | 'text' | 'code' | 'image' | 'html'.
    - `args`: object with `content`, `title`, `caption`, `language` fields.
      `content` is the raw payload. `title` renders above. `caption`
      renders below. `language` is required for `code` (matches the
      schema in show_preview.zig).
    - `variant` (default 'side'): `'side'` for the full-width panel,
      `'inline'` for the compact chat-bubble layout.

  Branch table (mirrors PreviewSidePanel.vue:199-244 + 334-347):

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

  Plan: docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md
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
     * `'side'` (default) — full-width panel layout, 480px-tall iframe.
     * `'inline'` — compact chat-bubble layout that auto-resizes to fit
     * the iframe's content height (via a tiny postMessage protocol —
     * no scrollbar, no fixed cap), plus an "Open full preview" button
     * that opens the HTML in a new tab via Blob URL for the
     * long-content case.
     */
    variant?: 'side' | 'inline'
  }>(),
  { variant: 'side' },
)

// 2026-08-29: emit `'open-in-side-panel'` when the CTA-strip "Open in
// side panel" button is clicked. ShowPreview.vue listens for this event
// and re-emits the existing `'open'` event so ChatView.vue's
// `openPreviewForMessage` handler is unchanged — the new event is just
// a parallel path to the same handler. We use a distinct event name
// (rather than reusing `'open'`) so a future caller can distinguish
// "open in new tab" from "open in side panel" if needed.
const emit = defineEmits<{
  'open-in-side-panel': []
}>()

const isInline = computed(() => props.variant === 'inline')

// ─── Iframe ref + auto-size message handling ────────────────────────
//
// The inline iframe auto-sizes to fit its content via a tiny postMessage
// protocol: a script inside the iframe reports its scrollHeight +
// scrollWidth to the parent. The parent clamps the height
// (200px ≤ h ≤ 2000px) and clamps the width (IFRAME_MIN_WIDTH ≤ w ≤
// IFRAME_MAX_WIDTH) and sets iframe.style.height + iframe.style.width
// accordingly. Result: the iframe renders at its content's natural
// size (height AND width), even when that's wider than the chat column.
// The iframe container has overflow-x: auto so the user can scroll
// horizontally within the card to see the full content.
//
// Why IFRAME_MIN_WIDTH 320: too-narrow content should still fill the
// chat column (looks weird if a tiny preview is e.g. 100px wide and
// sits in a corner of the bubble).
// Why IFRAME_MAX_WIDTH 1600: cap to prevent runaway widths (an
// infinite-width page would otherwise blow up the horizontal scroll
// bar). 1600px covers 4K dashboard mocks with room to spare.
const iframeRef = ref<HTMLIFrameElement | null>(null)
const MIN_IFRAME_HEIGHT = 200
const MAX_IFRAME_HEIGHT = 2000
const IFRAME_MIN_WIDTH = 320
const IFRAME_MAX_WIDTH = 1600

// 2026-08-29 (followup #3): the iframe now renders at its CONTENT's
// natural width (reported via postMessage), not the chat-column width.
// The iframe-container has overflow-x: auto so when the iframe is wider
// than the chat column, the user gets a horizontal scrollbar on the
// container to swipe through the full content inline. No more cropping.
// `reportedContentWidth` is the Vue-tracked width (clamped, in px);
// `iframeStyle` is the computed inline-style binding for the <iframe>.
// We set both the Vue ref AND the iframe's style directly so the style
// applies on the very first message — Vue's next-tick might race the
// initial layout.
const reportedContentWidth = ref<number | null>(null)
const iframeStyle = computed<Record<string, string>>(() => {
  const style: Record<string, string> = { 'min-height': `${MIN_IFRAME_HEIGHT}px` }
  if (reportedContentWidth.value !== null) {
    style.width = `${reportedContentWidth.value}px`
  }
  return style
})

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
  // 2026-08-29: also drive iframe WIDTH from the reported scrollWidth.
  // Older srcdocs that don't post `width` are handled by the
  // `typeof e.data.width === 'number'` gate below — the existing
  // auto-resize tests dispatch `{source, height}` only and stay green.
  if (typeof e.data.width === 'number') {
    const clampedW = Math.max(IFRAME_MIN_WIDTH, Math.min(IFRAME_MAX_WIDTH, e.data.width))
    if (reportedContentWidth.value !== clampedW) {
      reportedContentWidth.value = clampedW
    }
    iframe.style.width = `${clampedW}px`
  }
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
 *      to fit its content height. Mirrors the existing
 *      PreviewSidePanel pattern.
 */
const htmlSrcDoc = computed<string | null>(() => {
  if (props.contentType !== 'html') return null
  const raw = props.args.content ?? ''
  return `${AUTO_RESIZE_SCRIPT}<style>html,body{margin:0;padding:0;background:#fff;}</style>${raw}`
})

// ─── Open in side panel (inline CTA strip) ─────────────────────────
//
// 2026-08-29: the inline CTA strip below the iframe emits
// `'open-in-side-panel'` when clicked. ShowPreview.vue listens and
// re-emits the existing `'open'` event with the message id, so
// ChatView.vue's `openPreviewForMessage` handler is unchanged.
//
// We replaced the old "open in new tab" behaviour (which built a Blob
// URL + window.open) with this side-panel emit. Reasoning: the side
// panel is one click away, the user stays in the chat, and the panel
// is now the DEFAULT destination for show_preview — so routing the
// inline-fallback click back to the panel matches user mental model.
// The Blob-URL-in-new-tab path is no longer reachable from the UI but
// the helper could be re-introduced if a future caller needs it.
function emitOpenInSidePanel() {
  emit('open-in-side-panel')
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
      HTML iframe container sizing:
        side: min-h-480px, fills the parent panel (the panel is resizable up to full viewport).
        inline: auto-sized via the postMessage protocol in AUTO_RESIZE_SCRIPT (see <script setup>).
                 The script reports BOTH scrollHeight AND scrollWidth; the parent clamps height
                 (200-2000px) and width (320-1600px) and sets iframe.style.{height,width}
                 accordingly. The iframe renders at its CONTENT NATURAL width.

                 2026-08-29 followup #4 (user feedback after natural-width landed):
                 user said "cannot strect like yellow line?" — referring to the
                 chat bubble's top edge that spans the full window. The
                 iframe was still clipped to the chat column (~750px).
                 The iframe-container uses the `breakout-full-viewport`
                 utility (scoped style below) to escape ALL parent
                 padding — chat column margins, inline content `px-3`
                 padding, everything — and span the full viewport. The
                 iframe is at its content width (clamped 320-1600px) with
                 `max-w-full` so it caps at the viewport; container has
                 `overflow-x: auto` so users scroll horizontally if the
                 content exceeds the viewport.
    -->

    <div
      v-else-if="contentType === 'html' && htmlSrcDoc"
      data-testid="preview-html-container"
      :class="isInline
        ? 'breakout-full-viewport rounded overflow-x-auto overflow-y-hidden border border-[var(--color-border)] bg-white'
        : 'h-full min-h-[480px] rounded overflow-hidden border border-[var(--color-border)] bg-white'"
    >
      <iframe
        ref="iframeRef"
        sandbox="allow-scripts"
        :srcdoc="htmlSrcDoc"
        :style="isInline ? iframeStyle : ''"
        :class="isInline
          ? 'block max-w-full border-0'
          : 'w-full h-full min-h-[480px] border-0 block'"
        :title="args.title || 'HTML preview'"
        data-testid="preview-html-iframe"
      />
    </div>

    <!--
      Inline CTA strip (2026-08-29) — lives BELOW the iframe container
      so it can't overlap the iframe's content. The "↗ Open in side
      panel" button emits `open-in-side-panel` (ShowPreview.vue
      re-emits as `open` so ChatView.vue's handler is unchanged) — this
      is the MANUAL escape hatch for users who prefer the side panel
      layout even when inline works. The strip is hidden in side
      variant (the panel already shows the content full-width,
      redundant).
    -->
    <div
      v-if="isInline && contentType === 'html'"
      class="flex items-center justify-end gap-2 mt-1 text-[0.65rem] font-mono text-[var(--semantic-text-muted)]"
      data-testid="preview-inline-cta"
    >
      <button
        type="button"
        class="px-2 py-1 rounded border border-[var(--color-border)] bg-[var(--semantic-card-bg)] hover:bg-[var(--color-violet)]/20 hover:border-[var(--color-violet)]/60 hover:text-[var(--color-violet)] text-[var(--semantic-text)] cursor-pointer transition-colors"
        data-testid="preview-open-full-button"
        title="Open this preview in the side panel at full width"
        @click.stop="emitOpenInSidePanel"
      >↗ Open in side panel</button>
    </div>

    <!--
      Markdown / text / code / image content (non-html) flow through
      the v-else branch below — never had the iframe problem to begin
      with.
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
/*
 * breakout-full-viewport — 2026-08-29 followup #4.
 *
 * Inline HTML previews use this class on the iframe-container so the
 * iframe escapes ALL parent padding (chat column margins, inline
 * content `px-3` padding, etc.) and spans the FULL viewport width.
 * Why: `show_preview` content is typically designed for ~1200-1600px
 * wide displays; the chat column is only ~750px wide; the iframe was
 * being clipped to the chat column. User feedback: "cannot strect
 * like yellow line?" — referring to the chat bubble's top edge (which
 * spans the full window). Now the iframe stretches that wide too.
 *
 * The classic CSS trick: set width to 100vw, then use a negative
 * `margin-left` of half-the-difference to center the element on the
 * viewport regardless of how deeply nested the element is.
 *
 * `position: relative` is defensive — some ancestor might have
 * `overflow: hidden` (e.g. the chat column) which would clip the
 * breakout; we can't always fix that without invasive layout changes,
 * so this is the best-effort approach.
 */
.breakout-full-viewport {
  width: 100vw;
  margin-left: calc(50% - 50vw);
  margin-right: calc(50% - 50vw);
  position: relative;
}

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
