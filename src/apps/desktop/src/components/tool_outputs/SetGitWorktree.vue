<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

const pathBasename = (p: string): string => {
  const parts = p.split('/').filter(Boolean)
  return parts.length > 0 ? (parts[parts.length - 1] ?? p) : p
}

// Parse <path>...</path>
const path = computed(() => {
  const match = props.content.match(/<path>([\s\S]*?)<\/path>/)
  return match?.[1]?.trim() ?? null
})

// Parse <branch>...</branch>
const branch = computed(() => {
  const match = props.content.match(/<branch>([\s\S]*?)<\/branch>/)
  return match?.[1]?.trim() ?? null
})

// Parse <cleared>true|false</cleared>
const isCleared = computed(() => {
  const match = props.content.match(/<cleared>([\s\S]*?)<\/cleared>/)
  return match?.[1]?.trim() === 'true'
})

// Parse <created>true|false</created>
const isCreated = computed(() => {
  const match = props.content.match(/<created>([\s\S]*?)<\/created>/)
  return match?.[1]?.trim() === 'true'
})

const isSuccess = computed(() => isCreated.value || isCleared.value)

// Parse <error>...</error>
const errorMessage = computed(() => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  return match?.[1]?.trim() ?? null
})

// Header label: basename for SET, "(cleared)" for CLEAR, "error" otherwise
const headerLabel = computed(() => {
  if (isCleared.value) return '(cleared)'
  if (path.value) return pathBasename(path.value)
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
    :class="{ 'border-red-500/50 opacity-80': !isSuccess }"
  >
    <ToolCardHeader
      tool-name="set_git_worktree"
      :primary="headerLabel"
      :primary-title="path ?? ''"
      :primary-class="'text-[var(--semantic-text-dim)]'"
      :success="isSuccess"
      :expanded="isExpanded"
      :expandable="true"
      :show-copy="!!path"
      :show-open-in-editor="false"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0"
    >
      <div
        v-if="errorMessage"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <div
        v-if="path"
        class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--color-violet)]" :title="path">{{ path }}</span>
      </div>

      <div
        v-if="branch"
        class="flex gap-2 px-2 py-1.5 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Branch:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)] font-mono">{{ branch }}</span>
      </div>

      <div
        v-if="isCleared"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-text-dim)] text-xs"
      >
        <span>Worktree binding removed and directory deleted.</span>
      </div>
    </div>
  </div>
</template>