<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse skill name from <skill_name>...</skill_name>
const skillName = computed(() => {
  const match = props.content.match(/<skill_name>(.*?)<\/skill_name>/)
  return match ? match[1] : null
})

// Parse loaded status
const isLoaded = computed(() => {
  const match = props.content.match(/<loaded>([\s\S]*?)<\/loaded>/)
  if (!match || !match[1]) return false
  return match[1].trim() === 'true'
})

// Parse error message if any
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
})

// Parse skill content
const skillContent = computed(() => {
  const match = props.content.match(/<content>([\s\S]*?)<\/content>/)
  return match ? match[1] : ''
})

// Parse available skills (when skill not found)
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

// Has available skills list (skill not found)
const hasAvailableSkills = computed(() => availableSkills.value.length > 0)

// Status indicator
const statusIndicator = computed(() => isLoaded.value ? '✓' : '✗')

const toggle = () => {
  if (!isLoaded.value || errorMessage.value || hasAvailableSkills.value || skillContent.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copySkillName = async (e: Event) => {
  e.stopPropagation()
  if (skillName.value) {
    await navigator.clipboard.writeText(skillName.value)
  }
}
</script>

<template>
  <div 
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': !isLoaded }"
  >
    <!-- Header -->
    <div 
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      :class="{ 'cursor-default': isLoaded && !errorMessage && !hasAvailableSkills && !skillContent }"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">get_skill</span>
      <span class="flex-1 truncate text-left text-[var(--color-violet)] font-medium" :title="skillName || ''">
        {{ skillName || 'unknown' }}
      </span>
      
      <!-- Status indicator -->
      <span class="text-xs font-semibold" :class="isLoaded ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>
      
      <!-- Available skills count badge -->
      <span v-if="hasAvailableSkills" class="text-[var(--semantic-text-muted)] text-[0.65rem]">
        {{ availableSkills.length }} available
      </span>
      
      <!-- Copy button -->
      <button 
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copySkillName" 
        title="Copy skill name"
      >
        ⎘
      </button>
      
      <!-- Toggle indicator -->
      <span v-if="!isLoaded || errorMessage || hasAvailableSkills || skillContent" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0">
      <!-- Error message -->
      <div v-if="errorMessage" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs border-b border-dashed border-[var(--color-border)]">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Available skills list -->
      <div v-if="hasAvailableSkills" class="py-1 border-b border-dashed border-[var(--color-border)]">
        <div class="px-2 py-0.5 text-[0.65rem] text-[var(--semantic-text-muted)] font-medium bg-black/[0.02]">
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

      <!-- Skill content -->
      <div v-if="skillContent" class="flex-1 min-h-0 flex flex-col overflow-hidden">
        <div class="px-2 py-0.5 text-[0.65rem] text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] shrink-0">
          Content
          <span class="ml-1">{{ skillContent.split('\n').length }}L</span>
        </div>
        <pre class="flex-1 p-2 m-0 whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-xs overflow-auto">{{ skillContent }}</pre>
      </div>
    </div>
  </div>
</template>