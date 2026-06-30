<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import DiffView from './_shared/DiffView.vue'

const props = defineProps<{
  content: string
  expanded?: boolean
  diffviewBefore?: string
  diffviewAfter?: string
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse <path>...</path>
const filePath = computed(() => {
  const match = props.content.match(/<path>(.*?)<\/path>/)
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
  const match = props.content.match(/<error>([\s\S]*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// Diff content: prefer explicit props.diffviewBefore/After, then <diff_view>
// in the content, else empty.
const diffBefore = computed(() => {
  if (props.diffviewBefore) return props.diffviewBefore
  const m = props.content.match(/<before>([\s\S]*?)<\/before>/)
  return m && m[1] ? m[1] : ''
})

const diffAfter = computed(() => {
  if (props.diffviewAfter) return props.diffviewAfter
  const m = props.content.match(/<after>([\s\S]*?)<\/after>/)
  return m && m[1] ? m[1] : ''
})

const hasDiff = computed(() => diffBefore.value !== '' || diffAfter.value !== '')

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
      tool-name="text_replace"
      :primary="filePath"
      :success="isSuccess"
      :expanded="isExpanded"
      :expandable="!!errorMessage || hasDiff"
      :cwd="cwd"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div
        v-if="errorMessage"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>
      <DiffView
        v-if="hasDiff"
        :before="diffBefore"
        :after="diffAfter"
        :file-path="filePath ?? undefined"
        class="rounded-none border-0"
      />
    </div>
  </div>
</template>