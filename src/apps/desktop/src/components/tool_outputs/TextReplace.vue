<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import DiffView from './_shared/DiffView.vue'
import { parseTextReplace } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
  diffviewBefore?: string
  diffviewAfter?: string
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const parsed = computed(() => parseTextReplace(props.content))

// Diff content: prefer explicit props.diffviewBefore/After, then parsed before/after.
const diffBefore = computed(() => props.diffviewBefore ?? parsed.value.before)
const diffAfter = computed(() => props.diffviewAfter ?? parsed.value.after)

const hasDiff = computed(() => diffBefore.value !== '' || diffAfter.value !== '')

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
  >
    <ToolCardHeader
      tool-name="text_replace"
      :primary="parsed.path"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="!!parsed.error || hasDiff"
      :cwd="cwd"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-xs"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <DiffView
        v-if="hasDiff"
        :before="diffBefore"
        :after="diffAfter"
        :file-path="parsed.path || undefined"
        class="rounded-none border-0"
      />
    </div>
  </div>
</template>