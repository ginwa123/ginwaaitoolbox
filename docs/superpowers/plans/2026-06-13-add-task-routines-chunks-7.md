# Add Task Routines — Chunk 7: Frontend integration (WorkspaceItemTask + Sidebar)

**Why this chunk is last:** Both components modified here depend on the dialogs from Chunk 6 (Sidebar mounts the new dialogs and routes between them) and on the store actions from Chunk 5 (`runRoutine`, `updateRoutine`, the new `addTask` signature). No data-layer changes in this chunk — it wires the UI together and adds the routine-specific row rendering.

> **Predecessor files:** [`chunks-5.md`](2026-06-13-add-task-routines-chunks-5.md) (types + API + store actions) · [`chunks-6.md`](2026-06-13-add-task-routines-chunks-6.md) (dialog components) · [`chunks-6-tests.md`](2026-06-13-add-task-routines-chunks-6-tests.md) (dialog spec files).

**Files touched:**

| File | Change |
|---|---|
| `src/apps/desktop/src/components/WorkspaceItemTask.vue` | Branch on `task.task_type`. Renders clock icon + Run Now + status dot + next-run tooltip for routine tasks. New `runRoutine` and `editRoutine` events. |
| `src/apps/desktop/src/components/Sidebar.vue` | Replace fast-path `handleAddTask` with picker flow. New refs for the picker / add-routine / edit-routine dialogs. New handlers `handleAddTaskPick`, `handleRunRoutine`, `handleEditRoutine`, etc. |
| `src/apps/desktop/src/__tests__/workspaceItemTaskRoutine.spec.ts` | NEW. Routine rows render clock icon, Run Now button, status dot, next-run tooltip. Run Now emits `runRoutine` event. |

---

