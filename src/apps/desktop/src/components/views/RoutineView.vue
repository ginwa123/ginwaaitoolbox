<!--
  RoutineView — config surface for a Routine workspace item
  (`item_type='routine'`).

  Fetches its own data via GET /api/workspaces/:ws/items/:item/routine
  on mount (and when itemId changes). Edits description / instruction /
  schedule / enabled, saves via PATCH, fires immediately via the
  store's runRoutineItem (POST .../routines/:id/run).

  Schedule semantics (mirror the backend):
    - '' (empty) = manual-run only, no auto-fire.
    - otherwise a 5-field cron, validated client-side AND server-side.

  Public API:
    props:  item (WorkspaceItem), workspaceId (string), itemId (string)

  Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md
-->
<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue'
import { getRoutineItem, updateRoutineItem, type WorkspaceRoutine, type WorkspaceItem } from '../../api'
import { useWorkspacesStore } from '../../stores/workspaces'

const props = defineProps<{
  item: WorkspaceItem
  workspaceId: string
  itemId: string
}>()

const workspacesStore = useWorkspacesStore()

const loading = ref(true)
const loadError = ref<string | null>(null)
const saving = ref(false)
const saveError = ref<string | null>(null)
const running = ref(false)
const runError = ref<string | null>(null)

const description = ref('')
const instruction = ref('')
const schedule = ref('')
const enabled = ref(true)
const lastStatus = ref('')
const lastRunAt = ref('')
const nextRunAt = ref('')

async function load() {
  loading.value = true
  loadError.value = null
  try {
    const { routine } = await getRoutineItem(props.workspaceId, props.itemId)
    applyRoutine(routine)
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loading.value = false
  }
}

function applyRoutine(routine: WorkspaceRoutine) {
  description.value = routine.description ?? ''
  instruction.value = routine.instruction ?? ''
  schedule.value = routine.schedule ?? ''
  enabled.value = routine.enabled
  lastStatus.value = routine.last_status ?? ''
  lastRunAt.value = routine.last_run_at ?? ''
  nextRunAt.value = routine.next_run_at ?? ''
}

// Compact 5-field cron check (empty = manual-only, always valid).
// Mirrors the backend's POSIX parser loosely; the server re-validates
// and returns 400 on anything we let through.
function validateSchedule(expr: string): string | null {
  const trimmed = expr.trim()
  if (trimmed === '') return null
  const fields = trimmed.split(/\s+/)
  if (fields.length !== 5) return 'Schedule must have exactly 5 fields (minute hour day-of-month month day-of-week), or be empty for manual-only'
  for (const f of fields) {
    if (!/^[0-9*,\-/]+$/.test(f)) return `Invalid schedule field: "${f}"`
  }
  return null
}

const scheduleError = computed<string | null>(() => validateSchedule(schedule.value))
const canSave = computed(() => !saving.value && scheduleError.value === null)

async function handleSave() {
  if (!canSave.value) return
  saving.value = true
  saveError.value = null
  try {
    const { routine } = await updateRoutineItem(props.workspaceId, props.itemId, {
      description: description.value,
      instruction: instruction.value,
      schedule: schedule.value.trim(),
      enabled: enabled.value,
    })
    applyRoutine(routine)
  } catch (err) {
    saveError.value = err instanceof Error ? err.message : String(err)
  } finally {
    saving.value = false
  }
}

async function handleRunNow() {
  running.value = true
  runError.value = null
  try {
    await workspacesStore.runRoutineItem(props.workspaceId, props.itemId, props.itemId)
    // Refresh status after the fire (last_status flips to success).
    await load()
  } catch (err) {
    runError.value = err instanceof Error ? err.message : String(err)
  } finally {
    running.value = false
  }
}

const statusLine = computed(() => {
  const parts: string[] = []
  if (lastStatus.value) parts.push(`Last: ${lastStatus.value}`)
  if (lastRunAt.value) parts.push(`ran ${lastRunAt.value}`)
  if (nextRunAt.value) parts.push(`next ${nextRunAt.value}`)
  else parts.push('manual-only (no schedule)')
  return parts.join(' · ')
})

