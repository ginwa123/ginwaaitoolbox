<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse <skill_name>...</skill_name>
const skillName = computed(() => {
  const match = props.content.match(/<skill_name>(.*?)<\/skill_name>/)
  return match ? match[1] : null
})

// Parse <description>...</description>
const description = computed(() => {
  const match = props.content.match(/<description>(.*?)<\/description>/)
  return match ? match[1] : ''
})

// Parse <found>true|false</found>
const isFound = computed(() => {
  const match = props.content.match(/<found>(.*?)<\/found>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

// Parse <error>...</error>
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// Parse <available_skills>...</available_skills>, each containing <skill>...</skill>
const availableSkills = computed((): string[] => {
  const results: string[] = []
  const match = props.content.match(/<available_skills>([\s\S]*?)<\/available_skills>/)
  if (!match || !match[1]) return results

  const skillRegex = /<skill>(.*?)<\/skill>/g
  let m
  while ((m = skillRegex.exec(match[1])) !== null) {
    if (m[1]) results.push(m[1])
  }
  return results
})

const hasAvailableSkills = computed(() => availableSkills.value.length > 0)
const rightMeta = computed(() =>
  hasAvailableSkills.value ? `${availableSkills.value.length} available` : null,
)

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !isFound }"
  >
    <ToolCardHeader
      tool-name="view_skill"
      :primary="skillName"
      :success="isFound"
      :expanded="isExpanded"
      :expandable="!isFound || !!errorMessage || hasAvailableSkills || !!description"
      :right-meta="rightMeta"
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
            v-for="(skill, idx) in availableSkills"
            :key="idx"
            class="inline-block px-1.5 py-0.5 bg-violet-500/10 text-[var(--color-violet)] rounded text-[0.65rem]"
          >
            {{ skill }}
          </span>
        </div>
      </div>

      <div
        v-if="description"
        class="flex-1 min-h-0 flex flex-col overflow-hidden"
      >
        <div
          class="px-2 py-0.5 text-[0.65rem] text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] shrink-0"
        >
          Description
        </div>
        <pre
          class="flex-1 p-2 m-0 whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-xs overflow-auto"
        >{{ description }}</pre>
      </div>
    </div>
  </div>
</template>