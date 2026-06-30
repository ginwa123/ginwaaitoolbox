<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { parseSetGitWorktree } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseSetGitWorktree(props.content))

const pathBasename = (p: string): string => {
  const parts = p.split('/').filter(Boolean)
  return parts.length > 0 ? (parts[parts.length - 1] ?? p) : p
}

// Header label: basename for SET, "(cleared)" for CLEAR, "error" otherwise
const headerLabel = computed(() => {
  if (parsed.value.cleared) return '(cleared)'
  if (parsed.value.path) return pathBasename(parsed.value.path)
  return 'error'
})

const handleToggle = (next: boolean) => {
  // always allow expansion so the user can see full path + branch
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
  >
    <ToolCardHeader
      tool-name="set_git_worktree"
      :primary="headerLabel"
      :primary-title="parsed.path ?? ''"
      :primary-class="'text-[var(--semantic-text-dim)]'"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :show-copy="!!parsed.path"
      :show-open-in-editor="false"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0"
    >
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <div
        v-if="parsed.path"
        class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--color-violet)]" :title="parsed.path">{{ parsed.path }}</span>
      </div>

      <div
        v-if="parsed.branch"
        class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Branch:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)] font-mono">{{ parsed.branch }}</span>
      </div>

      <div
        v-if="parsed.cleared"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-text-dim)] text-xs"
      >
        <span>Worktree binding removed and directory deleted.</span>
      </div>
    </div>
  </div>
</template>