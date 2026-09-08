<!--
  ShowPreview — tool output component for the `show_preview` agent tool.

  Renders the XML envelope produced by `executeShowPreviewToString` in
  `src/modules/agent/tools/show_preview.zig`. The component is purely
  presentational: no API calls, no store mutations, no panel control —
  the parent (ChatView.vue) handles the side-panel navigation on click.

  Two response shapes are possible:
    Success:
      <show_preview>
        <status>shown</status>
        <preview_id>pv_1782850123456_a8b3c2</preview_id>
        <content_type>markdown</content_type>
        <content_length>NN</content_length>
      </show_preview>
    Error:
      <show_preview>
        <error>invalid content_type 'foo'. Must be one of: ...</error>
      </show_preview>

  Header (always visible):
    `show_preview → <title | content_type> · <content_length> ✓` (success)
    `show_preview → <error_message> ✗`                       (failure)

  Style is consistent with the rest of the tool_outputs components
  (KanbanMove, UpdateActivity): monospace, rounded-md, border + soft
  card bg, violet tool-name, ✗/✓ status indicators.

  Click behavior — INTENTIONAL DIFFERENCE from the other tool cards:
  ShowPreview is NOT expandable. The whole point of the side panel is
  to keep the chat bubble minimal (status, preview id, content_type,
  length) and let the user inspect the rich content in the right-side
  panel. A click on the bubble here does THREE things (handled by the
  parent):
    1. Opens / un-dismisses the preview side panel.
    2. Un-collapses the panel.
    3. Jumps the panel to the matching preview tab via the `focusId` prop.
  We emit an `open` event with the message id; the parent decides what
  to do. The card itself has no expand toggle — the user's mental
  model is "the bubble is just a bookmark; the panel is the content."

  Parameters prop — OPTIONAL:
  When provided, the component reads `title` and `content_type` from
  the JSON-stringified tool-call arguments and renders the title
  above the content_type for at-a-glance context. Falls back to the
  value extracted from the response envelope (which is authoritative
  for success) when the parameter title is absent.
-->
<script setup lang="ts">
import { computed } from 'vue'
import { usePreviewDisplayMode } from '@/composables/usePreviewDisplayMode'
import PreviewContentRenderer from '@/components/preview/PreviewContentRenderer.vue'
import { extractPreviewArgs, type PreviewArgs } from '@/helpers/previewArgs'
import ToolParameters from './_shared/ToolParameters.vue'

interface Props {
  /** The XML envelope produced by the show_preview tool. */
  content: string
  /**
   * The message id (passed back to the parent on click). The parent
   * uses this to focus the matching preview in the side panel.
   */
  messageId: string
  /**
   * OPTIONAL — the inner content of the show_preview tool's
   * `<parameters>...</parameters>` tag (as returned by
   * `tryUnwrapToolOutput(msg.content)?.parameters`). In production
   * this is XML-shaped (e.g. `<content_type>html</content_type>
   * <content>...</content>`); in legacy raw-JSON rows it's a JSON
   * string. Both shapes are accepted via `extractPreviewArgs`.
   * Default: empty string.
   */
  parameters?: string
}

const props = withDefaults(defineProps<Props>(), {
  parameters: '',
})

const emit = defineEmits<{
  /**
   * Fired when the user clicks the card (anywhere on it, not just a
   * specific button). Parent should navigate to / focus the side
   * panel for `messageId`.
   *
   * NOT emitted in `inline` mode — the rich content is already
   * visible inline, so there's nothing to navigate to.
   */
  open: [string]
}>()

// ─── XML tag extraction (local helper) ───────────────────────────────────
// Same regex-based extractor used in PreviewSidePanel.vue. Kept
// inline so ShowPreview has zero cross-file coupling (project convention
// for tool-output components — see KanbanMove.vue:47-82).
//
// Used to extract fields from the `content` prop (the INNER envelope,
// `<show_preview>...</show_preview>`), which is ALWAYS XML — never JSON.
// Don't try to JSON.parse this; it always starts with `<show_preview>`.

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

// ─── Response envelope parsers ────────────────────────────────────────────

