<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse <path>...</path>
const filePath = computed(() => {
  const match = props.content.match(/<path>(.*?)<\/path>/)
  return match ? match[1] : null
})

// Parse <deleted>true|false</deleted>
const isDeleted = computed(() => {
  const match = props.content.match(/<deleted>([\s\S]*?)<\/deleted>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

// Parse <error>...</error>
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// Parse <recursive>true|false</recursive>
const isRecursive = computed(() => {
  const match = props.content.match(/<recursive>([\s\S]*?)<\/recursive>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !isDeleted }"
  >
    <ToolCardHeader
      tool-name="remove_file"
      :primary="filePath"
      :success="isDeleted"
      :expanded="isExpanded"
      :expandable="!!errorMessage"
      :cwd="cwd"
      :inline-tag="isRecursive ? '(recursive)' : null"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded && errorMessage"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <div class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>
    </div>
  </div>
</template>