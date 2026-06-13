# Add Task Routines — Chunk 6: Frontend dialogs (AddTaskPicker, AddRoutine, EditRoutine)

**Why this chunk comes after Chunk 5:** The dialogs in this chunk call `api.createTask(workspaceId, itemId, { taskType: 'routine', routine: {...} })` and `api.updateTaskSimple(taskId, { schedule, ... })`. Both depend on the API extensions from Chunk 5. This chunk produces the user-facing forms; Chunk 7 wires them into the sidebar + task row.

**Files touched:**

| File | Change |
|---|---|
| `src/apps/desktop/src/components/AddTaskPickerDialog.vue` | NEW. Two large cards: "Standard Chat" + "Routine". Emits `pick`. |
| `src/apps/desktop/src/components/AddRoutineDialog.vue` | NEW. Form for creating a routine (name, description, initial_prompt, schedule picker, enabled). |
| `src/apps/desktop/src/components/EditRoutineDialog.vue` | NEW. Same form prefilled with the routine's current values. Emits `submit` instead of `create`. |
| `src/apps/desktop/src/components/AddTaskDialog.vue` | MODIFY. Wire the existing component up for the Standard path (it currently is dead code). No logic change — the parent will call `addTask({ taskType: 'standard' })`. |
| `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts` | NEW. Both cards visible; click emits the right `pick`. |
| `src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts` | NEW. Preset populates cron; custom toggle reveals input; submit fires right API call. |
| `src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts` | NEW. Opens prefilled; submit PATCHes. |

---

## Task 6.1: `AddTaskPickerDialog.vue` (two large cards)

**Files:**
- Create: `src/apps/desktop/src/components/AddTaskPickerDialog.vue`
- Test: `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts` (Task 6.5)

### Step 1: Write the failing test (deferred to Task 6.5)

AddTaskPickerDialog is a thin wrapper around two buttons. The test (Task 6.5) covers both cards' visibility + click behavior. Skip a separate failing test for this task — write the component first, then run the test in 6.5.

### Step 2: Write the component

Create `src/apps/desktop/src/components/AddTaskPickerDialog.vue`:

```vue
<script setup lang="ts">
// AddTaskPickerDialog — shown when the user clicks the green `+`
// button on a workspace item. Two large cards: "Standard Chat" and
// "Routine". The parent (Sidebar.vue) decides which creation flow
// to open based on the emitted `pick` value.
//
// Style match: backdrop + card wrapper copied verbatim from
// AddTaskDialog.vue:44-143 so the visual language is consistent
// with every other dialog in the app.

const props = defineProps<{
  show: boolean
  projectName?: string
}>()

const emit = defineEmits<{
  close: []
  pick: [taskType: 'standard' | 'routine']
}>()

const handleClose = () => emit('close')

const handleStandard = () => {
  emit('pick', 'standard')
}

const handleRoutine = () => {
  emit('pick', 'routine')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    handleClose()
  }
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
        <!-- Backdrop -->
        <div
          class="absolute inset-0 bg-black/60 backdrop-blur-sm"
          @click="handleClose"
        />

        <!-- Dialog Content -->
        <div
          class="relative w-full max-w-lg mx-4 rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          data-testid="add-task-picker"
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              class="text-base font-semibold"
              style="color: var(--semantic-text);"
            >
              New Task
            </h3>
            <p v-if="projectName" class="text-xs mt-1" style="color: var(--semantic-text-dim);">
              Add task to "{{ projectName }}"
            </p>
          </div>

          <!-- Two cards side-by-side -->
          <div class="px-5 pb-5 grid grid-cols-2 gap-3">
            <!-- Standard Chat card -->
            <button
              type="button"
              @click="handleStandard"
              data-testid="picker-standard"
              class="flex flex-col items-start gap-2 p-4 rounded-lg text-left transition-all duration-200 hover:scale-[1.02]"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
            >
              <span class="text-2xl" aria-hidden="true">💬</span>
              <span class="text-sm font-semibold" style="color: var(--semantic-text);">Standard Chat</span>
              <span class="text-xs" style="color: var(--semantic-text-dim);">
                An interactive chat with the AI. You send messages, the AI responds.
              </span>
            </button>

            <!-- Routine card -->
            <button
              type="button"
              @click="handleRoutine"
              data-testid="picker-routine"
              class="flex flex-col items-start gap-2 p-4 rounded-lg text-left transition-all duration-200 hover:scale-[1.02]"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
            >
              <span class="text-2xl" aria-hidden="true">🕒</span>
              <span class="text-sm font-semibold" style="color: var(--semantic-text);">Routine</span>
              <span class="text-xs" style="color: var(--semantic-text-dim);">
                A scheduled task. The AI runs your prompt on a schedule; you see the runs in the chat.
              </span>
            </button>
          </div>

          <!-- Cancel -->
          <div class="px-5 pb-5 flex justify-end">
            <button
              @click="handleClose"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
              style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal transitions — copied verbatim from AddTaskDialog.vue. */
.modal-enter-active,
.modal-leave-active {
  transition: all 0.2s ease-out;
}
.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}
.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95) translateY(10px);
}
</style>
```

