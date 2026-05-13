<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getSkills, type Skill } from '../api'

const skills = ref<Skill[]>([])
const isLoading = ref(true)
const error = ref<string | null>(null)

const loadSkills = async () => {
  isLoading.value = true
  error.value = null
  try {
    const result = await getSkills()
    skills.value = result.global_skills || []
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load skills'
    console.error('Failed to load skills:', err)
  } finally {
    isLoading.value = false
  }
}

onMounted(() => {
  loadSkills()
})

defineExpose({
  refresh: loadSkills
})
</script>

<template>
  <div class="skill-list">
    <!-- Loading State -->
    <div v-if="isLoading" class="flex items-center justify-center py-8">
      <div class="flex items-center gap-3">
        <div class="w-5 h-5 border-2 rounded-full animate-spin" style="border-color: var(--color-violet); border-top-color: transparent;"></div>
        <span style="color: var(--semantic-text-muted);">Loading skills...</span>
      </div>
    </div>

    <!-- Error State -->
    <div v-else-if="error" class="text-center py-8">
      <p class="text-sm" style="color: var(--color-red);">{{ error }}</p>
      <button
        @click="loadSkills"
        class="mt-3 px-4 py-2 rounded-lg text-sm transition-colors duration-200"
        style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
      >
        Retry
      </button>
    </div>

    <!-- Empty State -->
    <div v-else-if="skills.length === 0" class="text-center py-8">
      <p class="text-sm" style="color: var(--semantic-text-muted);">No skills available</p>
    </div>

    <!-- Skills List -->
    <div v-else class="space-y-2">
      <div
        v-for="skill in skills"
        :key="skill.name"
        class="p-4 rounded-lg transition-all duration-200 cursor-pointer hover:opacity-90"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex items-start gap-3">
          <span class="text-lg mt-0.5">🛠️</span>
          <div class="flex-1 min-w-0">
            <h3 class="text-sm font-medium truncate" style="color: var(--semantic-text);">
              {{ skill.name }}
            </h3>
            <p class="text-xs mt-1 line-clamp-2" style="color: var(--semantic-text-muted);">
              {{ skill.description }}
            </p>
            <p v-if="skill.path" class="text-xs mt-2 truncate" style="color: var(--semantic-text-dim);">
              {{ skill.path }}
            </p>
          </div>
        </div>
      </div>
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
</style>