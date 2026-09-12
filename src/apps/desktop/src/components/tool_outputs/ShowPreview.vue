<!--
  ShowPreview — tool output component for the `show_preview` agent tool.

  Renders the XML envelope produced by `executeShowPreviewToString` in
  `src/modules/agent/tools/show_preview.zig`. The component is purely
  presentational: no API calls, no store mutations.

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

  Body (success): rich content renders inline via
  PreviewContentRenderer. HTML previews offer an "Open in new tab"
  action for full-width viewing.

  Style is consistent with the rest of the tool_outputs components
  (KanbanMove, UpdateActivity): monospace, rounded-md, border + soft
  card bg, violet tool-name, ✗/✓ status indicators.

  Parameters prop — OPTIONAL:
  When provided, the component reads `title` and `content_type` from
  the JSON-stringified tool-call arguments and renders the title
  above the content_type for at-a-glance context. Falls back to the
  value extracted from the response envelope (which is authoritative
  for success) when the parameter title is absent.
-->
<script setup lang="ts">
import { computed } from 'vue'
import PreviewContentRenderer from '@/components/preview/PreviewContentRenderer.vue'
import { extractPreviewArgs, type PreviewArgs } from '@/helpers/previewArgs'
import ToolParameters from './_shared/ToolParameters.vue'

interface Props {
  /** The XML envelope produced by the show_preview tool. */
  content: string
  /**
   * The message id (used for test ids).
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

const previewArgs = computed<PreviewArgs>(() => extractPreviewArgs(props.parameters))

const contentTypeFromParams = computed(() => previewArgs.value.content_type ?? null)
const titleFromParams = computed(() => previewArgs.value.title ?? null)

const contentType = computed(() => {
  const fromEnvelope = findTag(props.content, 'content_type')?.trim()
  if (fromEnvelope) return fromEnvelope
  return contentTypeFromParams.value
})

const title = computed(() => {
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

const isSuccess = computed(
  () => errorMessage.value === null && status.value === 'shown',
)

const statusIndicator = computed(() => (isSuccess.value ? '✓' : '✗'))

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(2)} MB`
}

const headerLabel = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? 'error'
  const label = title.value ?? contentType.value ?? 'preview'
  return label
})

const rightMeta = computed(() => {
  if (!isSuccess.value) return null
  const parts: string[] = []
  if (contentType.value && title.value) {
    parts.push(contentType.value)
  }
  if (contentLength.value !== null) {
    parts.push(formatBytes(contentLength.value))
  }
  return parts.length > 0 ? parts.join(' · ') : null
})

const headerTitle = computed(() => {
  if (!isSuccess.value) return errorMessage.value ?? ''
  return previewId.value ? `preview_id: ${previewId.value}` : ''
})

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
    class="chat-tool-card font-mono text-xs"
    :class="[
      { 'border-red-500/50 opacity-90': !isSuccess },
    ]"
    :aria-label="isSuccess
      ? `Show preview ${previewId ?? ''} inline`
      : `Show preview error: ${errorMessage ?? 'unknown error'}`"
    :data-testid="`show-preview-card-${messageId}`"
    :title="headerTitle"
  >
    <!-- Header (always visible) -->
    <div
      class="group flex items-center gap-1 px-2 py-1 select-none"
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

    <!-- Inline body: rich content rendered directly inside the chat bubble. -->
    <div
      v-if="isSuccess && resolvedContentType"
      class="border-t border-dashed border-[var(--color-border)] px-3 py-2"
      data-testid="show-preview-inline-content"
    >
      <PreviewContentRenderer
        :content-type="resolvedContentType"
        :args="rendererArgs"
        variant="inline"
      />
    </div>

    <!-- Error body — only when the tool failed. -->
    <div
      v-if="!isSuccess && errorMessage"
      class="px-2 py-1.5 text-red-500 text-xs border-t border-dashed border-[var(--color-border)] whitespace-pre-wrap break-all"
    >
      <span class="font-semibold mr-1">Error:</span>{{ errorMessage }}
    </div>
    <ToolParameters :parameters="parameters" />
  </div>
</template>
