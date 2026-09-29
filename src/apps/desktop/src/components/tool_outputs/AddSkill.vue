<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { normalizeToolContent, parseAddSkill } from './_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Surfaced via the
   *  shared <ToolParameters> block in the expanded body; empty/'{}'
   *  renders nothing (see ToolParameters.vue hasArgs guard). */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseAddSkill(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

const hasArgs = computed(() => {
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !parsed.created }"
  >
    <ToolCardHeader
      tool-name="add_skill"
      :primary="parsed.skillName"
      :success="parsed.created"
      :expanded="isExpanded"
      :expandable="!parsed.created || !!parsed.error || !!parsed.path || hasArgs"
      :show-open-in-editor="false"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0"
    >
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <div
        v-if="parsed.created && parsed.path"
        class="flex gap-2 px-2 py-1.5 text-green-500 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Path:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)]">{{ parsed.path }}</span>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>