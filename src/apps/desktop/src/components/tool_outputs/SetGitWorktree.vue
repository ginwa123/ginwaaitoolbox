<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Extract the basename of <path> for the header (e.g. "auth-fix" from
// "/abs/.worktrees/auth-fix"). Falls back to the full path if the
// basename can't be derived.
const pathBasename = (p: string): string => {
  const parts = p.split('/').filter(Boolean)
  // parts.length > 0 guard is true here; use ?? to satisfy noUncheckedIndexedAccess
  return parts.length > 0 ? (parts[parts.length - 1] ?? p) : p
}

// Parse <path>
const path = computed(() => {
  const match = props.content.match(/<path>([\s\S]*?)<\/path>/)
  return match?.[1]?.trim() ?? null
})

// Parse <branch>
const branch = computed(() => {
  const match = props.content.match(/<branch>([\s\S]*?)<\/branch>/)
  return match?.[1]?.trim() ?? null
})

// Parse <cleared> — set to "true" on the CLEAR success path
const isCleared = computed(() => {
  const match = props.content.match(/<cleared>([\s\S]*?)<\/cleared>/)
  return match?.[1]?.trim() === 'true'
})

// Parse <created> — set to "true" on the SET success path, "false" on
// any error path
const isCreated = computed(() => {
  const match = props.content.match(/<created>([\s\S]*?)<\/created>/)
  return match?.[1]?.trim() === 'true'
})

// Status indicator — ✓ for either SET or CLEAR success, ✗ otherwise
const isSuccess = computed(() => isCreated.value || isCleared.value)
const statusIndicator = computed(() => isSuccess.value ? '✓' : '✗')

// Parse <error>
const errorMessage = computed(() => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  return match?.[1]?.trim() ?? null
})

// Header text — the basename for SET, "(cleared)" for CLEAR, "error" otherwise
const headerLabel = computed(() => {
  if (isCleared.value) return '(cleared)'
  if (path.value) return pathBasename(path.value)
  return 'error'
})

const toggle = () => {
  // Always allow expansion (even on success) so the user can see the full path + branch
  isExpanded.value = !isExpanded.value
}

const copyPath = async (e: Event) => {
  e.stopPropagation()
  const target = path.value ?? ''
  if (target) {
    await navigator.clipboard.writeText(target)
  }
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !isSuccess }"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-emerald-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-emerald-600 dark:text-emerald-400 font-semibold text-xs">🌳 set_git_worktree</span>
      <span
        class="flex-1 truncate text-left text-emerald-700 dark:text-emerald-300 font-medium"
        :title="path ?? ''"
      >
        {{ headerLabel }}
      </span>

      <!-- Status indicator -->
      <span class="text-xs font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Copy button (only for SET path — there's a path to copy) -->
      <button
        v-if="path"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-emerald-500 text-base transition-opacity"
        @click="copyPath"
        title="Copy worktree path"
      >
        ⎘
      </button>

      <!-- Toggle indicator -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0">
      <!-- Error message -->
      <div
        v-if="errorMessage"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Worktree path (SET path) -->
      <div
        v-if="path"
        class="flex gap-2 px-2 py-1.5 text-emerald-600 dark:text-emerald-400 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)]">{{ path }}</span>
      </div>

      <!-- Branch name (SET path) -->
      <div
        v-if="branch"
        class="flex gap-2 px-2 py-1.5 text-emerald-600 dark:text-emerald-400 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Branch:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)] font-mono">{{ branch }}</span>
      </div>

      <!-- Cleared status (CLEAR path) -->
      <div
        v-if="isCleared"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-text-dim)] text-xs"
      >
        <span>Worktree binding removed and directory deleted.</span>
      </div>
    </div>
  </div>
</template>
