<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse skill name
const skillName = computed(() => {
  const match = props.content.match(/<name>(.*?)<\/name>/)
  return match?.[1] ?? null
})

// Parse edited status
const isEdited = computed(() => {
  const match = props.content.match(/<edited>(.*?)<\/edited>/)
  return match?.[1]?.trim() === 'true'
})

// Status indicator
const statusIndicator = computed(() => isEdited.value ? '✓' : '✗')

// Parse error message if any
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  return match?.[1]?.trim() ?? null
})

// Parse path if present
const path = computed(() => {
  const match = props.content.match(/<path>(.*?)<\/path>/)
  return match?.[1]?.trim() ?? null
})

const toggle = () => {
  if (!isEdited.value || errorMessage.value || path.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copySkillName = async (e: Event) => {
  e.stopPropagation()
  if (skillName.value) {
    await navigator.clipboard.writeText(skillName.value)
  }
}
</script>

<template>
  <div 
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !isEdited }"
  >
    <!-- Header -->
    <div 
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      :class="{ 'cursor-default': isEdited && !errorMessage && !path }"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">edit_skill</span>
      <span class="flex-1 truncate text-left text-[var(--color-violet)] font-medium" :title="skillName || ''">
        {{ skillName || 'unknown' }}
      </span>
      
      <!-- Status indicator -->
      <span class="text-xs font-semibold" :class="isEdited ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>
      
      <!-- Copy button -->
      <button 
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copySkillName" 
        title="Copy skill name"
      >
        ⎘
      </button>
      
      <!-- Toggle indicator -->
      <span v-if="!isEdited || errorMessage || path" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0">
      <!-- Error message -->
      <div v-if="errorMessage" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs border-b border-dashed border-[var(--color-border)]">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Success path -->
      <div v-if="isEdited && path" class="flex gap-2 px-2 py-1.5 text-green-500 text-xs border-b border-dashed border-[var(--color-border)]">
        <span class="font-semibold shrink-0">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)]">{{ path }}</span>
      </div>
    </div>
  </div>
</template>
