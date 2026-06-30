<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse <name>...</name>
const skillName = computed(() => {
  const match = props.content.match(/<name>(.*?)<\/name>/)
  return match?.[1] ?? null
})

// Parse <edited>true|false</edited>
const isEdited = computed(() => {
  const match = props.content.match(/<edited>(.*?)<\/edited>/)
  return match?.[1]?.trim() === 'true'
})

// Parse <error>...</error>
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  return match?.[1]?.trim() ?? null
})

// Parse <path>...</path>
const path = computed(() => {
  const match = props.content.match(/<path>(.*?)<\/path>/)
  return match?.[1]?.trim() ?? null
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !isEdited }"
  >
    <ToolCardHeader
      tool-name="edit_skill"
      :primary="skillName"
      :success="isEdited"
      :expanded="isExpanded"
      :expandable="!isEdited || !!errorMessage || !!path"
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
        v-if="isEdited && path"
        class="flex gap-2 px-2 py-1.5 text-green-500 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)]">{{ path }}</span>
      </div>
    </div>
  </div>
</template>