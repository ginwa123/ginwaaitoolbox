/**
 * Tests for the routine-task branch of the per-task row.
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
 *
 * History:
 *   - These tests previously targeted <WorkspaceItemTask> (the
 *     pre-split single component with a `variant` prop). After the
 *     2026-07-02 split, the routine branch lives in
 *     <WorkspaceItemTaskRow> (sidebar list) and <WorkspaceItemTaskCard>
 *     (kanban). The shared logic is in composables/useTaskActions.ts.
 *     These tests target the Row component because routines are
 *     primarily managed from the sidebar list; the Card component
 *     uses the same routine branch and is covered indirectly by
 *     workspaceItemTaskCard.spec.ts.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItemTaskRow from '../components/WorkspaceItemTaskRow.vue'
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
  const wrapper = mount(WorkspaceItemTaskRow, {
    props: { task, workspaceId, itemId },
    global: { provide: { processingState } },
  })
  return { wrapper, processingState }
}

describe('WorkspaceItemTaskRow — routine branch', () => {
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
    // The standard bullet (w-1.5 h-1.5 rounded-full) must NOT render
    // in the routine branch. The status dot uses the same w-1.5.h-1.5
    // class — so we distinguish by data-testid: the bullet has none,
    // the status dot has data-testid="routine-status-dot". We assert
    // that ALL w-1.5 h-1.5 spans carry the status-dot testid.
    const allW1_5 = wrapper.findAll('span.w-1\\.5.h-1\\.5.rounded-full')
    expect(allW1_5.length).toBeGreaterThanOrEqual(1) // the status dot
    for (const w of allW1_5) {
      expect(w.attributes('data-testid')).toBe('routine-status-dot')
    }
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
    // jsdom normalizes the hex literal to rgb() form, so assert the
    // rgb(34, 197, 94) value (= #22c55e, Tailwind green-500) directly.
    const style = dot.attributes('style') ?? ''
    expect(style).toContain('rgb(34, 197, 94)')
  })

  it('renders the status dot red for last_status="failed"', () => {
    const { wrapper } = mountTask(makeRoutineTask({ last_status: 'failed' }))
    const dot = wrapper.find('[data-testid="routine-status-dot"]')
    // jsdom normalizes #ef4444 → rgb(239, 68, 68).
    expect(dot.attributes('style') ?? '').toContain('rgb(239, 68, 68)')
  })

  it('renders the status dot gray when last_status is null (never fired)', () => {
    const { wrapper } = mountTask(makeRoutineTask({ last_status: null }))
    const dot = wrapper.find('[data-testid="routine-status-dot"]')
    // jsdom normalizes #9ca3af → rgb(156, 163, 175).
    expect(dot.attributes('style') ?? '').toContain('rgb(156, 163, 175)')
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
