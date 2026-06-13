# Add Task Routines — Chunk 6 (Tests): Spec files for the three dialogs

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**This file continues Chunk 6 from `chunks-6.md`.** It contains the three test tasks (6.5, 6.6, 6.7) that gate the three components created in `chunks-6.md` (Tasks 6.1, 6.2, 6.3). The components must already exist for these tests to pass — see `chunks-6.md` for the implementation steps.

**Spec:** [`docs/plans/2026-06-13-add-task-routines-design.md`](../../plans/2026-06-13-add-task-routines-design.md) (Section: "Frontend UX" → "AddTaskPickerDialog", "AddRoutineDialog", "EditRoutineDialog").
**Parent plan:** [`docs/superpowers/plans/2026-06-13-add-task-routines.md`](2026-06-13-add-task-routines.md).
**Components (Chunk 6, Tasks 6.1-6.4):** [`chunks-6.md`](2026-06-13-add-task-routines-chunks-6.md).
**Integration (Chunk 7):** [`chunks-7.md`](2026-06-13-add-task-routines-chunks-7.md).

---

## Task 6.5: Test `AddTaskPickerDialog`

**Files:**
- Create: `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts`

### Step 1: Run the test, verify it FAILS

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/AddTaskPickerDialog.spec.ts 2>&1 | tail -n 30`
Expected: FAIL with `Failed to resolve import "../components/AddTaskPickerDialog"`.

(We wrote the component in Task 6.1 already; this test task is the gate.)

### Step 2: Write the test (the test is the failing step here)

Create `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts`:

```ts
/**
 * Tests for the AddTaskPickerDialog — two large cards shown when
 * the user clicks the green `+` button on a workspace item. The
 * parent (Sidebar) decides which creation flow to open based on
 * the `pick` event payload.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'

import AddTaskPickerDialog from '../components/AddTaskPickerDialog.vue'

describe('AddTaskPickerDialog', () => {
  beforeEach(() => {
    // No pinia / localStorage needed — this is a pure presentational
    // component.
  })

  afterEach(() => {
    // No teardown needed.
  })

  it('does not render anything when show=false', () => {
    const wrapper = mount(AddTaskPickerDialog, { props: { show: false } })
    expect(wrapper.find('[data-testid="add-task-picker"]').exists()).toBe(false)
  })

  it('renders both cards when show=true', async () => {
    const wrapper = mount(AddTaskPickerDialog, { props: { show: true } })
    expect(wrapper.find('[data-testid="add-task-picker"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="picker-standard"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="picker-routine"]').exists()).toBe(true)
    // Human-readable labels present
    expect(wrapper.text()).toContain('Standard Chat')
    expect(wrapper.text()).toContain('Routine')
  })

  it('emits pick="standard" when the Standard Chat card is clicked', async () => {
    const wrapper = mount(AddTaskPickerDialog, { props: { show: true } })
    await wrapper.find('[data-testid="picker-standard"]').trigger('click')
    const emitted = wrapper.emitted('pick')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['standard'])
  })

  it('emits pick="routine" when the Routine card is clicked', async () => {
    const wrapper = mount(AddTaskPickerDialog, { props: { show: true } })
    await wrapper.find('[data-testid="picker-routine"]').trigger('click')
    const emitted = wrapper.emitted('pick')
    expect(emitted).toBeDefined()
    expect(emitted![0]).toEqual(['routine'])
  })

  it('emits close when the Cancel button is clicked', async () => {
    const wrapper = mount(AddTaskPickerDialog, { props: { show: true } })
    // The Cancel button is the only one in the footer; the cards
    // are <button>s in the body, so the footer button is the one
    // outside any [data-testid] card. We use text matching.
    const cancelBtn = wrapper.findAll('button').find((b) => b.text() === 'Cancel')
    expect(cancelBtn).toBeDefined()
    await cancelBtn!.trigger('click')
    expect(wrapper.emitted('close')).toBeDefined()
  })
})
```

### Step 3: Run the test, verify it PASSES

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/AddTaskPickerDialog.spec.ts 2>&1 | tail -n 30`
Expected: PASS (5/5).

### Step 4: Type-check + commit

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean.

```bash
git add src/apps/desktop/src/components/AddTaskPickerDialog.vue \
        src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts
git commit -m "feat(routines): AddTaskPickerDialog with two cards (standard + routine)"
```

---

## Task 6.6: Test `AddRoutineDialog` (preset → cron, custom toggle, submit)

**Files:**
- Create: `src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts`

### Step 1: Run the test, verify it FAILS

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/AddRoutineDialog.spec.ts 2>&1 | tail -n 30`
Expected: FAIL with `Failed to resolve import "../components/AddRoutineDialog"`.

### Step 2: Write the test

Create `src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts`:

```ts
/**
 * Tests for the AddRoutineDialog — the create form. Covers the
 * preset → cron mapping, the custom toggle revealing the cron
 * input, inline cron validation rejecting bad expressions, and
 * submit firing the right payload shape.
 */
