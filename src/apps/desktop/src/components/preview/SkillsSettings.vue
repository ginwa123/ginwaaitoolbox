<script setup lang="ts">
import { ref } from 'vue'
import SkillList from '../tool_outputs/SkillList.vue'
import SkillDetail from '../shell/SkillDetail.vue'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

const selectedSkillName = ref<string | null>(null)
const skillListRef = ref<InstanceType<typeof SkillList> | null>(null)

const handleSelectSkill = (skillName: string) => {
  selectedSkillName.value = skillName
}

const handleSkillDeleted = (_skillName: string) => {
  selectedSkillName.value = null
  skillListRef.value?.refresh()
  emit('notification', 'Skill deleted successfully', 'success')
}

const handleSkillError = (message: string) => {
  emit('notification', message, 'error')
}
</script>

<template>
  <div class="flex h-full gap-6">
    <!-- Skill List Panel -->
    <div class="w-80 shrink-0 flex flex-col overflow-hidden">
      <div
        class="rounded-xl p-6 flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      >
        <h2
          class="text-base font-semibold mb-4 shrink-0"
          style="color: var(--semantic-text);"
        >Skills</h2>
        <p class="text-sm mb-4 shrink-0" style="color: var(--semantic-text-muted);">
          Available AI capabilities and workflows.
        </p>
        <div class="flex-1 overflow-y-auto min-h-0">
          <SkillList 
            ref="skillListRef"
            :selected-skill-name="selectedSkillName"
            @select-skill="handleSelectSkill"
          />
        </div>
      </div>
    </div>

    <!-- Skill Detail Panel -->
    <div class="flex-1 flex flex-col overflow-hidden">
      <div
        class="rounded-xl flex-1 flex flex-col overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      >
        <h2
          class="text-base font-semibold p-4 shrink-0"
          style="color: var(--semantic-text); border-bottom: 1px solid var(--color-border);"
        >Skill Detail</h2>
        <div class="flex-1 overflow-hidden">
          <SkillDetail 
            :skill-name="selectedSkillName"
            @skill-deleted="handleSkillDeleted"
            @error="handleSkillError"
          />
        </div>
      </div>
    </div>
  </div>
</template>