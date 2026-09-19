<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import DiffView from './_shared/DiffView.vue'
import { normalizeToolContent, parseTextReplace } from './_shared/toolOutputParser'
import { extractParam } from '@/helpers/extractParam'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  diffviewBefore?: string
  diffviewAfter?: string
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)

// Keep local toggle state in sync with the parent's `expanded` prop so the
// component behaves as a *controlled* component (parent owns the truth).
// Without this watcher, mount({expanded:true}) → setProps({expanded:false})
// leaves the local ref out of sync with the prop, which is wrong for any
// caller that programmatically expands/collapses from outside (e.g. tests,
// a "collapse all" toolbar, etc.).
watch(
  () => props.expanded,
  (next) => {
    isExpanded.value = next ?? false
  },
)

const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseTextReplace(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

const hasArgs = computed(() => {
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

// Diff content: prefer explicit props.diffviewBefore/After, then parsed before/after.
const diffBefore = computed(() => props.diffviewBefore ?? parsed.value.before)
const diffAfter = computed(() => props.diffviewAfter ?? parsed.value.after)

const hasDiff = computed(() => diffBefore.value !== '' || diffAfter.value !== '')

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its path.
// The parser uses the `path` tag; also try `file_path` for forward-compat.
const displayPath = computed((): string | null => {
  return (
    contentPath.value ??
    extractParam(props.parameters, 'path') ??
    extractParam(props.parameters, 'file_path')
  )
})

// Running: empty envelope content, but we know the path.
const isRunning = computed(() => {
  return isEmptyContent(props.content) && displayPath.value !== null
})

const openInEditor = useInjectOpenInCodeEditor()

// Forward the diff-view's @jump-to-line to the in-app code editor so the
// user can click a line number in the diff and land on that exact line
// in the file viewer. We require both `cwd` and a path (the target file
// must be on disk + a workspace) before forwarding; otherwise we silently
// ignore the click (the line-number still renders the hover affordance
// but won't do anything, which is correct for tests / standalone renders).
const handleJumpToLine = (line: number) => {
  const targetPath = displayPath.value ?? parsed.value.path
  if (!openInEditor || !props.cwd || !targetPath) return
  openInEditor({
    filePath: targetPath,
    cwd: props.cwd,
    line,
  })
}

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
    data-testid="text-replace-card"
  >
    <ToolCardHeader
      tool-name="text_replace"
      :primary="displayPath"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="!!parsed.error || hasDiff || hasArgs"
      :cwd="cwd"
      :right-meta="isRunning ? 'running…' : null"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <DiffView
        v-if="hasDiff"
        :before="diffBefore"
        :after="diffAfter"
        :file-path="displayPath || undefined"
        class="rounded-none border-0"
        @jump-to-line="handleJumpToLine"
      />
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