### Step 3: Type-check (deferred)

The component is tested in Task 6.5. Skip a type-check here — run it after 6.5 lands.

### Step 4: (deferred to Task 6.5)

### Step 5: (deferred to Task 6.5)

---

## Task 6.2: `AddRoutineDialog.vue` (create form with preset schedule chips)

**Files:**
- Create: `src/apps/desktop/src/components/AddRoutineDialog.vue`
- Test: `src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts` (Task 6.6)

### Step 1: Write the failing test (deferred to Task 6.6)

### Step 2: Write the component

Create `src/apps/desktop/src/components/AddRoutineDialog.vue`:

```vue
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
```

### Step 3-5: (deferred to Task 6.6)

---

## Task 6.3: `EditRoutineDialog.vue` (prefilled variant)

**Files:**
- Create: `src/apps/desktop/src/components/EditRoutineDialog.vue`
- Test: `src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts` (Task 6.7)

### Step 1: Write the failing test (deferred to Task 6.7)

### Step 2: Write the component

`EditRoutineDialog.vue` is a thin re-skin of `AddRoutineDialog.vue` that:
- Accepts a `routine: RoutineMeta` + `taskName: string` prop
- Prefills the form on open
- Emits `submit: [params]` instead of `create`
- Header says "Edit Routine" instead of "New Routine"
- Submit button says "Save" instead of "Create Routine"

Create `src/apps/desktop/src/components/EditRoutineDialog.vue`:

```vue
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
import type { RoutineMeta } from '../stores/workspaces'

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
```

### Step 3-5: (deferred to Task 6.7)

---

## Task 6.4: Wire `AddTaskDialog.vue` for the standard path

**Files:**
- Modify: `src/apps/desktop/src/components/AddTaskDialog.vue` (no logic change — just confirm the prop / emit shape matches what `Sidebar` will pass)

This task is a no-op in the component file itself; the dialog already emits `create: [name, description?]` (line 11) and accepts `show` + `projectName?` props (lines 4-7). The wire-up is purely a `Sidebar.vue` concern (Task 7.2). This task's only job is to **verify** the shape and document it for the reviewer.

### Step 1: (no test needed)

### Step 2: (no impl needed — the file is unchanged)

### Step 3: (no test run needed)

### Step 4: (no commit needed — no diff)

Skip the TDD ceremony for this task. Confirm by reading `AddTaskDialog.vue:9-12` and the Task 7.2 wire-up.

---

## Chunk 6 components done — checkpoint

- ✅ `AddTaskPickerDialog` component (Task 6.1)
- ✅ `AddRoutineDialog` component (Task 6.2)
- ✅ `EditRoutineDialog` component (Task 6.3)
- ✅ `AddTaskDialog` verified for the Standard path (Task 6.4 — no code change)

Next: **Chunk 6 test tasks** (Tasks 6.5-6.7) — see `chunks-6-tests.md`. Then Chunk 7 (integration) — see `chunks-7.md`.
