<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getSkills, type Skill } from '../../api'

const props = defineProps<{
  selectedSkillName: string | null
}>()

/** A skill plus the split tags the template renders as chips. */
interface SkillView extends Skill {
  tagList: string[]
}

const globalSkills = ref<SkillView[]>([])
const localSkills = ref<SkillView[]>([])
const isLoading = ref(true)
const error = ref<string | null>(null)

const emit = defineEmits<{
  selectSkill: [skillName: string]
}>()

// Tags arrive '||'-joined (the agent_memories convention); '' means the
// skill's frontmatter carried no tags line, not a tag with no name.
const withTags = (skills: Skill[]): SkillView[] =>
  skills.map(({ tags, ...skill }) => ({
    ...skill,
    tagList: (tags ?? '')
      .split('||')
      .map((t) => t.trim())
      .filter((t) => t !== ''),
  }))

const loadSkills = async () => {
  isLoading.value = true
  error.value = null
  try {
    const result = await getSkills()
    globalSkills.value = withTags(result.global_skills || [])
    localSkills.value = withTags(result.local_skills || [])
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load skills'
    console.error('Failed to load skills:', err)
  } finally {
    isLoading.value = false
  }
}

const openSkillDetail = (skill: Skill) => {
  emit('selectSkill', skill.name)
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
    <div v-else-if="globalSkills.length === 0 && localSkills.length === 0" class="text-center py-8">
      <p class="text-sm" style="color: var(--semantic-text-muted);">No skills available</p>
    </div>

    <!-- Skills List -->
    <div v-else class="space-y-2">
      <!-- Global Skills Section -->
      <div v-if="globalSkills.length > 0">
        <h4 class="text-xs font-medium mb-2 px-1" style="color: var(--semantic-text-muted);">
          Global Skills
        </h4>
        <div
          v-for="skill in globalSkills"
          :key="'global-' + skill.name"
          class="p-4 rounded-lg transition-all duration-200 cursor-pointer hover:opacity-90 mb-2"
          :class="{ 'ring-2': props.selectedSkillName === skill.name }"
          :style="props.selectedSkillName === skill.name 
            ? 'background-color: var(--semantic-active-bg); border-color: var(--color-violet);' 
            : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'"
          @click="openSkillDetail(skill)"
        >
          <div class="flex items-start gap-3">
            <span class="text-lg mt-0.5">🌐</span>
            <div class="flex-1 min-w-0">
              <h3 class="text-sm font-medium truncate" style="color: var(--semantic-text);">
                {{ skill.name }}
              </h3>
              <p class="text-xs mt-1 line-clamp-2" style="color: var(--semantic-text-muted);">
                {{ skill.description }}
              </p>
              <div
                v-if="skill.tagList.length > 0"
                class="flex flex-wrap gap-1 mt-2"
                data-testid="skill-tags"
              >
                <span
                  v-for="tag in skill.tagList"
                  :key="tag"
                  class="inline-block px-1.5 py-0.5 bg-violet-500/10 text-[var(--color-violet)] rounded text-[0.65rem]"
                >
                  {{ tag }}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Local Skills Section -->
      <div v-if="localSkills.length > 0">
        <h4 class="text-xs font-medium mb-2 px-1 mt-4" style="color: var(--semantic-text-muted);">
          Local Skills
        </h4>
        <div
          v-for="skill in localSkills"
          :key="'local-' + skill.name"
          class="p-4 rounded-lg transition-all duration-200 cursor-pointer hover:opacity-90 mb-2"
          :class="{ 'ring-2': props.selectedSkillName === skill.name }"
          :style="props.selectedSkillName === skill.name 
            ? 'background-color: var(--semantic-active-bg); border-color: var(--color-violet);' 
            : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'"
          @click="openSkillDetail(skill)"
        >
          <div class="flex items-start gap-3">
            <div class="flex-1 min-w-0">
              <h3 class="text-sm font-medium truncate" style="color: var(--semantic-text);">
                {{ skill.name }}
              </h3>
              <p class="text-xs mt-1 line-clamp-2" style="color: var(--semantic-text-muted);">
                {{ skill.description }}
              </p>
              <div
                v-if="skill.tagList.length > 0"
                class="flex flex-wrap gap-1 mt-2"
                data-testid="skill-tags"
              >
                <span
                  v-for="tag in skill.tagList"
                  :key="tag"
                  class="inline-block px-1.5 py-0.5 bg-violet-500/10 text-[var(--color-violet)] rounded text-[0.65rem]"
                >
                  {{ tag }}
                </span>
              </div>
              <p v-if="skill.path" class="text-xs mt-2 truncate" style="color: var(--semantic-text-dim);">
                {{ skill.path }}
              </p>
            </div>
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