<!--
  SkillDetail — one workspace's skill, read and deleted by name.

  There is no `(global)` badge and no path line any more: both described
  a directory, and a skill is a row. What replaced the path is the
  companion-file count, shown only when it is non-zero — a bundled skill
  such as `pdf` (11 files) or `skill-creator` (17) is not one file, and
  telling the user so is the difference between "why does this skill keep
  talking about scripts I don't have" and a legible answer.

  Load and delete keep both outcomes: `runSyncResult` hands back either the
  payload or the reason, and the reason is rendered (or emitted), so a
  failed read cannot present as an empty detail pane.
-->
<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { Effect } from 'effect'
import { getSkillDetail, deleteSkill, type SkillDetail } from '../../api'
import { useWorkspacesStore } from '../../stores/workspaces'
import { SyncRemoteError } from '../../sync/SyncError'
import { runSyncResult } from '../../sync/runtime'

const props = defineProps<{
  skillName: string | null
}>()

const emit = defineEmits<{
  skillDeleted: [skillName: string]
  error: [message: string]
}>()

// The RESOLVED workspace, not the raw `activeWorkspaceId` ref — see
// RightSideBarSkillList.vue / DocumentsView.vue for why.
const workspacesStore = useWorkspacesStore()
const workspaceId = computed(() => workspacesStore.activeWorkspace?.id ?? null)

const skillDetail = ref<SkillDetail | null>(null)
const isLoading = ref(false)
const isDeleting = ref(false)
const error = ref<string | null>(null)
const showDeleteConfirm = ref(false)

/** A load needs both halves of the identity; either one missing means
 *  "nothing to show", which is not the same as "nothing there". */
const loadTarget = computed(() => {
  const name = props.skillName
  const ws = workspaceId.value
  return name && ws ? { name, workspaceId: ws } : null
})

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

watch(
  loadTarget,
  async (target) => {
    if (!target) {
      skillDetail.value = null
      error.value = null
      showDeleteConfirm.value = false
      isLoading.value = false
      return
    }

    isLoading.value = true
    error.value = null
    showDeleteConfirm.value = false

    const result = await runSyncResult(
      Effect.tryPromise({
        try: () => getSkillDetail(target.workspaceId, target.name),
        catch: (e) => new SyncRemoteError({ op: 'skills.detail', reason: fail(e) }),
      }),
      'skills.detail',
    )

    isLoading.value = false
    if (!result.ok) {
      skillDetail.value = null
      error.value = result.reason
      return
    }
    if (result.value.error_message) {
      skillDetail.value = null
      error.value = result.value.error_message
      return
    }
    if (result.value.skill) {
      skillDetail.value = result.value.skill
      return
    }
    // Neither a skill nor a reason: say so rather than leaving a blank
    // pane that reads like the load failed.
    skillDetail.value = null
    error.value = `Skill "${target.name}" not found in this workspace`
  },
  { immediate: true },
)

/** Companion files stored beside the body. Zero hides the row entirely. */
const assetCount = computed(() => {
  const raw = skillDetail.value?.asset_count
  const n = typeof raw === 'number' ? raw : Number(raw ?? 0)
  return Number.isFinite(n) && n > 0 ? n : 0
})

const confirmDelete = () => {
  showDeleteConfirm.value = true
}

const cancelDelete = () => {
  showDeleteConfirm.value = false
}

const handleDelete = async () => {
  const detail = skillDetail.value
  const ws = workspaceId.value
  if (!detail || !ws) return

  isDeleting.value = true
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => deleteSkill(ws, detail.name),
      catch: (e) => new SyncRemoteError({ op: 'skills.delete', reason: fail(e) }),
    }),
    'skills.delete',
  )
  isDeleting.value = false

  if (!result.ok) {
    emit('error', result.reason)
    return
  }
  if (result.value.success) {
    showDeleteConfirm.value = false
    emit('skillDeleted', detail.name)
  } else {
    emit('error', result.value.error_message || 'Failed to delete skill')
  }
}
</script>

