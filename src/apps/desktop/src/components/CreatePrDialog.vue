<script setup lang="ts">
/**
 * "Create a PR" dialog. Mounted by ChatView.vue when the user clicks
 * "Create a PR" in the WorktreeMenu.
 *
 * On mount, calls api.getGitWorktreeInfo(worktreePath) to pre-fill the
 * title and body. User can edit before clicking "Create". The submit
 * calls api.createGitPr(...) and emits 'pr-created' with the URL on
 * success or 'error' with the message on failure.
 */
import { ref, onMounted } from 'vue'
import * as api from '../api'

const props = defineProps<{
  worktreePath: string
}>()

const emit = defineEmits<{
  (e: 'pr-created', url: string): void
  (e: 'error', message: string): void
  (e: 'close'): void
}>()

const base = ref('main')
const title = ref('')
const body = ref('')
const isSubmitting = ref(false)
const isLoading = ref(true)
const isRegenerating = ref(false)

onMounted(async () => {
  try {
    const info = await api.getGitWorktreeInfo(props.worktreePath)
    base.value = info.default_base || 'main'
    title.value = info.draft_title
    body.value = info.draft_body
  } catch (err) {
    emit('error', `Failed to load worktree info: ${err}`)
  } finally {
    isLoading.value = false
  }
})

// Re-fetch the worktree info against the CURRENT base branch value and
// overwrite title + body. See design decision #11 for why this is
// useful. Pass the current base explicitly so the diff is computed
// against whatever the user has typed (not the auto-detected default).
const onRegenerate = async () => {
  if (isRegenerating.value || isSubmitting.value) return
  isRegenerating.value = true
  try {
    const info = await api.getGitWorktreeInfo(props.worktreePath, base.value)
    title.value = info.draft_title
    body.value = info.draft_body
  } catch (err) {
    emit('error', `Failed to regenerate: ${err}`)
  } finally {
    isRegenerating.value = false
  }
}

const onSubmit = async () => {
  if (isSubmitting.value || title.value.trim() === '') return
  isSubmitting.value = true
  try {
    const resp = await api.createGitPr(props.worktreePath, base.value, title.value, body.value)
    if (resp.success) {
      emit('pr-created', resp.pr_url)
    } else {
      emit('error', resp.error_message || 'Unknown error from gh pr create')
    }
  } catch (err) {
    emit('error', `Failed to create PR: ${err}`)
  } finally {
    isSubmitting.value = false
  }
}

const onClose = () => {
  if (!isSubmitting.value) emit('close')
}
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center p-4"
    style="background-color: rgba(0, 0, 0, 0.5)"
    @click.self="onClose"
  >
    <div
      class="w-full max-w-2xl rounded-lg shadow-xl overflow-hidden"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      data-testid="create-pr-dialog"
    >
      <div
        class="px-4 py-3 flex items-center justify-between"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <h2 class="text-sm font-semibold" style="color: var(--semantic-text)">
          🔀 Create a pull request
        </h2>
        <div class="flex items-center gap-2">
          <!-- Auto-fill button: re-fetches worktree info against the
               CURRENT base branch value, overwrites title + body.
               Disabled while submitting (avoid race) or while a
               regenerate is already in flight (avoid double-fire). -->
          <button
            @click="onRegenerate"
            :disabled="isRegenerating || isSubmitting || isLoading"
            data-testid="create-pr-regenerate"
            title="Re-fill title and body from the latest commit and diff against the current base branch"
            class="px-2 py-1 text-xs rounded flex items-center gap-1.5"
            :class="
              isRegenerating || isSubmitting || isLoading
                ? 'opacity-50 cursor-not-allowed'
                : 'hover:opacity-80'
            "
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text-dim);
            "
          >
            <span
              v-if="isRegenerating"
              class="w-3 h-3 border-2 rounded-full animate-spin"
              style="border-color: var(--semantic-text-dim); border-top-color: transparent"
            ></span>
            <span v-else>↻</span>
            <span>Auto-fill</span>
          </button>
          <button
            @click="onClose"
            :disabled="isSubmitting"
            class="opacity-60 hover:opacity-100"
            style="color: var(--semantic-text)"
          >
            ✕
          </button>
        </div>
      </div>

      <div v-if="isLoading" class="px-4 py-8 text-center text-xs" style="color: var(--semantic-text-dim)">
        Loading worktree info...
      </div>

      <div v-else class="px-4 py-4 space-y-3">
        <div>
          <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim)">
            Base branch
          </label>
          <input
            v-model="base"
            data-testid="create-pr-base"
            type="text"
            class="w-full px-2 py-1.5 text-xs rounded font-mono"
            style="
              background-color: var(--semantic-input-bg, var(--semantic-card-bg));
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            placeholder="main"
          />
        </div>
        <div>
          <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim)">
            Title
          </label>
          <input
            v-model="title"
            data-testid="create-pr-title"
            type="text"
            class="w-full px-2 py-1.5 text-xs rounded"
            style="
              background-color: var(--semantic-input-bg, var(--semantic-card-bg));
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            placeholder="PR title"
          />
        </div>
        <div>
          <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim)">
            Body
          </label>
          <textarea
            v-model="body"
            data-testid="create-pr-body"
            rows="8"
            class="w-full px-2 py-1.5 text-xs rounded font-mono"
            style="
              background-color: var(--semantic-input-bg, var(--semantic-card-bg));
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            placeholder="Describe the changes..."
          ></textarea>
        </div>
      </div>

      <div
        class="px-4 py-3 flex items-center justify-end gap-2"
        style="border-top: 1px solid var(--color-border)"
      >
        <button
          @click="onClose"
          :disabled="isSubmitting"
          class="px-3 py-1.5 text-xs rounded"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
        >
          Cancel
        </button>
        <button
          @click="onSubmit"
          :disabled="isSubmitting || isLoading || title.trim() === ''"
          data-testid="create-pr-submit"
          class="px-3 py-1.5 text-xs font-medium rounded flex items-center gap-1.5"
          :class="
            isSubmitting || isLoading || title.trim() === ''
              ? 'opacity-50 cursor-not-allowed'
              : 'hover:opacity-80'
          "
          style="
            background-color: var(--color-violet);
            color: white;
          "
        >
          <span
            v-if="isSubmitting"
            class="w-3 h-3 border-2 rounded-full animate-spin"
            style="border-color: white; border-top-color: transparent"
          ></span>
          <span>{{ isSubmitting ? 'Creating...' : 'Create PR' }}</span>
        </button>
      </div>
    </div>
  </div>
</template>