const previewId = computed(() => {
  const v = findTag(props.content, 'preview_id')
  return v?.trim() || null
})

const status = computed(() => {
  const v = findTag(props.content, 'status')
  return v?.trim() || null
})

const contentLength = computed(() => {
  const v = findTag(props.content, 'content_length')
  if (!v) return null
  const n = Number.parseInt(v.trim(), 10)
  return Number.isFinite(n) ? n : null
})

const errorMessage = computed(() => {
  const v = findTag(props.content, 'error')
  return v?.trim() || null
})

// ─── Inline-mode rendering (2026-08-06) ──────────────────────────────────
//
// Args extracted from the `parameters` prop via the shared
// `extractPreviewArgs` helper (helpers/previewArgs.ts). The helper
// tries XML extraction first (current backend — `jsonArgsToXml`)
// then falls back to JSON.parse (legacy raw-JSON rows).
//
// Bug fix (2026-08-06): the previous code did `JSON.parse(props.parameters)`
// directly, which threw SyntaxError on the XML shape (current production
// data) and silently fell through to `{}` — so the iframe was blank
// while the same preview in the side panel rendered correctly. Both
// renderers now go through the same helper.

const { isInline } = usePreviewDisplayMode()

const previewArgs = computed<PreviewArgs>(() => extractPreviewArgs(props.parameters))

const contentTypeFromParams = computed(() => previewArgs.value.content_type ?? null)
const titleFromParams = computed(() => previewArgs.value.title ?? null)

// Prefer the response envelope's `<content_type>` for the header meta
// (it's the canonical value the side panel renders), but fall back to
// the parameter value if the response envelope omits it. This matches
// the pre-fix behaviour but reads both sources through the new helper.
const contentType = computed(() => {
  const fromEnvelope = findTag(props.content, 'content_type')?.trim()
  if (fromEnvelope) return fromEnvelope
  return contentTypeFromParams.value
})

const title = computed(() => {
  // Prefer parameter title when present.
  return titleFromParams.value
})

const resolvedContentType = computed<
  'markdown' | 'text' | 'code' | 'image' | 'html' | null
>(() => {
  const ct = previewArgs.value.content_type ?? contentType.value ?? null
  if (
    ct === 'markdown' ||
    ct === 'text' ||
    ct === 'code' ||
    ct === 'image' ||
    ct === 'html'
  ) {
    return ct
  }
  return null
})

const rendererArgs = computed(() => ({
  content: previewArgs.value.content ?? '',
  title: previewArgs.value.title ?? title.value ?? undefined,
  language: previewArgs.value.language ?? undefined,
  caption: previewArgs.value.caption ?? undefined,
}))

// ─── Derived display values ──────────────────────────────────────────────

const isSuccess = computed(
  () => errorMessage.value === null && status.value === 'shown',
)

const statusIndicator = computed(() => (isSuccess.value ? '✓' : '✗'))

