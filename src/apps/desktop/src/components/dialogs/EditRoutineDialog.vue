<script setup lang="ts">
// EditRoutineDialog — same shape as AddRoutineDialog, but
// prefilled with the routine's current values. Emits `submit`
// instead of `create`. The parent (Sidebar) wires `submit` to
// `workspacesStore.updateRoutine(...)`.
//
// Why a separate file (not a shared base component): the
// AddTaskDialog / RenameTaskModal pair in this codebase is two
// files too. We follow that precedent — small duplication beats
// premature abstraction (design doc rule: "three lines of
// duplication beat one premature abstraction"; the two dialogs
// are about 200 lines each, but their prop shapes + emit names
// differ enough that abstracting would obscure the intent).

import { ref, watch, nextTick } from 'vue'
import type { RoutineMeta } from '../../stores/workspaces'

export interface EditRoutineParams {
  name: string
  schedule: string
  initial_prompt: string
  enabled: boolean
}

const props = defineProps<{
  show: boolean
  routine: RoutineMeta | null
  taskName: string
  apiError?: string | null
}>()

const emit = defineEmits<{
  close: []
  submit: [params: EditRoutineParams]
}>()

const name = ref('')
const initialPrompt = ref('')
const enabled = ref(true)
const customCron = ref('')
const useCustom = ref(false)
const localError = ref<string | null>(null)
const nameInput = ref<HTMLInputElement | null>(null)

const PRESETS: { id: string; label: string; match: (cron: string) => boolean; build: (h: number, m: number) => string; withTime: boolean }[] = [
  { id: 'every5',  label: 'Every 5 min',         match: (c) => c === '*/5 * * * *',  build: () => '*/5 * * * *',  withTime: false },
  { id: 'every30', label: 'Every 30 min',        match: (c) => c === '*/30 * * * *', build: () => '*/30 * * * *', withTime: false },
  { id: 'hourly',  label: 'Every hour',          match: (c) => c === '0 * * * *',    build: () => '0 * * * *',    withTime: false },
  { id: 'every6h', label: 'Every 6 hours',       match: (c) => c === '0 */6 * * *',  build: () => '0 */6 * * *',  withTime: false },
  // The remaining presets are time-aware; matching them by exact
  // string is the simplest path. If the user changed the time
  // inside a time-aware preset, we fall through to "custom".
  { id: 'daily',   label: 'Daily at',            match: (c) => /^\d+ \d+ \* \* \*$/.test(c),         build: (h, m) => `${m} ${h} * * *`,   withTime: true },
  { id: 'weekday', label: 'Weekdays at',         match: (c) => /^\d+ \d+ \* \* 1-5$/.test(c),       build: (h, m) => `${m} ${h} * * 1-5`, withTime: true },
  { id: 'weekly',  label: 'Weekly on Monday',    match: (c) => /^\d+ \d+ \* \* 1$/.test(c),         build: (h, m) => `${m} ${h} * * 1`,   withTime: true },
  { id: 'monthly', label: 'Monthly on the 1st',  match: (c) => /^\d+ \d+ 1 \* \*$/.test(c),         build: (h, m) => `${m} ${h} 1 * *`,   withTime: true },
]

const selectedPresetId = ref<string>('every5')
const timeHour = ref(9)
const timeMinute = ref(0)
const currentSchedule = ref<string>('*/5 * * * *')

// Pre-fill on open. Detect which preset the current schedule
// matches (if any) and seed the form.
function applyPrefill() {
  if (!props.routine) return
  name.value = props.taskName
  initialPrompt.value = props.routine.initial_prompt
  enabled.value = props.routine.enabled

  const sched = props.routine.schedule
  const matched = PRESETS.find((p) => p.match(sched))
  if (matched) {
    selectedPresetId.value = matched.id
    useCustom.value = false
    // For time-aware presets, parse hour/minute out of the cron.
    if (matched.withTime) {
      const parts = sched.split(/\s+/)
      timeMinute.value = Number(parts[0])
      timeHour.value = Number(parts[1])
    }
    currentSchedule.value = sched
  } else {
    useCustom.value = true
    customCron.value = sched
    currentSchedule.value = sched
  }
}

watch(() => props.show, (show) => {
  if (show) {
    localError.value = null
    applyPrefill()
    nextTick(() => nameInput.value?.focus())
  }
})

watch(() => props.apiError, (msg) => {
  if (msg) localError.value = msg
})

function recomputeSchedule() {
  if (useCustom.value) {
    currentSchedule.value = customCron.value.trim()
  } else {
    const preset = PRESETS.find((p) => p.id === selectedPresetId.value)
    if (preset) currentSchedule.value = preset.build(timeHour.value, timeMinute.value)
  }
}
watch([selectedPresetId, timeHour, timeMinute], recomputeSchedule)
watch(useCustom, () => recomputeSchedule())
watch(customCron, () => recomputeSchedule())