import { beforeEach, describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

import AddRoutineDialog from '../components/AddRoutineDialog.vue'

async function openDialog(props: Record<string, unknown> = {}) {
  const wrapper = mount(AddRoutineDialog, { props: { show: false, ...props } })
  await wrapper.setProps({ show: true })
  await nextTick()
  return wrapper
}

describe('AddRoutineDialog', () => {
  beforeEach(() => {
    // No pinia needed.
  })

  it('preselects "every5" preset and shows the corresponding cron in the preview', async () => {
    const wrapper = await openDialog()
    expect(wrapper.find('[data-testid="preset-every5"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="routine-schedule-preview"]').text()).toContain('*/5 * * * *')
  })

  it('updates the cron preview when a different preset is selected', async () => {
    const wrapper = await openDialog()
    await wrapper.find('[data-testid="preset-hourly"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="routine-schedule-preview"]').text()).toContain('0 * * * *')
  })

  it('reveals a cron text input when the custom toggle is checked', async () => {
    const wrapper = await openDialog()
    expect(wrapper.find('[data-testid="custom-cron-input"]').exists()).toBe(false)
    await wrapper.find('[data-testid="custom-cron-toggle"]').setValue(true)
    await nextTick()
    expect(wrapper.find('[data-testid="custom-cron-input"]').exists()).toBe(true)
  })

  it('shows an inline error when the user submits an invalid custom cron', async () => {
    const wrapper = await openDialog()
    // Fill required fields.
    await wrapper.find('[data-testid="routine-name"]').setValue('Bad')
    await wrapper.find('[data-testid="routine-initial-prompt"]').setValue('do thing')
    // Switch to custom + bad cron
    await wrapper.find('[data-testid="custom-cron-toggle"]').setValue(true)
    await nextTick()
    await wrapper.find('[data-testid="custom-cron-input"]').setValue('not a cron')
    await wrapper.find('[data-testid="routine-submit"]').trigger('click')
    expect(wrapper.find('[data-testid="routine-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="routine-error"]').text()).toMatch(/cron/i)
    // No `create` emitted
    expect(wrapper.emitted('create')).toBeUndefined()
  })

  it('emits `create` with the right payload when submitted with a valid preset', async () => {
    const wrapper = await openDialog()
    await wrapper.find('[data-testid="routine-name"]').setValue('Daily standup')
    await wrapper.find('[data-testid="routine-initial-prompt"]').setValue('summarize')
    await wrapper.find('[data-testid="preset-daily"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="routine-time-hour"]').setValue(9)
    await wrapper.find('[data-testid="routine-time-minute"]').setValue(30)
    await nextTick()
    await wrapper.find('[data-testid="routine-submit"]').trigger('click')

    const emitted = wrapper.emitted('create')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({
      name: 'Daily standup',
      initial_prompt: 'summarize',
      enabled: true,
      schedule: '30 9 * * *',
    })
  })

  it('disables the submit button when name or initial_prompt is empty', async () => {
    const wrapper = await openDialog()
    const submit = wrapper.find<HTMLButtonElement>('[data-testid="routine-submit"]')
    expect(submit.element.disabled).toBe(true)
    await wrapper.find('[data-testid="routine-name"]').setValue('X')
    expect(submit.element.disabled).toBe(true)
    await wrapper.find('[data-testid="routine-initial-prompt"]').setValue('Y')
    await nextTick()
    expect(submit.element.disabled).toBe(false)
  })
})
```

### Step 3: Run the test, verify it PASSES

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/AddRoutineDialog.spec.ts 2>&1 | tail -n 30`
Expected: PASS (6/6).

### Step 4: Type-check + commit

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean.

```bash
git add src/apps/desktop/src/components/AddRoutineDialog.vue \
        src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts
git commit -m "feat(routines): AddRoutineDialog with preset schedule chips + custom cron"
```

---

## Task 6.7: Test `EditRoutineDialog` (prefilled, PATCH submit)

**Files:**
- Create: `src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts`