<template>
  <div class="skill-detail h-full flex flex-col overflow-hidden" data-testid="skill-detail">
    <!-- Empty State -->
    <div
      v-if="!skillName"
      class="flex-1 flex items-center justify-center"
      data-testid="skill-detail-empty"
    >
      <p class="text-body" style="color: var(--semantic-text-muted)">
        Select a skill to view details
      </p>
    </div>

    <!-- Loading State -->
    <div v-else-if="isLoading" class="flex-1 flex items-center justify-center">
      <div class="flex items-center gap-3">
        <div
          class="w-5 h-5 border-2 rounded-full animate-spin"
          style="border-color: var(--color-violet); border-top-color: transparent"
        ></div>
        <span style="color: var(--semantic-text-muted)">Loading...</span>
      </div>
    </div>

    <!-- Error State. A failed read renders as a failure, never as an
         empty skill. -->
    <div
      v-else-if="error"
      class="flex-1 flex items-center justify-center"
      data-testid="skill-detail-error"
    >
      <p class="text-body" style="color: var(--color-red)">{{ error }}</p>
    </div>

    <!-- Skill Content -->
    <div v-else-if="skillDetail" class="flex-1 flex flex-col overflow-hidden">
      <!-- Header -->
      <div class="p-4 shrink-0" style="border-bottom: 1px solid var(--color-border)">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-3">
            <span class="text-title-sm">🛠️</span>
            <h3 class="text-lead font-semibold" style="color: var(--semantic-text)">
              {{ skillDetail.name }}
            </h3>
          </div>
          <button
            @click="confirmDelete"
            class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200"
            style="background-color: rgba(239, 68, 68, 0.1); color: var(--color-red)"
            title="Delete skill"
          >
            <svg
              class="w-4 h-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
          </button>
        </div>
        <p class="text-body" style="color: var(--semantic-text-muted)">
          {{ skillDetail.description }}
        </p>
        <!-- Only a bundle has companions. Showing "0 files" on every
             single-file skill would be noise, so the row is conditional. -->
        <p
          v-if="assetCount > 0"
          class="text-dense mt-2"
          style="color: var(--semantic-text-dim)"
          data-testid="skill-detail-assets"
        >
          <span class="font-medium">{{ assetCount }}</span>
          bundled file{{ assetCount === 1 ? '' : 's' }}
        </p>
      </div>

      <!-- Content -->
      <div class="flex-1 overflow-y-auto p-4">
        <h4 class="text-body font-medium mb-2 shrink-0" style="color: var(--semantic-text)">
          Content
        </h4>
        <pre
          class="text-dense p-4 rounded whitespace-pre-wrap"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text-muted)"
          >{{ skillDetail.content }}</pre>
      </div>

      <!-- Delete Confirmation Modal -->
      <div
        v-if="showDeleteConfirm"
        class="absolute inset-0 flex items-center justify-center z-10"
        style="background-color: rgba(0, 0, 0, 0.5)"
      >
        <div
          class="rounded-xl p-6 max-w-sm mx-4"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        >
          <h3 class="text-lead font-semibold mb-2" style="color: var(--semantic-text)">
            Delete Skill?
          </h3>
          <p class="text-body mb-4" style="color: var(--semantic-text-muted)">
            Are you sure you want to delete "<strong>{{ skillDetail.name }}</strong
            >"? This action cannot be undone.
          </p>
          <div class="flex gap-3 justify-end">
            <button
              @click="cancelDelete"
              class="px-4 py-2 rounded-lg text-body font-medium transition-colors duration-200"
              style="
                background-color: var(--semantic-content-bg);
                color: var(--semantic-text-muted);
                border: 1px solid var(--color-border);
              "
              :disabled="isDeleting"
            >
              Cancel
            </button>
            <button
              @click="handleDelete"
              class="px-4 py-2 rounded-lg text-body font-medium transition-colors duration-200"
              style="background-color: var(--color-red); color: white"
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
