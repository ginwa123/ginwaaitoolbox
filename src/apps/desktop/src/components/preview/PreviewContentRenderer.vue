<!--
  PreviewContentRenderer — shared renderer for the rich content of
  a single `show_preview` agent tool output.

  This component was extracted from PreviewSidePanel.vue (2026-08-06)
  so that BOTH PreviewSidePanel (right-side panel) AND ShowPreview
  (per-message chat bubble, in inline mode) can render the same
  5-branch content (markdown / text / code / image / html) without
  copy-paste drift.

  Two consumers:
    1. <PreviewSidePanel> — passes the active preview's
       `contentType` (extracted from the response envelope) and
       `args` (extracted from the <parameters> tag via
       tryUnwrapToolOutput).
    2. <ShowPreview> — in `inline` mode, passes the same shape so
       the rich content renders inside the chat bubble.

  Props:
    - `contentType`: one of 'markdown' | 'text' | 'code' | 'image' | 'html'.
    - `args`: object with `content`, `title`, `caption`, `language` fields.
      `content` is the raw payload. `title` renders above. `caption`
      renders below. `language` is required for `code` (matches the
      schema in show_preview.zig).

  Branch table (mirrors PreviewSidePanel.vue:199-244 + 334-347):

    | content_type  | Render path                                |
    |---------------|---------------------------------------------|
    | markdown      | marked.parse(c) → v-html                    |
    | text          | <pre class="whitespace-pre-wrap"> + escaped |
    | code          | <pre><code class="language-X"> + escaped    |
    | image         | <img :src="data:/http URL only">            |
    | html          | <iframe sandbox="allow-scripts" srcdoc=...> |
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
import { computed } from 'vue'
import { marked } from 'marked'

export interface PreviewArgs {
  content?: string
  title?: string
  language?: string
  caption?: string
}

const props = defineProps<{
  contentType: 'markdown' | 'text' | 'code' | 'image' | 'html'
  args: PreviewArgs
}>()

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
 * Also wraps the HTML in a tiny `<style>` reset so the preview doesn't
 * get a default-margin surprise from the browser body. Mirrors the
 * existing PreviewSidePanel pattern.
 */
const htmlSrcDoc = computed<string | null>(() => {
  if (props.contentType !== 'html') return null
  const raw = props.args.content ?? ''
  return `<style>html,body{margin:0;padding:0;background:#fff;}</style>${raw}`
})
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

    <div
      v-else-if="contentType === 'html' && htmlSrcDoc"
      class="h-full min-h-[480px] rounded overflow-hidden border border-[var(--color-border)] bg-white"
    >
      <iframe
        sandbox="allow-scripts"
        :srcdoc="htmlSrcDoc"
        class="w-full h-full min-h-[480px] border-0 block"
        :title="args.title || 'HTML preview'"
        data-testid="preview-html-iframe"
      />
    </div>

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
