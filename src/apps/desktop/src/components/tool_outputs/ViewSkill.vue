<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { parseViewSkill } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseViewSkill(props.content))

const hasAvailableSkills = computed(() => parsed.value.availableSkills.length > 0)
const rightMeta = computed(() =>
  hasAvailableSkills.value ? `${parsed.value.availableSkills.length} available` : null,
)

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': !parsed.found }"
  >
    <ToolCardHeader
      tool-name="view_skill"
      :primary="parsed.skillName"
      :success="parsed.found"
      :expanded="isExpanded"
      :expandable="!parsed.found || !!parsed.error || hasAvailableSkills || !!parsed.description"
      :right-meta="rightMeta"
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
        v-if="hasAvailableSkills"
        class="py-1 border-b border-dashed border-[var(--color-border)]"
      >
        <div
          class="px-2 py-0.5 text-[0.65rem] text-[var(--semantic-text-muted)] font-medium bg-black/[0.02]"
        >
          Available skills
        </div>
        <div class="px-2 py-1 flex flex-wrap gap-1">
          <span
            v-for="(skill, idx) in parsed.availableSkills"
            :key="idx"
            class="inline-block px-1.5 py-0.5 bg-violet-500/10 text-[var(--color-violet)] rounded text-[0.65rem]"
          >
            {{ skill }}
          </span>
        </div>
      </div>

      <div
        v-if="parsed.description"
        class="flex-1 min-h-0 flex flex-col overflow-hidden"
      >
        <div
          class="px-2 py-0.5 text-[0.65rem] text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] shrink-0"
        >
          Description
        </div>
        <pre
          class="flex-1 p-2 m-0 whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-xs overflow-auto"
        >{{ parsed.description }}</pre>
      </div>
    </div>
  </div>
</template>