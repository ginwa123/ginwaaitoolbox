<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse <file_write>...</file_write>
const filePath = computed(() => {
  const match = props.content.match(/<file_write>(.*?)<\/file_write>/)
  return match ? match[1] : null
})

// Parse <success>true|false</success>
const isSuccess = computed(() => {
  const match = props.content.match(/<success>([\s\S]*?)<\/success>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

// Parse <error>...</error>
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !isSuccess }"
  >
    <ToolCardHeader
      tool-name="write_file"
      :primary="filePath"
      :success="isSuccess"
      :expanded="isExpanded"
      :expandable="!!errorMessage"
      :cwd="cwd"
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