onMounted(load)
watch(() => props.itemId, load)
</script>

<template>
  <div class="flex flex-col gap-4 p-5 max-w-2xl" data-testid="routine-view">
    <div class="flex items-center gap-2">
      <span aria-hidden="true" class="text-lg">⏰</span>
      <h2 class="text-base font-semibold" style="color: var(--semantic-text);">
        {{ item.name ?? 'Routine' }}
      </h2>
    </div>

    <div v-if="loading" class="text-sm" style="color: var(--semantic-text-dim);">
      Loading routine…
    </div>

    <div v-else-if="loadError" class="text-sm" style="color: var(--color-red);" data-testid="routine-error">
      Failed to load routine: {{ loadError }}
    </div>

    <template v-else>
      <p class="text-xs" style="color: var(--semantic-text-dim);" data-testid="routine-status">
        {{ statusLine }}
      </p>

      <div>
        <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim);">Description</label>
        <input
          v-model="description"
          type="text"
          placeholder="What is this routine for?"
          data-testid="routine-description"
          class="w-full px-3 py-2 rounded-lg text-sm outline-none"
          :style="{ backgroundColor: 'var(--semantic-sidebar-bg)', border: '1px solid var(--color-border)', color: 'var(--semantic-text)' }"
        />
      </div>

      <div>
        <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim);">Instruction (fired on each run)</label>
        <textarea
          v-model="instruction"
          rows="4"
          placeholder="Tell the agent what to do on every fire…"
          data-testid="routine-instruction"
          class="w-full px-3 py-2 rounded-lg text-sm outline-none font-mono"
          :style="{ backgroundColor: 'var(--semantic-sidebar-bg)', border: '1px solid var(--color-border)', color: 'var(--semantic-text)' }"
        />
      </div>

      <div>
        <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim);">Schedule (cron — empty = manual-only)</label>
        <input
          v-model="schedule"
          type="text"
          placeholder="0 9 * * *"
          data-testid="routine-schedule"
          :aria-invalid="scheduleError !== null"
          class="w-full px-3 py-2 rounded-lg text-sm outline-none font-mono"
          :style="{
            backgroundColor: 'var(--semantic-sidebar-bg)',
            border: `1px solid ${scheduleError ? 'var(--color-red)' : 'var(--color-border)'}`,
            color: 'var(--semantic-text)',
          }"
        />
        <p v-if="scheduleError" class="text-xs mt-1" style="color: var(--color-red);">{{ scheduleError }}</p>
        <p v-else class="text-xs mt-1" style="color: var(--semantic-text-dim);">
          5 fields: minute hour day-of-month month day-of-week — e.g. <span class="font-mono">*/5 * * * *</span>, <span class="font-mono">0 9 * * 1-5</span>
        </p>
      </div>

      <label class="flex items-center gap-2 text-sm" style="color: var(--semantic-text);">
        <input v-model="enabled" type="checkbox" data-testid="routine-enabled" />
        Enabled
      </label>

      <p v-if="saveError" class="text-xs" style="color: var(--color-red);">{{ saveError }}</p>
      <p v-if="runError" class="text-xs" style="color: var(--color-red);">{{ runError }}</p>

      <div class="flex gap-2">
        <button
          type="button"
          :disabled="!canSave"
          data-testid="routine-save"
          class="px-3 py-1.5 rounded-lg text-sm font-medium disabled:opacity-50"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
          @click="handleSave"
        >
          {{ saving ? 'Saving…' : 'Save' }}
        </button>
        <button
          type="button"
          :disabled="running || !enabled"
          data-testid="routine-run"
          class="px-3 py-1.5 rounded-lg text-sm font-medium disabled:opacity-50"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
          @click="handleRunNow"
        >
          {{ running ? 'Firing…' : '▶ Run now' }}
        </button>
      </div>
    </template>
  </div>
</template>