### Step 1: Run the test, verify it FAILS

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/EditRoutineDialog.spec.ts 2>&1 | tail -n 30`
Expected: FAIL with `Failed to resolve import "../components/EditRoutineDialog"`.

### Step 2: Write the test

Create `src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts`:

```ts
/**
 * Tests for the EditRoutineDialog — same shape as AddRoutineDialog
 * but prefilled with the routine's current values and emitting
 * `submit` instead of `create`. The parent (Sidebar) wires
 * `submit` to `workspacesStore.updateRoutine(...)`.
 */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

import EditRoutineDialog from '../components/EditRoutineDialog.vue'
import type { RoutineMeta } from '../stores/workspaces'

const baseRoutine: RoutineMeta = {
  schedule: '0 9 * * 1-5',
  initial_prompt: 'summarize commits',
  enabled: true,
  last_run_at: null,
  next_run_at: '2099-01-01 09:00:00',
  last_status: null,
  last_error: null,
}

async function openEditDialog(props: Record<string, unknown> = {}) {
  const wrapper = mount(EditRoutineDialog, {
    props: { show: false, routine: baseRoutine, taskName: 'Daily', ...props },
  })
  await wrapper.setProps({ show: true })
  await nextTick()
  return wrapper
}

describe('EditRoutineDialog', () => {
  it('prefills name, initial_prompt, enabled, and the matching preset', async () => {
    const wrapper = await openEditDialog()
    // The weekday preset matches "0 9 * * 1-5" via the regex.
    const nameInput = wrapper.find<HTMLInputElement>('[data-testid="edit-routine-name"]')
    expect(nameInput.element.value).toBe('Daily')
    const promptTextarea = wrapper.find<HTMLTextAreaElement>('[data-testid="edit-routine-initial-prompt"]')
    expect(promptTextarea.element.value).toBe('summarize commits')
    const enabledBox = wrapper.find<HTMLInputElement>('[data-testid="edit-routine-enabled"]')
    expect(enabledBox.element.checked).toBe(true)
    // The weekday preset is highlighted (we check via the cron preview
    // containing the original schedule, which is the more user-visible signal).
    expect(wrapper.find('[data-testid="edit-schedule-preview"]').text()).toContain('0 9 * * 1-5')
  })

  it('does not render when routine=null (closed state)', async () => {
    const wrapper = mount(EditRoutineDialog, {
      props: { show: false, routine: null, taskName: 'X' },
    })
    expect(wrapper.find('[data-testid="edit-routine-dialog"]').exists()).toBe(false)
  })

  it('emits `submit` with the right payload when the form is saved', async () => {
    const wrapper = await openEditDialog()
    // Change the name and submit.
    await wrapper.find('[data-testid="edit-routine-name"]').setValue('Renamed standup')
    await wrapper.find('[data-testid="edit-routine-submit"]').trigger('click')

    const emitted = wrapper.emitted('submit')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({
      name: 'Renamed standup',
      initial_prompt: 'summarize commits',
      schedule: '0 9 * * 1-5',
      enabled: true,
    })
  })

  it('shows the custom cron input when the schedule is not a preset match', async () => {
    const wrapper = await openEditDialog({
      routine: { ...baseRoutine, schedule: '15,45 * * * *' },
    })
    // '15,45 * * * *' doesn't match any preset; the custom input
    // should be revealed automatically.
    expect(wrapper.find('[data-testid="edit-custom-cron-input"]').exists()).toBe(true)
    const input = wrapper.find<HTMLInputElement>('[data-testid="edit-custom-cron-input"]')
    expect(input.element.value).toBe('15,45 * * * *')
  })
})
```

### Step 3: Run the test, verify it PASSES

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/EditRoutineDialog.spec.ts 2>&1 | tail -n 30`
Expected: PASS (4/4).

### Step 4: Type-check + commit

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean.

```bash
git add src/apps/desktop/src/components/EditRoutineDialog.vue \
        src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts
git commit -m "feat(routines): EditRoutineDialog prefilled with current values"
```

---

## Chunk 6 done — checkpoint

- ✅ `AddTaskPickerDialog` — two cards (Standard / Routine) emitting `pick`
- ✅ `AddRoutineDialog` — full create form with preset schedule chips + custom cron
- ✅ `EditRoutineDialog` — same form prefilled with the routine's current values
- ✅ Tests for all three dialogs
- ✅ `AddTaskDialog` verified for the Standard path (no change needed)

Next: **Chunk 7 — Frontend integration** (Sidebar picker flow + `WorkspaceItemTask` routine rendering). See `chunks-7.md`.