## Task 7.1: `WorkspaceItemTask.vue` — branch on `task.task_type` (combines Task 7.1 + 7.3 from the task list)

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItemTask.vue` (template + script)
- Test: `src/apps/desktop/src/__tests__/workspaceItemTaskRoutine.spec.ts` (new)

The original task list split this into Task 7.1 (rendering) and Task 7.3 (event emission), but both modify the same component in a single TDD cycle. We combine them into one task; the new `runRoutine` + `editRoutine` events are part of the same commit as the new template elements.

### Step 1: Write the failing test

Create `src/apps/desktop/src/__tests__/workspaceItemTaskRoutine.spec.ts`:

```ts
/**
 * Tests for the routine-task branch of WorkspaceItemTask.
 *
 * When `task.task_type === 'routine'`, the row renders a clock
 * icon (instead of the bullet), a "Run now" play-icon button on
 * hover, a status dot whose color reflects `last_status`, and a
 * tooltip on the clock showing the next fire time. Standard
 * tasks (or legacy tasks with no task_type) render the original
 * bullet + rename/delete layout.
 *
 * Clicking "Run now" emits `runRoutine: [workspaceId, itemId, taskId]`.
 * The parent (WorkspaceItem → Sidebar) is responsible for calling
 * the store action and routing. We test the emit only; the
 * end-to-end flow is in Task 7.5.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItemTask from '../components/WorkspaceItemTask.vue'
import type { RoutineMeta, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const baseRoutine: RoutineMeta = {
  schedule: '0 9 * * 1-5',
  initial_prompt: 'summarize commits',
  enabled: true,
  last_run_at: '2025-06-13 09:00:00',
  next_run_at: '2025-06-16 09:00:00',
  last_status: 'success',
  last_error: null,
}

function makeRoutineTask(overrides: Partial<RoutineMeta> = {}): Task {
  return {
    id: 'task_r1',
    name: 'Daily standup',
    task_type: 'routine',
    routine: { ...baseRoutine, ...overrides },
  }
}

function makeStandardTask(): Task {
  return { id: 'task_std', name: 'Quick chat', task_type: 'standard' }
}

function mountTask(
  task: Task,
  workspaceId = 'ws_1',
  itemId = 'item_1',
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItemTask, {
    props: { task, workspaceId, itemId },
    global: { provide: { processingState } },
  })
  return { wrapper, processingState }
}

describe('WorkspaceItemTask — routine branch', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    // Pinia teardown handled by next beforeEach.
  })

  it('renders the clock icon (and not the standard bullet) for a routine task', () => {
    const { wrapper } = mountTask(makeRoutineTask())
    // Clock icon: data-testid="routine-clock"
    expect(wrapper.find('[data-testid="routine-clock"]').exists()).toBe(true)
    // Bullet is hidden — the only w-1.5.h-1.5 span is for the
    // status dot (different sizing). The legacy bullet testid
    // (none) was a w-1.5 h-1.5 span, which we now use for the
    // status dot only when not in legacy mode. We assert the
    // absence of the bullet by checking the row's first visual
    // marker is the clock (data-testid order in the DOM).
    const markers = wrapper.findAll('[data-testid^="task-"], [data-testid="routine-clock"]')
    expect(markers[0]!.attributes('data-testid')).toBe('routine-clock')
  })

  it('renders the standard bullet for a standard task (existing behavior unchanged)', () => {
    const { wrapper } = mountTask(makeStandardTask())
    // The standard bullet is the w-1.5 h-1.5 rounded-full span
    // (no testid; matched by class). The clock icon is absent.
    expect(wrapper.find('[data-testid="routine-clock"]').exists()).toBe(false)
    expect(wrapper.find('span.w-1\\.5.h-1\\.5.rounded-full').exists()).toBe(true)
  })

  it('treats a task with no task_type as standard (backwards-compat with legacy data)', () => {
    // Old tasks loaded from the DB before this migration have
    // no task_type. They must continue to render the bullet +
    // standard layout. (The backend migration adds the column
    // with DEFAULT 'standard', so new GETs always include it,
    // but in-flight data in the SPA store may not.)
    const legacy = { id: 'task_legacy', name: 'Old task' } as unknown as Task
    const { wrapper } = mountTask(legacy)
    expect(wrapper.find('[data-testid="routine-clock"]').exists()).toBe(false)
    expect(wrapper.find('span.w-1\\.5.h-1\\.5.rounded-full').exists()).toBe(true)
  })

  it('renders the status dot green for last_status="success"', () => {
    const { wrapper } = mountTask(makeRoutineTask({ last_status: 'success' }))
    const dot = wrapper.find('[data-testid="routine-status-dot"]')
    expect(dot.exists()).toBe(true)
    // Green = #22c55e (Tailwind green-500) or any of the project's
    // semantic green tokens. The component uses a hex literal;
    // assert the color family loosely via the style attribute.
    const style = dot.attributes('style') ?? ''
    expect(style).toMatch(/green|#22c55e|#10b981/i)
  })

  it('renders the status dot red for last_status="failed"', () => {
    const { wrapper } = mountTask(makeRoutineTask({ last_status: 'failed' }))
    const dot = wrapper.find('[data-testid="routine-status-dot"]')
    expect(dot.attributes('style') ?? '').toMatch(/red|#ef4444|#dc2626/i)
  })

  it('renders the status dot gray when last_status is null (never fired)', () => {
    const { wrapper } = mountTask(makeRoutineTask({ last_status: null }))
    const dot = wrapper.find('[data-testid="routine-status-dot"]')
    const style = dot.attributes('style') ?? ''
    // Gray token or rgba/literal gray.
    expect(style).toMatch(/gray|#9ca3af|#6b7280/i)
  })

  it('renders the Run Now button on hover (opacity-0 by default, in the DOM)', () => {
    const { wrapper } = mountTask(makeRoutineTask())
    const btn = wrapper.find('[data-testid="run-routine-btn"]')
    expect(btn.exists()).toBe(true)
    // Hover-reveal pattern (same as rename/delete buttons):
    // the button carries opacity-0 in the un-hovered state.
    expect(btn.classes()).toContain('opacity-0')
  })

  it('emits runRoutine with (workspaceId, itemId, taskId) when Run Now is clicked', async () => {
    const { wrapper } = mountTask(makeRoutineTask(), 'ws_x', 'item_y')
    await wrapper.find('[data-testid="run-routine-btn"]').trigger('click')
    const emitted = wrapper.emitted('runRoutine')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_x', 'item_y', 'task_r1'])
  })

  it('does NOT emit selectTask when Run Now is clicked (stopPropagation guard)', async () => {
    // Same rationale as the rename/delete guards: the Run Now
    // button is nested INSIDE the row <button>. Without
    // stopPropagation, the click bubbles and triggers
    // handleSelectTask as a side effect.
    const { wrapper } = mountTask(makeRoutineTask())
    await wrapper.find('[data-testid="run-routine-btn"]').trigger('click')
    expect(wrapper.emitted('selectTask')).toBeUndefined()
  })

  it('emits editRoutine (not renameTask) when the pencil is clicked on a routine task', async () => {
    // For routine tasks, the pencil opens the EditRoutineDialog
    // (which carries schedule + initial_prompt + enabled). The
    // existing renameTask event is reserved for standard tasks.
    const { wrapper } = mountTask(makeRoutineTask())
    const pencil = wrapper.find('button[title="Edit Routine"]')
    expect(pencil.exists()).toBe(true)
    await pencil.trigger('click')
    const editEmitted = wrapper.emitted('editRoutine')
    const renameEmitted = wrapper.emitted('renameTask')
    expect(editEmitted).toBeDefined()
    expect(editEmitted![0]).toEqual(['ws_1', 'item_1', 'task_r1'])
    expect(renameEmitted).toBeUndefined()
  })

  it('still emits renameTask for a standard task (existing behavior unchanged)', async () => {
    const { wrapper } = mountTask(makeStandardTask())
    const pencil = wrapper.find('button[title="Rename Task"]')
    expect(pencil.exists()).toBe(true)
    await pencil.trigger('click')
    expect(wrapper.emitted('renameTask')).toBeDefined()
    expect(wrapper.emitted('editRoutine')).toBeUndefined()
  })

  it('renders the next-fire tooltip on the clock icon', () => {
    // We assert the title attribute (native tooltip) since the
    // design doc calls for a "Next: in N min (HH:MM)" string.
    // A future migration to a richer tooltip library can swap
    // out the title attribute for a Popper.js popover without
    // changing this test's contract.
    const { wrapper } = mountTask(makeRoutineTask({
      next_run_at: '2099-01-01 15:00:00',
    }))
    const clock = wrapper.find('[data-testid="routine-clock"]')
    const title = clock.attributes('title') ?? ''
    expect(title).toMatch(/Next/i)
    expect(title).toMatch(/15:00/)
  })
})
```

### Step 2: Run the test, verify it FAILS

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspaceItemTaskRoutine.spec.ts 2>&1 | tail -n 30`
Expected: FAIL with multiple "expected to find [data-testid=...]" errors. The current component only renders the bullet + name + pencil + delete; no clock icon, no Run Now button, no status dot, no routine events.

### Step 3: Write the implementation

Replace the contents of `src/apps/desktop/src/components/WorkspaceItemTask.vue`:

```vue
<script setup lang="ts">
// Extracted from WorkspaceItem.vue on 2026-06-10. This component owns
// ONLY the per-task row inside the expanded workspace-item panel — the
// item row (chevron / name / hover buttons) and the expansion state
// stay in WorkspaceItem. Event payload is identical to the pre-split
// contract; WorkspaceItem re-emits these three events up to
// WorkspaceList unchanged.
//
// Chunk 7 of task-routines: the row now branches on `task.task_type`.
// Standard tasks render the original bullet + rename/delete. Routine
// tasks render a clock icon, a status dot reflecting `last_status`,
// a "Run now" play-icon button on hover, and a tooltip with the next
// fire time. The pencil on a routine task emits `editRoutine` (not
// `renameTask`) so the parent opens EditRoutineDialog (which carries
// schedule + initial_prompt) instead of the simple RenameTaskModal.

import { inject, ref, computed, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Task, RoutineMeta } from '../stores/workspaces'

const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const workspacesStore = useWorkspacesStore()

const props = defineProps<{
  task: Task
  workspaceId: string
  itemId: string
}>()

const emit = defineEmits<{
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // NEW (Chunk 7 of task-routines plan): emitted by the pencil
  // on a routine task. The parent opens EditRoutineDialog.
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  // NEW: emitted by the Run Now button. The parent calls
  // workspacesStore.runRoutine(...) and routes to the chat view.
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
}>()

// Convenience: is this task a routine? Defaults to false (the
// legacy behavior) for tasks with no `task_type` field.
const isRoutine = computed(
  () => props.task.task_type === 'routine' && props.task.routine !== undefined,
)

const statusColor = computed<string>(() => {
  if (!isRoutine.value) return 'transparent'
  const s = props.task.routine!.last_status
  if (s === 'success') return '#22c55e' // green-500
  if (s === 'failed') return '#ef4444'  // red-500
  if (s === 'running') return '#eab308' // yellow-500 (spinning via class)
  return '#9ca3af' // gray-400 — never fired
})

const statusClass = computed<string>(() => {
  if (!isRoutine.value) return ''
  return props.task.routine!.last_status === 'running' ? 'animate-spin' : ''
})

// Format the next-fire tooltip. The backend stores
// `next_run_at` as "YYYY-MM-DD HH:MM:SS" (UTC). The label is
// "Next: in 23 min (15:00)" — we compute the relative delta
// from `Date.now()` and the absolute HH:MM in UTC.
const nextRunTooltip = computed<string>(() => {
  if (!isRoutine.value) return ''
  const r: RoutineMeta = props.task.routine!
  // Parse "YYYY-MM-DD HH:MM:SS" as UTC. Use a single Date ctor.
  const next = new Date(r.next_run_at.replace(' ', 'T') + 'Z')
  if (Number.isNaN(next.getTime())) return `Next: ${r.next_run_at}`
  const ms = next.getTime() - Date.now()
  const hh = String(next.getUTCHours()).padStart(2, '0')
  const mm = String(next.getUTCMinutes()).padStart(2, '0')
  const time = `${hh}:${mm}`
  if (ms <= 0) return `Next: any moment (${time})`
  const mins = Math.round(ms / 60000)
  if (mins < 60) return `Next: in ${mins} min (${time})`
  const hours = Math.floor(mins / 60)
  const remMins = mins % 60
  if (hours < 24) return `Next: in ${hours} h ${remMins} min (${time})`
  const days = Math.floor(hours / 24)
  const remHours = hours % 24
  return `Next: in ${days} d ${remHours} h (${time})`
})

const handleSelectTask = () => {
  emit('selectTask', props.task.id)
}

const handleDeleteTask = (event: Event) => {
  event.stopPropagation()
  emit('deleteTask', props.workspaceId, props.itemId, props.task.id)
}

const handleRenameTask = (event: Event) => {
  event.stopPropagation()
  emit('renameTask', props.workspaceId, props.itemId, props.task.id, props.task.name)
}

const handleEditRoutine = (event: Event) => {
  event.stopPropagation()
  emit('editRoutine', props.workspaceId, props.itemId, props.task.id)
}

const handleRunRoutine = (event: Event) => {
  event.stopPropagation()
  emit('runRoutine', props.workspaceId, props.itemId, props.task.id)
}
</script>

<template>
  <button
    class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
    :style="{
      color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
      backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'transparent',
    }"
    @click="handleSelectTask"
  >
    <!-- ───── ROUTINE branch ───── -->
    <template v-if="isRoutine">
      <!-- Spinner while worker is processing this task (mirrors ChatsList). -->
      <span
        v-if="processingState[task.id]"
        class="w-4 h-4 flex items-center justify-center shrink-0"
        data-testid="task-spinner"
      >
        <div
          class="w-3 h-3 border-2 rounded-full animate-spin"
          style="border-color: var(--color-yellow); border-top-color: transparent"
        ></div>
      </span>
      <!-- Clock icon (with next-run tooltip) -->
      <span
        v-else
        class="w-4 h-4 flex items-center justify-center shrink-0"
        :title="nextRunTooltip"
        data-testid="routine-clock"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
      </span>
      <!-- Status dot (next to the name) -->
      <span
        class="w-1.5 h-1.5 rounded-full shrink-0"
        :class="statusClass"
        :style="{ backgroundColor: statusColor }"
        data-testid="routine-status-dot"
      />
      <!-- Task name -->
      <span class="flex-1 truncate">{{ task.name }}</span>
      <!-- Pencil — for routine tasks this opens EditRoutineDialog -->
      <button
        @click="handleEditRoutine($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-blue-400"
        style="color: var(--semantic-text-dim);"
        title="Edit Routine"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
      <!-- Run Now play-icon button (between rename and delete) -->
      <button
        @click="handleRunRoutine($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-green-400"
        style="color: var(--semantic-text-dim);"
        title="Run now"
        data-testid="run-routine-btn"
      >
        <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path d="M8 5v14l11-7z" />
        </svg>
      </button>
      <!-- Delete task button -->
      <button
        @click="handleDeleteTask($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-red-400"
        style="color: var(--semantic-text-dim);"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </template>

    <!-- ───── STANDARD branch (existing behavior) ───── -->
    <template v-else>
      <span
        v-if="processingState[task.id]"
        class="w-4 h-4 flex items-center justify-center shrink-0"
        data-testid="task-spinner"
      >
        <div
          class="w-3 h-3 border-2 rounded-full animate-spin"
          style="border-color: var(--color-yellow); border-top-color: transparent"
        ></div>
      </span>
      <span
        v-else
        class="w-1.5 h-1.5 rounded-full shrink-0"
        :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
      />
      <span class="flex-1 truncate">{{ task.name }}</span>
      <button
        @click="handleRenameTask($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-blue-400"
        style="color: var(--semantic-text-dim);"
        title="Rename Task"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
      <button
        @click="handleDeleteTask($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-red-400"
        style="color: var(--semantic-text-dim);"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </template>
  </button>
</template>
```

### Step 4: Run the test, verify it PASSES

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspaceItemTaskRoutine.spec.ts 2>&1 | tail -n 30`
Expected: PASS (12/12).

### Step 5: Type-check + commit

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean. **Important:** the existing `workspaceItemTask.spec.ts` and `workspaceItemTaskRename.spec.ts` tests must still pass — they use `button[title="Rename Task"]` which still exists on the STANDARD branch. The legacy behavior is preserved. **Also important:** the new `defineEmits` block adds `editRoutine` and `runRoutine`. The existing `workspaceItemTask.spec.ts` and `workspaceItemTaskRename.spec.ts` test files don't need to change.

**Caveat — `WorkspaceItem.vue` must re-emit the new events:** the existing `WorkspaceItem.vue` re-emits `selectTask` / `deleteTask` / `renameTask` from `<WorkspaceItemTask>`. We need to add `editRoutine` and `runRoutine` to that re-emit. Open `src/apps/desktop/src/components/WorkspaceItem.vue` and:

1. In the `<script setup>` block, add `editRoutine` and `runRoutine` to the `defineEmits` type:
   ```ts
   const emit = defineEmits<{
     selectTask: [taskId: string]
     deleteTask: [workspaceId: string, itemId: string, taskId: string]
     renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
     editRoutine: [workspaceId: string, itemId: string, taskId: string]    // NEW
     runRoutine: [workspaceId: string, itemId: string, taskId: string]     // NEW
   }>()
   ```
2. In the template, add the bindings: `<WorkspaceItemTask ... @editRoutine="emit('editRoutine', $event)" @runRoutine="emit('runRoutine', $event)" />`.

These edits are required to pass `bun run build` (the type-check). Include them in this commit.

```bash
git add src/apps/desktop/src/components/WorkspaceItemTask.vue \
        src/apps/desktop/src/components/WorkspaceItem.vue \
        src/apps/desktop/src/__tests__/workspaceItemTaskRoutine.spec.ts
git commit -m "feat(routines): WorkspaceItemTask renders clock icon + Run Now + status dot for routines"
```

---

## Task 7.2: `Sidebar.vue` — picker flow + Run Now handler + Edit Routine handler

**Files:**
- Modify: `src/apps/desktop/src/components/Sidebar.vue` (handleAddTask replacement, new refs / handlers / dialog mounts)

This is the wiring task. There's no new logic to test in isolation — the `runRoutine` / `updateRoutine` store actions already have their own tests from Chunk 5, and the components' emit / event flows are tested in Tasks 7.1, 6.5, 6.6, 6.7. The Sidebar change is verified by:

1. `bun run build` (the type-check will catch any mismatched event / prop wiring)
2. The E2E test in Task 7.5

### Step 1: (no separate failing test)

### Step 2: Write the implementation

**2a. Add the imports** at the top of `src/apps/desktop/src/components/Sidebar.vue` (after the existing component imports around line 7-13):

```ts
import AddTaskPickerDialog from './AddTaskPickerDialog.vue'
import AddTaskDialog from './AddTaskDialog.vue'
import AddRoutineDialog from './AddRoutineDialog.vue'
import EditRoutineDialog from './EditRoutineDialog.vue'
import type { AddRoutineParams, EditRoutineParams } from './AddRoutineDialog.vue'
import type { RoutineMeta } from '../stores/workspaces'
```

**2b. Add the new refs** next to the existing dialog state (after line 82, the existing `renameTargetTaskName` ref):

```ts
// Add task picker
const showAddTaskPicker = ref(false)
const addTaskPickerWorkspaceId = ref<string | null>(null)
const addTaskPickerItemId = ref<string | null>(null)
const addTaskPickerProjectName = ref('')

// Add standard task (after picker → standard)
const showAddTaskDialog = ref(false)
const addTaskDialogWorkspaceId = ref<string | null>(null)
const addTaskDialogItemId = ref<string | null>(null)

// Add routine (after picker → routine)
const showAddRoutineDialog = ref(false)
const addRoutineDialogWorkspaceId = ref<string | null>(null)
const addRoutineDialogItemId = ref<string | null>(null)
const addRoutineApiError = ref<string | null>(null)

// Edit routine
const showEditRoutineDialog = ref(false)
const editRoutineWorkspaceId = ref<string | null>(null)
const editRoutineItemId = ref<string | null>(null)
const editRoutineTaskId = ref<string | null>(null)
```

**2c. Replace the `handleAddTask` function** at line 350 with the picker flow:

```ts
// OLD (removed):
// const handleAddTask = async (workspaceId: string, item: WorkspaceItem) => {
//   const name = `Task ${new Date().toLocaleTimeString()}`
//   const taskId = await workspacesStore.addTask(workspaceId, item.id, name)
//   if (taskId) {
//     workspacesStore.setActiveTask(taskId)
//     router.replace({ path: '/app', query: { view: 'task', task: taskId } })
//   }
// }

// NEW: open the picker. The actual creation happens in
// handleAddTaskPick → handleCreateStandardTask / handleCreateRoutine.
const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
  addTaskPickerWorkspaceId.value = workspaceId
  addTaskPickerItemId.value = item.id
  addTaskPickerProjectName.value = item.name
  showAddTaskPicker.value = true
}

const handleAddTaskPickerClose = () => {
  showAddTaskPicker.value = false
  addTaskPickerWorkspaceId.value = null
  addTaskPickerItemId.value = null
}

const handleAddTaskPick = (taskType: 'standard' | 'routine') => {
  if (taskType === 'standard') {
    showAddTaskPicker.value = false
    showAddTaskDialog.value = true
  } else {
    showAddTaskPicker.value = false
    addRoutineApiError.value = null
    showAddRoutineDialog.value = true
  }
}

const handleAddTaskDialogClose = () => {
  showAddTaskDialog.value = false
}

const handleCreateStandardTask = async (name: string, description?: string) => {
  if (!addTaskDialogWorkspaceId.value && !addTaskPickerWorkspaceId.value) return
  const wsId = addTaskDialogWorkspaceId.value ?? addTaskPickerWorkspaceId.value!
  const itemId = addTaskDialogItemId.value ?? addTaskPickerItemId.value!
  const taskId = await workspacesStore.addTask(wsId, itemId, {
    name,
    description,
    taskType: 'standard',
  })
  showAddTaskDialog.value = false
  addTaskDialogWorkspaceId.value = null
  addTaskDialogItemId.value = null
  if (taskId) {
    workspacesStore.setActiveTask(taskId)
    router.replace({ path: '/app', query: { view: 'task', task: taskId } })
  }
}

const handleAddRoutineDialogClose = () => {
  showAddRoutineDialog.value = false
  addRoutineDialogWorkspaceId.value = null
  addRoutineDialogItemId.value = null
  addRoutineApiError.value = null
}

const handleCreateRoutine = async (params: AddRoutineParams) => {
  const wsId = addRoutineDialogWorkspaceId.value ?? addTaskPickerWorkspaceId.value
  const itemId = addRoutineDialogItemId.value ?? addTaskPickerItemId.value
  if (!wsId || !itemId) return

  const taskId = await workspacesStore.addTask(wsId, itemId, {
    name: params.name,
    description: params.description,
    taskType: 'routine',
    routine: {
      schedule: params.schedule,
      initial_prompt: params.initial_prompt,
      enabled: params.enabled,
    },
  })
  if (taskId) {
    showAddRoutineDialog.value = false
    addRoutineDialogWorkspaceId.value = null
    addRoutineDialogItemId.value = null
    addRoutineApiError.value = null
    workspacesStore.setActiveTask(taskId)
    router.replace({ path: '/app', query: { view: 'task', task: taskId } })
  } else {
    // API failed; the createTask error is logged inside the
    // store action. We surface it to the dialog via a follow-up
    // // open if the user retries. For now: leave the dialog open
    // // so they can see any inline state. (Future: thread a real
    // // error message here.)
    addRoutineApiError.value = 'Failed to create routine. Please try again.'
  }
}

const handleRunRoutine = async (workspaceId: string, itemId: string, taskId: string) => {
  // Fire the routine, then navigate to its session. The session_id
  // returned by the backend equals taskId (per the task.id ==
  // session_id codebase invariant). We optimistically set active
  // and route; the SSE /chat-view connection picks up the new
  // user message when the sub-process writes it.
  const result = await workspacesStore.runRoutine(workspaceId, itemId, taskId)
  if (result?.session_id) {
    workspacesStore.setActiveTask(taskId)
    router.replace({
      path: '/app',
      query: { view: 'task', task: taskId, session: result.session_id },
    })
  }
}

const handleEditRoutine = (workspaceId: string, itemId: string, taskId: string) => {
  editRoutineWorkspaceId.value = workspaceId
  editRoutineItemId.value = itemId
  editRoutineTaskId.value = taskId
  showEditRoutineDialog.value = true
}

const handleEditRoutineClose = () => {
  showEditRoutineDialog.value = false
  editRoutineWorkspaceId.value = null
  editRoutineItemId.value = null
  editRoutineTaskId.value = null
}

const handleEditRoutineSubmitted = async (params: EditRoutineParams) => {
  if (!editRoutineWorkspaceId.value || !editRoutineItemId.value || !editRoutineTaskId.value) return
  await workspacesStore.updateRoutine(
    editRoutineWorkspaceId.value,
    editRoutineItemId.value,
    editRoutineTaskId.value,
    {
      name: params.name,
      schedule: params.schedule,
      initial_prompt: params.initial_prompt,
      enabled: params.enabled,
    },
  )
  showEditRoutineDialog.value = false
  editRoutineWorkspaceId.value = null
  editRoutineItemId.value = null
  editRoutineTaskId.value = null
}

// Lookup the routine being edited (for the EditRoutineDialog's
// `routine` prop). Returns null if any of the edit-target ids
// are missing.
const editRoutineTarget = computed<RoutineMeta | null>(() => {
  if (!editRoutineWorkspaceId.value || !editRoutineItemId.value || !editRoutineTaskId.value) return null
  for (const ws of workspacesStore.workspaces) {
    if (ws.id !== editRoutineWorkspaceId.value) continue
    const item = ws.items.find((i) => i.id === editRoutineItemId.value)
    const task = item?.tasks?.find((t) => t.id === editRoutineTaskId.value)
    return task?.routine ?? null
  }
  return null
})

const editRoutineTaskName = computed<string>(() => {
  if (!editRoutineWorkspaceId.value || !editRoutineItemId.value || !editRoutineTaskId.value) return ''
  for (const ws of workspacesStore.workspaces) {
    if (ws.id !== editRoutineWorkspaceId.value) continue
    const item = ws.items.find((i) => i.id === editRoutineItemId.value)
    const task = item?.tasks?.find((t) => t.id === editRoutineTaskId.value)
    return task?.name ?? ''
  }
  return ''
})
```

**2d. Update the existing `WorkspaceList` event bindings** at line 466-484 of `Sidebar.vue` to wire the new `runRoutine` and `editRoutine` events:

```vue
<WorkspaceList
  v-if="!isCollapsed"
  :workspaces="workspacesStore.workspaces"
  :active-workspace-item-id="workspacesStore.activeWorkspaceItemId"
  @toggle-workspace="handleToggleWorkspace"
  @select-item="handleSelectItem"
  @delete-workspace="handleDeleteWorkspace"
  @rename-workspace="handleRenameWorkspace"
  @delete-item="handleDeleteItem"
  @request-add-item="handleAddItem"
  @add-workspace="handleAddWorkspace"
  @add-task="handleAddTask"
  @select-task="handleSelectTask"
  @delete-task="handleDeleteTask"
  @rename-task="handleRenameTask"
  @run-routine="handleRunRoutine"           <!-- NEW -->
  @edit-routine="handleEditRoutine"         <!-- NEW -->
  @load-more-tasks="handleLoadMoreTasks"
  @reorder-workspaces="handleReorderWorkspaces"
/>
```

**Important:** the `WorkspaceList` and `WorkspaceItem` components currently don't re-emit `runRoutine` / `editRoutine` — the same edit as in Task 7.1's caveat applies. Update:

1. `src/apps/desktop/src/components/WorkspaceItem.vue`: add `editRoutine` + `runRoutine` to `defineEmits` and re-emit them from `<WorkspaceItemTask>`.
2. `src/apps/desktop/src/components/WorkspaceList.vue` (or wherever `WorkspaceItem` is rendered): add `editRoutine` + `runRoutine` to its `defineEmits` and re-emit.

The exact location of the `WorkspaceList` re-emit depends on the file's structure. Look at the existing re-emit pattern (e.g., `addTask`, `selectTask`) and mirror it.

**2e. Mount the new dialogs** at the bottom of the template, after the existing `</RenameTaskModal>` line (line 513):

```vue
<AddTaskPickerDialog
  :show="showAddTaskPicker"
  :project-name="addTaskPickerProjectName"
  @close="handleAddTaskPickerClose"
  @pick="handleAddTaskPick"
/>
<AddTaskDialog
  :show="showAddTaskDialog"
  :project-name="addTaskPickerProjectName"
  @close="handleAddTaskDialogClose"
  @create="handleCreateStandardTask"
/>
<AddRoutineDialog
  :show="showAddRoutineDialog"
  :project-name="addTaskPickerProjectName"
  :api-error="addRoutineApiError"
  @close="handleAddRoutineDialogClose"
  @create="handleCreateRoutine"
/>
<EditRoutineDialog
  :show="showEditRoutineDialog"
  :routine="editRoutineTarget"
  :task-name="editRoutineTaskName"
  @close="handleEditRoutineClose"
  @submit="handleEditRoutineSubmitted"
/>
```

### Step 3: (no separate test)

### Step 4: Type-check

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean. The type-check will catch:
- Missing `editRoutine` / `runRoutine` re-emits in `WorkspaceItem.vue` / `WorkspaceList.vue` (fix in 2d)
- Mismatched `AddRoutineParams` / `EditRoutineParams` shapes (exported from the dialogs)
- Any unused-ref warnings from the new state

If the type-check fails, iterate: read the error, fix the file, re-run.

### Step 5: Commit

```bash
git add src/apps/desktop/src/components/Sidebar.vue \
        src/apps/desktop/src/components/WorkspaceItem.vue \
        src/apps/desktop/src/components/WorkspaceList.vue
git commit -m "feat(routines): Sidebar wires picker + AddRoutine + EditRoutine + Run now flow"
```

---

## Task 7.3 (already done as part of Task 7.1)

The `runRoutine` event emission is part of the `WorkspaceItemTask.vue` edit in Task 7.1. Mark this task done in the task list.

---

## Task 7.4: Test `WorkspaceItemTask` for routine rows (covered by Task 7.1)

The test in Task 7.1 (`workspaceItemTaskRoutine.spec.ts`) already covers the new behavior:

- Renders clock icon, status dot, Run Now button, next-run tooltip
- Clicking Run Now emits `runRoutine` event
- Pencil on a routine task emits `editRoutine`, not `renameTask`
- Backwards-compat: tasks with no `task_type` render the standard bullet

This task is a no-op — Task 7.1's spec file IS the test for Task 7.4. Mark it done.

---

## Task 7.5: E2E manual verification

This task is documentation, not code. After all the commits from Chunks 5-7 land on `main` and the test suite is green, do a manual smoke test of the full flow.

### Step 1: Run all unit tests + build

```bash
cd src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 20
timeout 180 bun run build 2>&1 | tail -n 20
```

Expected: all unit tests pass; `bun run build` is clean (per project memory, this is the authoritative type-check).

### Step 2: Start the dev server

```bash
cd src/apps/desktop
bun run dev
```

The app starts on the configured port (default 5173). Open the URL in a browser. The dev server uses Vite + Vue 3 HMR; changes are picked up live.

### Step 3: E2E walkthrough

1. **Open the app.** The sidebar shows a default workspace / item. If there is no workspace / item, create one (green `+` on Workspaces, then "Add Project" on the new workspace).
2. **Click the green `+` on the workspace item row.** The **AddTaskPickerDialog** opens with two cards: "Standard Chat" and "Routine".
3. **Click the "Routine" card.** The picker closes; the **AddRoutineDialog** opens.
4. **Fill the form**:
   - Name: "Test Routine"
   - Initial prompt: "Say hello in one sentence."
   - Schedule: click "Every 5 min" (the cron preview shows `*/5 * * * *`).
   - Leave Enabled checked.
5. **Click "Create Routine".** The dialog closes. The task row in the sidebar now shows:
   - A small clock icon (instead of the bullet)
   - A gray status dot (last_status is null — never fired)
   - The task name "Test Routine"
6. **Hover the row.** Three buttons appear: the pencil ("Edit Routine"), the play icon ("Run now"), and the X ("Delete").
7. **Click the play icon ("Run now").** The route changes to the chat view (`?view=task&task=...&session=...`). Within ~5s:
   - A new user message appears with the prefix `🔁 Routine fire — Test Routine — <timestamp>` followed by the initial_prompt content.
   - The assistant response streams in below it.
8. **Return to the sidebar.** The status dot is now **green** (last_status='success'). The clock icon's tooltip reads something like "Next: in 4 min (HH:MM)".
9. **Click the pencil ("Edit Routine").** The **EditRoutineDialog** opens prefilled with the current values (Name, Initial prompt, "Every 5 min" highlighted, etc.).
10. **Change the name to "Test Routine 2" and click Save.** The dialog closes; the row in the sidebar shows the new name. The session header (chat view) also reflects the new name via the existing cascade.
11. **Click the green `+` on the same item again, this time pick "Standard Chat".** The **AddTaskDialog** opens. Fill in "Standard Task" + description, click "Create Task". The dialog closes; the new standard task appears in the list with the bullet icon (not the clock).
12. **Click the standard task's pencil.** The **RenameTaskModal** opens (NOT the EditRoutineDialog). This is the pre-existing rename flow, unchanged.

### Step 4: Disable the routine and re-fire

13. Open the **Edit Routine** dialog for the test routine, uncheck "Enabled", click Save.
14. Wait for the next fire time, or click "Run now".
15. **Expected:** the dialog shows an error or the run does nothing. (The 409 from the backend should surface in the browser console; the UI should remain on the chat view of the previous run.)

### Step 5: Re-enable and re-fire

16. Open the **Edit Routine** dialog, check "Enabled" again, click Save.
17. Click "Run now". Within ~5s, a new run appears in the chat view.

### Step 6: Cleanup

18. Delete the routine (X button on the row, then confirm). The row disappears.
19. Delete the standard task the same way.

### Acceptance criteria

- [ ] Picker shows two cards; clicking either opens the right dialog.
- [ ] AddRoutineDialog's preset chips populate the cron correctly.
- [ ] AddRoutineDialog's "Custom" toggle reveals a 5-field cron input; bad cron is rejected inline.
- [ ] Routine rows show a clock icon, status dot, and Run Now button.
- [ ] Clicking Run Now fires the routine and navigates to the chat view.
- [ ] Within 5s of clicking Run Now, the chat view shows the new 🔁 user message and the assistant response streams in.
- [ ] Status dot turns green on success, red on failure.
- [ ] Clock tooltip shows the next fire time.
- [ ] Pencil on a routine row opens EditRoutineDialog (with schedule, initial_prompt, enabled).
- [ ] Pencil on a standard row still opens RenameTaskModal.
- [ ] The legacy `task.task_type === 'standard'` (or undefined) path renders the bullet + standard layout unchanged.

---

## Chunk 7 done — checkpoint

- ✅ `WorkspaceItemTask.vue` branches on `task.task_type`
- ✅ Routine rows render clock icon, status dot, Run Now, next-run tooltip
- ✅ Pencil on routine rows emits `editRoutine` (opens EditRoutineDialog)
- ✅ Run Now emits `runRoutine` (parent calls store + routes)
- ✅ Backwards-compat: tasks with no `task_type` render the standard layout
- ✅ `Sidebar.vue` mounts all 4 dialogs (picker + AddTask + AddRoutine + EditRoutine)
- ✅ `handleAddTask` opens the picker (no longer the fast-path)
- ✅ `handleRunRoutine` calls `workspacesStore.runRoutine` + routes to chat
- ✅ `handleEditRoutine` opens EditRoutineDialog
- ✅ E2E walkthrough documented in Task 7.5

## All chunks 5-7 done — final acceptance

Run the full suite one more time:

```bash
cd src/apps/desktop
timeout 180 bunx vitest run 2>&1 | tail -n 20
timeout 180 bun run build 2>&1 | tail -n 20
```

Both clean = the feature is ready for review.

## Files touched in Chunks 5-7 (frontend portion of the task-routines feature)

| File | Change | Lines (est.) |
|---|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | `Task` interface gains `task_type` + `routine`; `addTask` accepts params object; new `runRoutine` + `updateRoutine` actions | +100, -20 |
| `src/apps/desktop/src/api/index.ts` | `createTask` accepts routine params; new `runRoutine`; `updateTaskSimple` accepts routine fields | +50, -10 |
| `src/apps/desktop/src/components/AddTaskPickerDialog.vue` | NEW: two large cards | +90 |
| `src/apps/desktop/src/components/AddRoutineDialog.vue` | NEW: form with preset schedule chips + custom cron | +300 |
| `src/apps/desktop/src/components/EditRoutineDialog.vue` | NEW: prefilled variant of AddRoutine | +280 |
| `src/apps/desktop/src/components/WorkspaceItemTask.vue` | Branch on `task.task_type`; clock icon + Run Now + status dot + tooltip for routines; new `editRoutine` + `runRoutine` events | +150, -20 |
| `src/apps/desktop/src/components/WorkspaceItem.vue` | Re-emit new events | +10 |
| `src/apps/desktop/src/components/WorkspaceList.vue` | Re-emit new events | +10 |
| `src/apps/desktop/src/components/Sidebar.vue` | Picker flow; new dialog mounts; new handlers | +120 |
| `src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts` | NEW: addTask / runRoutine / updateRoutine tests | +250 |
| `src/apps/desktop/src/__tests__/apiRunRoutine.spec.ts` | NEW: api.runRoutine + extended createTask + extended updateTaskSimple | +200 |
| `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts` | NEW | +90 |
| `src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts` | NEW | +150 |
| `src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts` | NEW | +120 |
| `src/apps/desktop/src/__tests__/workspaceItemTaskRoutine.spec.ts` | NEW: routine branch in WorkspaceItemTask | +250 |

Total: ~2200 lines added, 50 removed. Fifteen files touched. All changes are surgical (no refactoring of unrelated code), follow the existing component / store / api style, and ship with a TDD test for every behavior the user-facing UX promises.
