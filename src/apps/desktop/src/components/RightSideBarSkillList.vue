<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue'
import { getSkills, type Skill } from '../api'
import { useSidebarStore } from '../stores/sidebar'

const props = defineProps<{
  cwd?: string
}>()

const emit = defineEmits<{
  'skill-click': [skill: Skill]
}>()

// Skills state
const globalSkills = ref<Skill[]>([])
const localSkills = ref<Skill[]>([])
const isLoading = ref(false)
const error = ref<string | null>(null)

// Computed
const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')
const hasSkills = computed(() => globalSkills.value.length > 0 || localSkills.value.length > 0)

// Skills expand/collapse state (persisted in useSidebarStore)
const sidebarStore = useSidebarStore()

// Load skills
const loadSkills = async () => {
  isLoading.value = true
  error.value = null

  try {
    const result = await getSkills(props.cwd)
    globalSkills.value = result.global_skills || []
    localSkills.value = result.local_skills || []
  } catch (err) {
    console.error('Failed to load skills:', err)
    error.value = err instanceof Error ? err.message : 'Failed to load skills'
  } finally {
    isLoading.value = false
  }
}

// Handle skill click
const handleSkillClick = (skill: Skill) => {
  emit('skill-click', skill)
}

// Refresh skills
const refreshSkills = () => {
  loadSkills()
}

// Watch for cwd changes (though skills are global/local, we might want to reload)
watch(() => props.cwd, () => {
  loadSkills()
}, { immediate: true })

onMounted(() => {
  loadSkills()
})
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Skills content (scrollable) -->
    <div class="flex-1 overflow-y-auto">
      <!-- Loading -->
      <div v-if="isLoading" class="flex-1 flex items-center justify-center">
        <svg class="animate-spin w-5 h-5" style="color: var(--color-aqua);" viewBox="0 0 24 24" fill="none">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
        </svg>
      </div>

      <!-- Error state -->
      <div
        v-else-if="error"
        class="flex-1 flex flex-col items-center justify-center p-4 text-center"
      >
        <span class="text-2xl mb-2">⚠️</span>
        <p class="text-xs" style="color: var(--semantic-text-dim);">
          {{ error }}
        </p>
        <button
          @click="refreshSkills"
          class="mt-3 px-3 py-1.5 rounded text-xs transition-colors"
          style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
        >
          Retry
        </button>
      </div>

      <!-- Empty state -->
      <div
        v-else-if="!hasSkills"
        class="flex-1 flex flex-col items-center justify-center p-4 text-center"
      >
        <span class="text-3xl mb-3">🧠</span>
        <p class="text-xs" style="color: var(--semantic-text-dim);">
          No skills available
        </p>
      </div>

      <!-- Skills list -->
      <div v-else class="py-1">
        <!-- Global Skills -->
        <div v-if="globalSkills.length > 0">
          <button
            type="button"
            class="w-full flex items-center justify-between gap-2 px-3 py-1.5 text-xs font-semibold uppercase tracking-wide transition-colors hover:opacity-80 text-left"
            style="color: var(--semantic-text-muted);"
            @click="sidebarStore.toggleSkillsGlobalExpanded"
          >
            <span>🌐 Global Skills ({{ globalSkills.length }})</span>
            <svg
              class="w-3 h-3 shrink-0 transition-transform duration-200"
              :class="{ 'rotate-90': sidebarStore.skillsGlobalExpanded }"
              fill="none" viewBox="0 0 24 24" stroke="currentColor"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
            </svg>
          </button>
          <div v-show="sidebarStore.skillsGlobalExpanded">
            <button
              v-for="skill in globalSkills"
              :key="'global-' + skill.name"
              class="w-full flex flex-col items-start gap-1 px-3 py-2 text-sm transition-colors hover:opacity-80 text-left"
              @click="handleSkillClick(skill)"
            >
              <span class="font-medium" style="color: var(--semantic-text);">
                {{ skill.name }}
              </span>
              <span class="text-xs line-clamp-2" style="color: var(--semantic-text-dim);">
                {{ skill.description }}
              </span>
            </button>
          </div>
        </div>

        <!-- Local Skills -->
        <div v-if="localSkills.length > 0" class="mt-2">
          <button
            type="button"
            class="w-full flex items-center justify-between gap-2 px-3 py-1.5 text-xs font-semibold uppercase tracking-wide transition-colors hover:opacity-80 text-left"
            style="color: var(--semantic-text-muted);"
            @click="sidebarStore.toggleSkillsLocalExpanded"
          >
            <span>📁 Local Skills ({{ localSkills.length }})</span>
            <svg
              class="w-3 h-3 shrink-0 transition-transform duration-200"
              :class="{ 'rotate-90': sidebarStore.skillsLocalExpanded }"
              fill="none" viewBox="0 0 24 24" stroke="currentColor"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
            </svg>
          </button>
          <div v-show="sidebarStore.skillsLocalExpanded">
            <button
              v-for="skill in localSkills"
              :key="'local-' + skill.name"
              class="w-full flex flex-col items-start gap-1 px-3 py-2 text-sm transition-colors hover:opacity-80 text-left"
              @click="handleSkillClick(skill)"
            >
              <span class="font-medium" style="color: var(--semantic-text);">
                {{ skill.name }}
              </span>
              <span class="text-xs line-clamp-2" style="color: var(--semantic-text-dim);">
                {{ skill.description }}
              </span>
              <span v-if="skill.path" class="text-xs truncate" style="color: var(--semantic-text-muted);">
                {{ skill.path }}
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>

    <!-- Footer -->
    <div
      class="h-8 flex items-center justify-between px-3 shrink-0 text-xs"
      style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim);"
    >
      <span>{{ globalSkills.length + localSkills.length }} skills</span>
      <button
        @click="refreshSkills"
        class="p-1 rounded hover:opacity-70 transition-opacity"
        title="Refresh skills"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
        </svg>
      </button>
    </div>
  </div>
</template>

<style scoped>
.line-clamp-2 {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.mt-2 {
  margin-top: 0.5rem;
}
</style>