// (Same 5-field validator as AddRoutineDialog.vue. Inlined here
// rather than extracted to a shared module because the two
// dialogs are intentionally small and the validator is the only
// shared piece of logic — extracting it now would create a
// helper file with a single function. If a third caller shows up,
// extract then.)
const CRON_FIELD_MAX = [59, 23, 31, 12, 6]
function validate5FieldCron(expr: string): string | null {
  const fields = expr.trim().split(/\s+/)
  if (fields.length !== 5) return 'Cron must have exactly 5 fields'
  for (let i = 0; i < 5; i++) {
    const f = fields[i]!
    const max = CRON_FIELD_MAX[i]!
    for (const part of f.split(',')) {
      let step = 1
      let range = part
      const slash = part.indexOf('/')
      if (slash >= 0) {
        const s = Number(part.slice(slash + 1))
        if (!Number.isInteger(s) || s <= 0) return `Bad step in field ${i + 1}`
        step = s
        range = part.slice(0, slash)
      }
      let lo: number, hi: number
      if (range === '*') { lo = 0; hi = max }
      else if (range.includes('-')) {
        const [a, b] = range.split('-')
        lo = Number(a); hi = Number(b)
        if (!Number.isInteger(lo) || !Number.isInteger(hi)) return `Bad range in field ${i + 1}`
      } else {
        const v = Number(range)
        if (!Number.isInteger(v)) return `Bad value in field ${i + 1}`
        if (v < 0 || v > max) return `Value out of range in field ${i + 1}`
        continue
      }
      if (lo < 0 || hi > max || lo > hi) return `Range out of bounds in field ${i + 1}`
    }
  }
  return null
}

function pickPreset(id: string) { selectedPresetId.value = id; useCustom.value = false }
function enableCustom() { useCustom.value = true }

function handleSubmit() {
  if (!name.value.trim() || !initialPrompt.value.trim()) return
  const schedule = currentSchedule.value
  if (!schedule) { localError.value = 'Schedule is required'; return }
  const cronErr = validate5FieldCron(schedule)
  if (cronErr) { localError.value = cronErr; return }
  localError.value = null
  emit('submit', {
    name: name.value.trim(),
    schedule,
    initial_prompt: initialPrompt.value.trim(),
    enabled: enabled.value,
  })
}
function handleClose() { emit('close') }
function handleKeydown(event: KeyboardEvent) { if (event.key === 'Escape') handleClose() }
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show && routine"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
        @keydown="handleKeydown"
      >
        <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="handleClose" />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 80vh;"
          data-testid="edit-routine-dialog"
        >
          <div class="px-5 pt-5 pb-4">
            <h3 class="text-base font-semibold" style="color: var(--semantic-text);">Edit Routine</h3>
            <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
              Editing "{{ taskName }}"
            </p>
          </div>
          <div class="flex-1 overflow-y-auto px-5 pb-4 space-y-4">
            <div>
              <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Name</label>
              <input
                ref="nameInput"
                v-model="name"
                type="text"
                class="w-full px-3 py-2 rounded-lg text-sm outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                data-testid="edit-routine-name"
              />
            </div>
            <div>
              <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Initial prompt</label>
              <textarea
                v-model="initialPrompt"
                rows="3"
                class="w-full px-3 py-2 rounded-lg text-sm outline-none resize-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                data-testid="edit-routine-initial-prompt"
              />
            </div>
            <div>
              <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Schedule</label>
              <div class="flex flex-wrap gap-1.5">
                <button
                  v-for="preset in PRESETS"
                  :key="preset.id"
                  type="button"
                  @click="pickPreset(preset.id)"
                  :data-testid="`edit-preset-${preset.id}`"
                  class="px-2 py-1 rounded-md text-xs transition-all"
                  :style="{
                    backgroundColor: (!useCustom && selectedPresetId === preset.id) ? 'var(--color-aqua)' : 'var(--semantic-sidebar-bg)',
                    color: (!useCustom && selectedPresetId === preset.id) ? 'var(--color-bg)' : 'var(--semantic-text-muted)',
                    border: '1px solid var(--color-border)',
                  }"
                >
                  {{ preset.label }}
                </button>
              </div>
              <div v-if="!useCustom && PRESETS.find(p => p.id === selectedPresetId)?.withTime" class="flex items-center gap-2 mt-2">
                <input v-model.number="timeHour" type="number" min="0" max="23" class="w-16 px-2 py-1 rounded-md text-xs"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                  data-testid="edit-time-hour" />
                <span style="color: var(--semantic-text-dim);">:</span>
                <input v-model.number="timeMinute" type="number" min="0" max="59" class="w-16 px-2 py-1 rounded-md text-xs"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                  data-testid="edit-time-minute" />
              </div>
              <div class="mt-2 flex items-center gap-2">
                <input type="checkbox" :checked="useCustom" @change="enableCustom" id="edit-custom-cron-toggle" data-testid="edit-custom-cron-toggle" />
                <label for="edit-custom-cron-toggle" class="text-xs" style="color: var(--semantic-text-dim);">Custom (cron expression)</label>
              </div>
              <input v-if="useCustom" v-model="customCron" type="text" placeholder="*/5 * * * *" class="w-full mt-2 px-3 py-2 rounded-lg text-sm font-mono outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                data-testid="edit-custom-cron-input" />
              <p class="mt-1 text-[10px]" style="color: var(--semantic-text-dim);" data-testid="edit-schedule-preview">
                Cron: <span class="font-mono">{{ currentSchedule || '—' }}</span>
              </p>
            </div>
            <div class="flex items-center gap-2">
              <input type="checkbox" v-model="enabled" id="edit-enabled-toggle" data-testid="edit-routine-enabled" />
              <label for="edit-enabled-toggle" class="text-sm" style="color: var(--semantic-text);">Enabled</label>
            </div>
            <p v-if="localError" class="text-xs" style="color: var(--semantic-error);" data-testid="edit-routine-error">
              {{ localError }}
            </p>
          </div>
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button @click="handleClose" class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
              style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);">Cancel</button>
            <button @click="handleSubmit" :disabled="!name.trim() || !initialPrompt.trim()"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
              data-testid="edit-routine-submit">Save</button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.modal-enter-active, .modal-leave-active { transition: all 0.2s ease-out; }
.modal-enter-from, .modal-leave-to { opacity: 0; }
.modal-enter-from > div:last-child, .modal-leave-to > div:last-child { transform: scale(0.95) translateY(10px); }
</style>
