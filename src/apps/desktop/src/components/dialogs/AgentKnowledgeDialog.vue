<!--
  AgentKnowledgeDialog — modal for adding a markdown knowledge file to an Agent.

  Body:
    - file_path (required, must be absolute)
    - label (optional)

  Public API:
    props:  show (boolean), busy (boolean), error (string | null)
    emits:  close, create(file_path: string, label: string)

  Plan: 2026-08-15-agent-mode (Task 16)
  Updated 2026-08-20 to support `busy` + `error` so AppLayout can
  show submit progress + server error without unmounting the dialog.
  Also added a "Browse" button that opens FilePickerDialog in 'file'
  mode — typing absolute paths by hand is error-prone.
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'

const props = withDefaults(
  defineProps<{ show: boolean; busy?: boolean; error?: string | null }>(),
  { busy: false, error: null },
)

const emit = defineEmits<{
  close: []
  create: [filePath: string, label: string]
}>()

const filePath = ref('')
const label = ref('')
const pathInput = ref<HTMLInputElement | null>(null)
const pathTouched = ref(false)
const showPicker = ref(false)

const pathError = computed<string | null>(() => {
  if (!pathTouched.value) return null
  if (filePath.value.length === 0) return 'Path is required'
  if (!filePath.value.startsWith('/')) return 'Path must be absolute'
  return null
})

const canSubmit = computed(
  () => filePath.value.startsWith('/') && filePath.value.length > 0 && !props.busy,
)

const handleCreate = () => {
  if (!canSubmit.value) return
  // Don't close the dialog here — let the parent decide based on the
  // server response. The parent toggles `show=false` on success.
  emit('create', filePath.value, label.value)
}

const handleClose = () => {
  if (props.busy) return
  showPicker.value = false
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && !props.busy && !showPicker.value) handleClose()
}

const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  // FilePickerDialog calls this with `''` on first open (to list the
  // system root) and with a folder path when the user navigates.
  // Empty path → use `getSystemFolder` (same pattern as AddAgentDialog)
  // because the backend rejects `path=''` in /system/folder.
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

const handleFileSelected = (path: string) => {
  filePath.value = path
  pathTouched.value = true
  showPicker.value = false
  // Auto-fill the label from the basename if empty.
  if (!label.value.trim()) {
    const idx = path.lastIndexOf('/')
    const base = idx === -1 ? path : path.slice(idx + 1)
    const dot = base.lastIndexOf('.')
    label.value = dot > 0 ? base.slice(0, dot) : base
  }
  pathInput.value?.focus()
}

watch(() => props.show, async (show) => {
  if (show) {
    filePath.value = ''
    label.value = ''
    pathTouched.value = false
    showPicker.value = false
    await nextTick()
    pathInput.value?.focus()
  }
})
</script>

<template>
  <Teleport to="body">
    <Transition name="agent-knowledge-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-knowledge-title"
        data-testid="agent-knowledge-dialog"
      >
        <div class="absolute inset-0 backdrop-blur-md" style="background: rgba(0, 0, 0, 0.6);" @click="handleClose" />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 70vh;"
        >
          <div class="px-5 pt-5 pb-4">
            <h3 id="agent-knowledge-title" class="text-base font-semibold" style="color: var(--semantic-text);">
              Add Knowledge
            </h3>
            <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
              Attach a markdown file the agent will read at chat start
            </p>
          </div>
          <div class="px-5 pb-4">
            <div class="flex items-center justify-between mb-2">
              <label class="text-xs font-medium" style="color: var(--semantic-text-dim);">File Path (absolute)</label>
              <button
                type="button"
                @click="showPicker = true"
                data-testid="agent-knowledge-browse"
                class="text-[11px] font-medium px-2 py-0.5 rounded hover:opacity-80"
                style="background: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
                :disabled="props.busy"
              >
                📂 Browse…
              </button>
            </div>
            <input
              ref="pathInput"
              v-model="filePath"
              type="text"
              placeholder="/home/me/docs/spec.md"
              data-testid="agent-knowledge-path"
              :aria-invalid="pathError !== null"
              class="w-full px-3 py-2 rounded-lg text-sm font-mono outline-none"
              :style="{
                backgroundColor: 'var(--semantic-sidebar-bg)',
                border: `1px solid ${pathError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: 'var(--semantic-text)',
              }"
              @input="pathTouched = true"
              @blur="pathTouched = true"
              @keyup.enter="handleCreate"
            />
            <p v-if="pathError" class="text-xs mt-1" style="color: var(--color-red);" data-testid="agent-knowledge-path-error">
              {{ pathError }}
            </p>
          </div>
          <div class="px-5 pb-4">
            <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Label (optional)</label>
            <input
              v-model="label"
              type="text"
              placeholder="Project spec"
              data-testid="agent-knowledge-label"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
            />
          </div>
          <div v-if="props.error" data-testid="agent-knowledge-error" class="mx-5 mb-3 text-xs p-2 rounded" style="background: var(--color-red); color: var(--color-bg);">
            {{ props.error }}
          </div>
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button type="button" @click="handleClose" :disabled="props.busy" data-testid="agent-knowledge-cancel" class="px-3 py-1.5 rounded-lg text-sm font-medium disabled:opacity-50" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);">Cancel</button>
            <button type="button" @click="handleCreate" :disabled="!canSubmit" data-testid="agent-knowledge-submit" class="px-3 py-1.5 rounded-lg text-sm font-medium disabled:opacity-50" style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);">
              <span v-if="props.busy">Adding…</span>
              <span v-else>Add</span>
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <FilePickerDialog
    v-model="showPicker"
    mode="file"
    :load-items="loadItemsForPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="true"
    title="Select Knowledge Markdown File"
    @select="handleFileSelected"
  />
</template>

<style scoped>
.agent-knowledge-modal-enter-active,
.agent-knowledge-modal-leave-active {
  transition: opacity 0.2s ease;
}
.agent-knowledge-modal-enter-from,
.agent-knowledge-modal-leave-to {
  opacity: 0;
}
</style>