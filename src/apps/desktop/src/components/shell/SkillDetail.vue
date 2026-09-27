<script setup lang="ts">
import { ref, watch, onMounted } from 'vue'
import { getSkillDetail, deleteSkill, ApiError, type SkillDetail } from '../../api'

const props = defineProps<{
  skillName: string | null
  /**
   * Workspace the skill is listed under. Required by the backend for a
   * local delete (is_global=false) — it addresses the row by
   * (is_global, cwd, name) — so it must be passed on delete, not just on
   * the detail fetch. Optional: hosts with no workspace context (the
   * settings overlay) get the backend's 400 and its error_message.
   */
  cwd?: string
}>()

onMounted(() => {
  console.log('[SkillDetail] MOUNTED! skillName prop:', props.skillName)
})

const emit = defineEmits<{
  skillDeleted: [skillName: string]
  error: [message: string]
}>()

const skillDetail = ref<SkillDetail | null>(null)
const isLoading = ref(false)
const isDeleting = ref(false)
const error = ref<string | null>(null)
const showDeleteConfirm = ref(false)

// Load skill detail when skillName changes
watch(() => props.skillName, async (newName) => {
  console.log('[SkillDetail] skillName prop changed to:', newName)
  console.log('[SkillDetail] current skillDetail.value:', skillDetail.value?.name)

  if (!newName) {
    skillDetail.value = null
    error.value = null
    showDeleteConfirm.value = false
    return
  }

  isLoading.value = true
  error.value = null

  try {
    console.log('[SkillDetail] calling getSkillDetail with:', newName, 'cwd:', props.cwd)
    const result = await getSkillDetail(newName, props.cwd)
    console.log('[SkillDetail] getSkillDetail result:', result)
    if (result.error_message) {
      console.log('[SkillDetail] got error_message:', result.error_message)
      error.value = result.error_message
      skillDetail.value = null
    } else if (result.skill) {
      console.log('[SkillDetail] got skill:', result.skill.name)
      skillDetail.value = result.skill
    } else {
      console.log('[SkillDetail] result has neither skill nor error_message')
    }
  } catch (err) {
    console.log('[SkillDetail] catch error:', err)
    error.value = err instanceof Error ? err.message : 'Failed to load skill details'
    skillDetail.value = null
  } finally {
    console.log('[SkillDetail] isLoading set to false, skillDetail.value:', skillDetail.value?.name)
    isLoading.value = false
  }
}, { immediate: true })

const confirmDelete = () => {
  showDeleteConfirm.value = true
}

const cancelDelete = () => {
  showDeleteConfirm.value = false
}

// A local delete with no cwd is unresolvable, so the backend answers 400
// with the reason in `error_message`. apiFetch throws on any non-2xx, so
// that reason lives in ApiError.body — `err.message` would only say
// "HTTP 400 Bad Request".
const deleteErrorMessage = (err: unknown): string => {
  if (err instanceof ApiError && err.body) {
    try {
      const parsed: unknown = JSON.parse(err.body)
      if (parsed && typeof parsed === 'object') {
        const message = (parsed as { error_message?: unknown }).error_message
        if (typeof message === 'string' && message !== '') return message
      }
    } catch {
      // Not JSON — fall through to the generic message below.
    }
  }
  return err instanceof Error ? err.message : 'Failed to delete skill'
}

const handleDelete = async () => {
  if (!skillDetail.value) return

  isDeleting.value = true
  try {
    const result = await deleteSkill(skillDetail.value.name, {
      is_global: skillDetail.value.is_global,
      cwd: props.cwd,
    })

    if (result.success) {
      showDeleteConfirm.value = false
      emit('skillDeleted', skillDetail.value.name)
    } else {
      emit('error', result.error_message || 'Failed to delete skill')
    }
  } catch (err) {
    emit('error', deleteErrorMessage(err))
  } finally {
    isDeleting.value = false
  }
}

defineExpose({})
</script>

<template>
  <div class="skill-detail h-full flex flex-col overflow-hidden">
    <!-- Empty State -->
    <div v-if="!skillName" class="flex-1 flex items-center justify-center">
      <p class="text-sm" style="color: var(--semantic-text-muted);">
        Select a skill to view details
      </p>
    </div>

    <!-- Loading State -->
    <div v-else-if="isLoading" class="flex-1 flex items-center justify-center">
      <div class="flex items-center gap-3">
        <div class="w-5 h-5 border-2 rounded-full animate-spin" style="border-color: var(--color-violet); border-top-color: transparent;"></div>
        <span style="color: var(--semantic-text-muted);">Loading...</span>
      </div>
    </div>

    <!-- Error State -->
    <div v-else-if="error" class="flex-1 flex items-center justify-center">
      <p class="text-sm" style="color: var(--color-red);">{{ error }}</p>
    </div>

    <!-- Skill Content -->
    <div v-else-if="skillDetail" class="flex-1 flex flex-col overflow-hidden">
      <!-- Header -->
      <div class="p-4 shrink-0" style="border-bottom: 1px solid var(--color-border);">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-3">
            <span class="text-lg">🛠️</span>
            <h3 class="text-base font-semibold" style="color: var(--semantic-text);">
              {{ skillDetail.name }}
            </h3>
          </div>
          <button
            @click="confirmDelete"
            class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200"
            style="background-color: rgba(239, 68, 68, 0.1); color: var(--color-red);"
            title="Delete skill"
          >
            <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
            </svg>
          </button>
        </div>
        <p class="text-sm" style="color: var(--semantic-text-muted);">
          {{ skillDetail.description }}
        </p>
        <div
          v-if="skillDetail.path"
          class="text-xs mt-2 p-2 rounded truncate"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text-dim);"
        >
          <span class="font-medium">Path:</span> {{ skillDetail.path }}
          <span v-if="skillDetail.is_global" class="ml-2">(global)</span>
        </div>
      </div>

      <!-- Content -->
      <div class="flex-1 overflow-y-auto p-4">
        <h4 class="text-sm font-medium mb-2 shrink-0" style="color: var(--semantic-text);">
          Content
        </h4>
        <pre
          class="text-xs p-4 rounded whitespace-pre-wrap"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text-muted);"
        >{{ skillDetail.content }}</pre>
      </div>

      <!-- Delete Confirmation Modal -->
      <div
        v-if="showDeleteConfirm"
        class="absolute inset-0 flex items-center justify-center z-10"
        style="background-color: rgba(0,0,0,0.5);"
      >
        <div
          class="rounded-xl p-6 max-w-sm mx-4"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <h3 class="text-base font-semibold mb-2" style="color: var(--semantic-text);">
            Delete Skill?
          </h3>
          <p class="text-sm mb-4" style="color: var(--semantic-text-muted);">
            Are you sure you want to delete "<strong>{{ skillDetail.name }}</strong>"? This action cannot be undone.
          </p>
          <div class="flex gap-3 justify-end">
            <button
              @click="cancelDelete"
              class="px-4 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
              style="background-color: var(--semantic-content-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
              :disabled="isDeleting"
            >
              Cancel
            </button>
            <button
              @click="handleDelete"
              class="px-4 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
              style="background-color: var(--color-red); color: white;"
              :disabled="isDeleting"
            >
              {{ isDeleting ? 'Deleting...' : 'Delete' }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
