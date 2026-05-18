<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse file path from <file_write>...</file_write>
const filePath = computed(() => {
  const match = props.content.match(/<file_write>(.*?)<\/file_write>/)
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
  const match = props.content.match(/<error>(.*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// Status indicator (success/failure)
const statusIndicator = computed(() => isSuccess.value ? '✓' : '✗')

const toggle = () => {
  if (errorMessage.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyPath = async (e: Event) => {
  e.stopPropagation()
  if (filePath.value) {
    await navigator.clipboard.writeText(filePath.value)
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
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      :class="{ 'cursor-default': isSuccess && !errorMessage }"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">write_file</span>
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
      <span v-if="errorMessage" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded && errorMessage" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <div class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>
    </div>
  </div>
</template>