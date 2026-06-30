<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { parseRemoveFile } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseRemoveFile(props.content))

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !parsed.deleted }"
  >
    <ToolCardHeader
      tool-name="remove_file"
      :primary="parsed.path"
      :success="parsed.deleted"
      :expanded="isExpanded"
      :expandable="!!parsed.error"
      :cwd="cwd"
      :inline-tag="parsed.recursive ? '(recursive)' : null"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded && parsed.error"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <div class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
    </div>
  </div>
</template>