// Human-friendly content_length: show in B / KB / MB so the user can
// glance and see "this is a 200 KB image" vs "this is a 4 KB snippet".
function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(2)} MB`
}

const headerLabel = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? 'error'
  // Prefer the parameter title when present (it's what the LLM chose
  // to label the preview with), otherwise fall back to the content_type.
  const label = title.value ?? contentType.value ?? 'preview'
  return label
})

// Right-meta text — content_type + size, dim gray, only on success.
const rightMeta = computed(() => {
  if (!isSuccess.value) return null
  const parts: string[] = []
  if (contentType.value && title.value) {
    // Title is shown as primary, so repeat the content_type here for
    // disambiguation (a "Plan" might be markdown OR text).
    parts.push(contentType.value)
  }
  if (contentLength.value !== null) {
    parts.push(formatBytes(contentLength.value))
  }
  return parts.length > 0 ? parts.join(' · ') : null
})

const headerTitle = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? ''
  // Hover title shows the canonical preview_id for power users to copy.
  return previewId.value ? `preview_id: ${previewId.value}` : ''
})

// ─── Event handlers ──────────────────────────────────────────────────────

const handleClick = () => {
  // In inline mode the content is already visible — nothing to navigate
  // to. Emit `open` only in side mode (when the click would expand
  // content into the right-side panel).
  if (isInline.value) return
  // Emit the bubble's message id; the parent decides how to navigate
  // (focus the side panel, dismiss collapsed state, etc.).
  emit('open', props.messageId)
}

const copyPreviewId = async (e: Event) => {
  e.stopPropagation()
  if (!previewId.value) return
  try {
    await navigator.clipboard.writeText(previewId.value)
  } catch {
    // ignore — clipboard may be blocked in jsdom tests / older browsers
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs hover:border-violet-500/40 transition-colors"
    :class="[
      !isInline ? 'cursor-pointer' : '',
      { 'border-red-500/50 opacity-90': !isSuccess },
    ]"
    :role="!isInline ? 'button' : undefined"
    :tabindex="!isInline ? 0 : undefined"
    :aria-label="isSuccess
      ? `Show preview ${previewId ?? ''} in side panel`
      : `Show preview error: ${errorMessage ?? 'unknown error'}`"
    :data-testid="`show-preview-card-${messageId}`"
    :title="isSuccess ? 'Click to open in side panel' : errorMessage ?? ''"
    @click="handleClick"
    @keydown.enter="handleClick"
    @keydown.space.prevent="handleClick"
  >
    <!-- Header (always visible) -->
    <div
      class="group flex items-center gap-1 px-2 py-1 select-none hover:bg-violet-500/5"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">show_preview</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text)] text-xs"
        :title="headerTitle"
      >
        {{ headerLabel }}
      </span>
      <span
        v-if="rightMeta"
        class="text-[var(--semantic-text-muted)] text-xs"
        :title="`${contentType ?? ''} · ${contentLength ?? 0} bytes`"
      >
        {{ rightMeta }}
      </span>
      <span
        class="text-xs font-semibold"
        :class="isSuccess ? 'text-green-500' : 'text-red-500'"
      >
        {{ statusIndicator }}
      </span>
      <button
        v-if="isSuccess && previewId"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        title="Copy preview id"
        @click="copyPreviewId"
      >⎘</button>
    </div>

    <!--
      Inline-mode body: rich content rendered directly inside the
      chat bubble (no need to click through to the side panel).
      Hidden in 'side' mode (the user clicks to open the panel).

      The container has its own padding + max-w-full so the renderer
      (which renders an iframe at up to 320px tall) stays visually
      distinct from the message thread above it. `variant="inline"`
      switches PreviewContentRenderer to compact sizing and adds an
      "Open full preview" button for HTML content.
    -->
    <div
      v-if="isInline && isSuccess && resolvedContentType"
      class="border-t border-dashed border-[var(--color-border)] px-3 py-2"
      data-testid="show-preview-inline-content"
      @click.stop
    >
      <!--
        2026-08-29: PreviewContentRenderer now emits a dedicated
        'open-in-side-panel' event when the inline CTA strip's
        '↗ Open in side panel' button is clicked. We re-emit the
        existing 'open' event with our messageId so ChatView.vue's
        `@open="openPreviewForMessage"` handler at line 3093 keeps
        working unchanged. The renderer is also free to drop the
        event in the future (a "click to expand" pattern, etc.) —
        we don't depend on it.
      -->
      <PreviewContentRenderer
        :content-type="resolvedContentType"
        :args="rendererArgs"
        variant="inline"
        @open-in-side-panel="emit('open', messageId)"
      />
    </div>

    <!-- Error body — only when the tool failed. Success case has
         nothing to show inline when in side mode; the rich content
         lives in the side panel. The error message is wrapped in a
         single line so the user can scan the chat log without it
         expanding the card. -->
    <div
      v-if="!isSuccess && errorMessage"
      class="px-2 py-1.5 text-red-500 text-xs border-t border-dashed border-[var(--color-border)] whitespace-pre-wrap break-all"
    >
      <span class="font-semibold mr-1">Error:</span>{{ errorMessage }}
    </div>
    <ToolParameters :parameters="parameters" />
  </div>
</template>