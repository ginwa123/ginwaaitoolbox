<script setup lang="ts">
// AddRoutineDialog — modal form for creating a routine. Emits
// `create: [params]` on submit; the parent (Sidebar) calls
// `workspacesStore.addTask(...)`.
//
// Schedule picker: preset chips + a "Custom (cron expression)"
// toggle that reveals a 5-field cron text input. The cron
// validation is local (a small inline `validate5FieldCron`); the
// server also validates and returns 400 on bad input. We surface
// the 400 from the parent in the `apiError` prop.
//
// The EditRoutineDialog (Task 6.3) reuses the SAME template via
// a `prefill` prop. To keep them as two separate files (matching
// the AddTaskDialog / RenameTaskModal precedent), the
// prefill-handling lives in EditRoutineDialog; the bare
// AddRoutineDialog starts empty.

import { ref, watch, nextTick } from 'vue'

export interface AddRoutineParams {
  name: string
  description?: string
  initial_prompt: string
  schedule: string
  enabled: boolean
}

const props = defineProps<{
  show: boolean
  projectName?: string
  apiError?: string | null
}>()

const emit = defineEmits<{
  close: []
  create: [params: AddRoutineParams]
}>()

const name = ref('')
const description = ref('')
const initialPrompt = ref('')
const enabled = ref(true)
const customCron = ref('')
const useCustom = ref(false)
const localError = ref<string | null>(null)
const nameInput = ref<HTMLInputElement | null>(null)

// Preset → cron. Each preset is "5-field cron" (minute hour
// day-of-month month day-of-week). The Time-of-day inputs are
// local-state vars that the selected preset copies into the
// schedule string when the user toggles a preset.
const PRESETS: { id: string; label: string; build: (h: number, m: number) => string; withTime: boolean }[] = [
  { id: 'every5',  label: 'Every 5 min',         build: () => '*/5 * * * *',   withTime: false },
  { id: 'every30', label: 'Every 30 min',        build: () => '*/30 * * * *',  withTime: false },
  { id: 'hourly',  label: 'Every hour',          build: () => '0 * * * *',     withTime: false },
  { id: 'every6h', label: 'Every 6 hours',       build: () => '0 */6 * * *',   withTime: false },
  { id: 'daily',   label: 'Daily at',            build: (h, m) => `${m} ${h} * * *`,     withTime: true },
  { id: 'weekday', label: 'Weekdays at',         build: (h, m) => `${m} ${h} * * 1-5`,   withTime: true },
  { id: 'weekly',  label: 'Weekly on Monday',    build: (h, m) => `${m} ${h} * * 1`,     withTime: true },
  { id: 'monthly', label: 'Monthly on the 1st',  build: (h, m) => `${m} ${h} 1 * *`,     withTime: true },
]

const selectedPresetId = ref<string>('every5')
const timeHour = ref(9)
const timeMinute = ref(0)

// Build the cron string from the current preset/time selection.
// When `useCustom` is true, the cron is whatever the user typed
// in the custom field.
const currentSchedule = ref<string>('*/5 * * * *')
function recomputeSchedule() {
  if (useCustom.value) {
    currentSchedule.value = customCron.value.trim()
  } else {
    const preset = PRESETS.find((p) => p.id === selectedPresetId.value)
    if (preset) {
      currentSchedule.value = preset.build(timeHour.value, timeMinute.value)
    }
  }
}

watch([selectedPresetId, timeHour, timeMinute], recomputeSchedule)
watch(useCustom, () => recomputeSchedule())
watch(customCron, () => recomputeSchedule())

// 5-field cron validation. Accepts "*", "N", "N-M", "*/S",
// "N,M", "N-M/S". Range check per field. Mirrors the server's
// 5-field POSIX parser exactly (see cron.zig in the backend).
const CRON_FIELD_MAX = [59, 23, 31, 12, 6] // minute, hour, dom, month, dow
function validate5FieldCron(expr: string): string | null {
  const fields = expr.trim().split(/\s+/)
  if (fields.length !== 5) return 'Cron must have exactly 5 fields (minute hour day-of-month month day-of-week)'
  for (let i = 0; i < 5; i++) {
    const f = fields[i]!
    const max = CRON_FIELD_MAX[i]!
    for (const part of f.split(',')) {
      let step = 1
      let range = part
      const slash = part.indexOf('/')
      if (slash >= 0) {
        const s = Number(part.slice(slash + 1))
        if (!Number.isInteger(s) || s <= 0) return `Bad step in field ${i + 1}: "${part}"`
        step = s
        range = part.slice(0, slash)
      }
      let lo: number, hi: number
      if (range === '*') { lo = 0; hi = max }
      else if (range.includes('-')) {
        const [a, b] = range.split('-')
        lo = Number(a); hi = Number(b)
        if (!Number.isInteger(lo) || !Number.isInteger(hi)) return `Bad range in field ${i + 1}: "${part}"`
      } else {
        const v = Number(range)
        if (!Number.isInteger(v)) return `Bad value in field ${i + 1}: "${part}"`
        if (v < 0 || v > max) return `Value ${v} out of range (0-${max}) in field ${i + 1}`
        continue
      }
      if (lo < 0 || hi > max || lo > hi) return `Range out of bounds in field ${i + 1}: "${part}"`
    }
  }
  return null
}

function pickPreset(id: string) {
  selectedPresetId.value = id
  useCustom.value = false
}

function enableCustom() {
  useCustom.value = true
}

