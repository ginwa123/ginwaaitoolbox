<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { parseRemoveSkill } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseRemoveSkill(props.content))

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !parsed.removed }"
  >
    <ToolCardHeader
      tool-name="remove_skill"
      :primary="parsed.skillName"
      :success="parsed.removed"
      :expanded="isExpanded"
      :expandable="!parsed.removed || !!parsed.error || !!parsed.path"
      :show-open-in-editor="false"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0"
    >
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <div
        v-if="parsed.removed && parsed.path"
        class="flex gap-2 px-2 py-1.5 text-green-500 text-xs border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)]">{{ parsed.path }}</span>
      </div>
    </div>
  </div>
</template>