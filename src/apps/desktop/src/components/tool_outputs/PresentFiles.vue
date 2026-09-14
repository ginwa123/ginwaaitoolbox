<!--
  PresentFiles — tool output component for the `present_files` agent tool.

  Renders the XML envelope produced by `executePresentFilesToString` in
  `src/modules/agent/tools/present_files.zig`. The component is
  presentational except for plain `<a href>` / `<img src>` links to the
  download endpoint (`GET /api/files/download`, cookie-based auth so no
  JS fetch/blob dance is needed):

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

  Per-file rendering:
    - image/* mimes: thumbnail preview (`disposition=inline`) visible
      WITHOUT clicking download; click thumbnail → fullscreen
      `ImagePreview` modal. Filename + ⬇ button download
      (`disposition=attachment`).
    - everything else: generic 📄 row (icon + name + size + mime + ⬇).

  Header (always visible):
    `present_files → N files ✓` (success)
    `present_files → <error_message> ✗` (failure)

  Style matches the rest of tool_outputs (ReadFile, GenerateImage):
  monospace, rounded-md, border + soft card bg, violet tool-name,
  ✗/✓ status indicators, expand/collapse `+`/`−` toggle.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import ImagePreview from '../preview/ImagePreview.vue'
import {
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
  content: string
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
const parsed = computed(() => parsePresentFiles(props.content))
const fullscreenSrc = ref<string | null>(null)

const files = computed((): ParsedPresentFile[] => parsed.value.files)

const displayName = (f: ParsedPresentFile): string =>
  f.label && f.label.trim() !== '' ? f.label : basenameOfPath(f.path)

const downloadUrl = (f: ParsedPresentFile): string =>
  fileDownloadUrl(props.sessionId, f.path, 'attachment')

const previewUrl = (f: ParsedPresentFile): string =>
  fileDownloadUrl(props.sessionId, f.path, 'inline')

const isImage = (f: ParsedPresentFile): boolean => isPreviewableImage(f.mime)

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
          class="flex items-center gap-2 rounded-md border border-[var(--color-border)] bg-black/[0.02] px-2 py-1.5 hover:bg-violet-500/5"
          :data-testid="`present-files-row-${idx}`"
        >
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
        <div v-if="files.length === 0" class="px-1 py-0.5 text-[var(--semantic-text-dim)]">
          (no files)
        </div>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>

    <ImagePreview :src="fullscreenSrc ?? ''" @close="closeFullscreen" />
  </div>
</template>