watch(() => props.show, (show) => {
  if (show) {
    name.value = ''
    description.value = ''
    initialPrompt.value = ''
    enabled.value = true
    useCustom.value = false
    customCron.value = ''
    selectedPresetId.value = 'every5'
    timeHour.value = 9
    timeMinute.value = 0
    localError.value = null
    currentSchedule.value = '*/5 * * * *'
    nextTick(() => nameInput.value?.focus())
  }
})

// Surface API errors from the parent (400 on bad cron, etc.).
watch(() => props.apiError, (msg) => {
  if (msg) localError.value = msg
})

function handleSubmit() {
  if (!name.value.trim() || !initialPrompt.value.trim()) return
  const schedule = currentSchedule.value
  if (!schedule) {
    localError.value = 'Schedule is required'
    return
  }
  const cronErr = validate5FieldCron(schedule)
  if (cronErr) {
    localError.value = cronErr
    return
  }
  localError.value = null
  emit('create', {
    name: name.value.trim(),
    description: description.value.trim() || undefined,
    initial_prompt: initialPrompt.value.trim(),
    schedule,
    enabled: enabled.value,
  })
}

function handleClose() { emit('close') }

function handleKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') handleClose()
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
        @keydown="handleKeydown"
      >
        <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="handleClose" />

        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 80vh;"
          data-testid="add-routine-dialog"
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3 class="text-base font-semibold" style="color: var(--semantic-text);">New Routine</h3>
            <p v-if="projectName" class="text-xs mt-1" style="color: var(--semantic-text-dim);">
              Add a routine to "{{ projectName }}"
            </p>
          </div>

          <!-- Form body, scrollable -->
          <div class="flex-1 overflow-y-auto px-5 pb-4 space-y-4">
            <!-- Name -->
            <div>
              <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Name</label>
              <input
                ref="nameInput"
                v-model="name"
                type="text"
                placeholder="Daily standup"
                class="w-full px-3 py-2 rounded-lg text-sm outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                data-testid="routine-name"
              />
            </div>

            <!-- Description -->
            <div>
              <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Description (optional)</label>
              <input
                v-model="description"
                type="text"
                placeholder="What does this routine do?"
                class="w-full px-3 py-2 rounded-lg text-sm outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                data-testid="routine-description"
              />
            </div>

            <!-- Initial prompt -->
            <div>
              <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Initial prompt</label>
              <textarea
                v-model="initialPrompt"
                rows="3"
                placeholder="What should the AI do on every fire?"
                class="w-full px-3 py-2 rounded-lg text-sm outline-none resize-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                data-testid="routine-initial-prompt"
              />
            </div>

            <!-- Schedule picker -->
            <div>
              <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Schedule</label>
              <div class="flex flex-wrap gap-1.5">
                <button
                  v-for="preset in PRESETS"
                  :key="preset.id"
                  type="button"
                  @click="pickPreset(preset.id)"
                  :data-testid="`preset-${preset.id}`"
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
              <!-- Time-of-day inputs (visible for time-aware presets) -->
              <div v-if="!useCustom && PRESETS.find(p => p.id === selectedPresetId)?.withTime" class="flex items-center gap-2 mt-2">
                <input
                  v-model.number="timeHour"
                  type="number" min="0" max="23"
                  class="w-16 px-2 py-1 rounded-md text-xs"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                  data-testid="routine-time-hour"
                />
                <span style="color: var(--semantic-text-dim);">:</span>
                <input
                  v-model.number="timeMinute"
                  type="number" min="0" max="59"
                  class="w-16 px-2 py-1 rounded-md text-xs"
                  style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                  data-testid="routine-time-minute"
                />
              </div>
              <!-- Custom cron -->
              <div class="mt-2 flex items-center gap-2">
                <input
                  type="checkbox"
                  :checked="useCustom"
                  @change="enableCustom"
                  id="custom-cron-toggle"
                  data-testid="custom-cron-toggle"
                />
                <label for="custom-cron-toggle" class="text-xs" style="color: var(--semantic-text-dim);">
                  Custom (cron expression)
                </label>
              </div>
              <input
                v-if="useCustom"
                v-model="customCron"
                type="text"
                placeholder="*/5 * * * *"
                class="w-full mt-2 px-3 py-2 rounded-lg text-sm font-mono outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                data-testid="custom-cron-input"
              />
              <p class="mt-1 text-[10px]" style="color: var(--semantic-text-dim);" data-testid="routine-schedule-preview">
                Cron: <span class="font-mono">{{ currentSchedule || '—' }}</span>
              </p>
            </div>

            <!-- Enabled -->
            <div class="flex items-center gap-2">
              <input
                type="checkbox"
                v-model="enabled"
                id="enabled-toggle"
                data-testid="routine-enabled"
              />
              <label for="enabled-toggle" class="text-sm" style="color: var(--semantic-text);">
                Enabled
              </label>
            </div>

            <!-- Error -->
            <p v-if="localError" class="text-xs" style="color: var(--semantic-error);" data-testid="routine-error">
              {{ localError }}
            </p>
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              @click="handleClose"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
              style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);"
            >
              Cancel
            </button>
            <button
              @click="handleSubmit"
              :disabled="!name.trim() || !initialPrompt.trim()"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
              data-testid="routine-submit"
            >
              Create Routine
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.modal-enter-active,
.modal-leave-active { transition: all 0.2s ease-out; }
.modal-enter-from,
.modal-leave-to { opacity: 0; }
.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child { transform: scale(0.95) translateY(10px); }
</style>
