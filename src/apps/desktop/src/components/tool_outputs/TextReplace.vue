<script setup lang="ts">
import { computed, ref } from 'vue'
import { useInjectOpenInCodeEditor } from '../../composables/useCodeEditor'

const props = defineProps<{
  content: string
  expanded?: boolean
  diffviewBefore?: string
  diffviewAfter?: string
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const openInEditor = useInjectOpenInCodeEditor()

// Parse file path from <path>...</path>
const filePath = computed(() => {
  const match = props.content.match(/<path>(.*?)<\/path>/)
  return match ? match[1] : null
})

// Parse success status
const isSuccess = computed(() => {
  const match = props.content.match(/<success>([\s\S]*?)<\/success>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

// Parse error message if any
const errorMessage = computed(() => {
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// Use passed diff data or parse from content
const diffBefore = computed(() => {
  if (props.diffviewBefore) return props.diffviewBefore
  const match = props.content.match(/<before>([\s\S]*?)<\/before>/)
  if (!match || !match[1]) return null
  return match[1]
})

const diffAfter = computed(() => {
  if (props.diffviewAfter) return props.diffviewAfter
  const match = props.content.match(/<after>([\s\S]*?)<\/after>/)
  if (!match || !match[1]) return null
  return match[1]
})

// Has diff view data
const hasDiffView = computed(() => diffBefore.value && diffAfter.value)

// Status indicator (success/failure)
const statusIndicator = computed(() => isSuccess.value ? '✓' : '✗')

// Diff view computed values
const beforeLines = computed(() => diffBefore.value?.split('\n') ?? [])
const afterLines = computed(() => diffAfter.value?.split('\n') ?? [])

const isLineChanged = (idx: number): boolean => {
  return beforeLines.value[idx] !== afterLines.value[idx]
}

const toggle = () => {
  if (errorMessage.value || hasDiffView.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyPath = async (e: Event) => {
  e.stopPropagation()
  if (filePath.value) {
    await navigator.clipboard.writeText(filePath.value)
  }
}

const handleOpenInEditor = (e: Event) => {
  e.stopPropagation()
  if (!filePath.value || !props.cwd || !openInEditor) return
  openInEditor({ filePath: filePath.value, cwd: props.cwd })
}
</script>

<template>
  <div 
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !isSuccess }"
  >
    <!-- Header -->
    <div 
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">text_replace</span>
      <span class="flex-1 truncate text-left text-[var(--color-violet)] font-medium" :title="filePath || ''">{{ filePath || 'unknown' }}</span>
      <span class="text-xs font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>
      <button
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copyPath"
        title="Copy path"
      >
        ⎘
      </button>
      <button
        v-if="props.cwd && openInEditor && filePath"
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 transition-opacity"
        @click="handleOpenInEditor"
        title="Open in code editor"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
      <span v-if="errorMessage || hasDiffView" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Error message -->
      <div v-if="errorMessage" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Diff view -->
      <div v-if="hasDiffView" class="flex overflow-hidden bg-[var(--semantic-card-bg)] ">
        <div class="flex-1 overflow-hidden">
          <div class="px-2 py-1 text-xs font-semibold uppercase bg-black/[0.02] border-b border-[var(--color-border)] text-red-500">Before</div>
          <div class="overflow-x-auto text-xs leading-relaxed">
            <div 
              v-for="(line, idx) in beforeLines" 
              :key="'b'+idx" 
              class="flex min-w-max px-2 py-0.5 whitespace-pre hover:bg-violet-500/5"
              :class="isLineChanged(idx) ? '!bg-red-400/15 !text-red-500' : ''"
            >
              <span class="w-4 mr-3 font-semibold shrink-0 text-center">-</span>
              <span class="shrink-0">{{ line }}</span>
            </div>
          </div>
        </div>
        <div class="w-px bg-[var(--color-border)]"></div>
        <div class="flex-1 overflow-hidden">
          <div class="px-2 py-1 text-xs font-semibold uppercase bg-black/[0.02] border-b border-[var(--color-border)] text-green-500">After</div>
          <div class="overflow-x-auto text-xs leading-relaxed">
            <div 
              v-for="(line, idx) in afterLines" 
              :key="'a'+idx" 
              class="flex min-w-max px-2 py-0.5 whitespace-pre hover:bg-violet-500/5"
              :class="isLineChanged(idx) ? '!bg-green-400/15 !text-green-500' : ''"
            >
              <span class="w-4 mr-3 font-semibold shrink-0 text-center">+</span>
              <span class="shrink-0">{{ line }}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>