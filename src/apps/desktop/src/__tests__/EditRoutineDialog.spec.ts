/**
 * Tests for the EditRoutineDialog — same shape as AddRoutineDialog
 * but prefilled with the routine's current values and emitting
 * `submit` instead of `create`. The parent (Sidebar) wires
 * `submit` to `workspacesStore.updateRoutine(...)`.
 *
 * Note on Teleport + mount: same pattern as AddTaskPickerDialog.spec.ts
 * and AddRoutineDialog.spec.ts — attachTo: document.body and
 * document.querySelector for the teleported DOM.
 *
 * Note on the open lifecycle: the component's `watch(() =>
 * props.show, ...)` only fires on a CHANGE. So to trigger
 * applyPrefill in the test, we mount with `show: false` and then
 * call `wrapper.setProps({ show: true })`. This mirrors how a
 * real consumer opens the dialog: it was hidden, the user clicks
 * something, the prop flips to true, the watcher fires.
 */
import { afterEach, describe, expect, it } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
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

async function openEditDialog(
  props: { routine: RoutineMeta | null; taskName: string; apiError?: string | null } = {
    routine: baseRoutine,
    taskName: 'Daily',
  },
) {
  // Mount closed first so the `watch(() => props.show, ...)`
  // handler fires when we toggle to true below.
  const w = mount(EditRoutineDialog, {
    props: { show: false, ...props },
    attachTo: document.body,
  })
  await w.setProps({ show: true })
  await nextTick()
  return w
}

describe('EditRoutineDialog', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.querySelectorAll('[data-testid="edit-routine-dialog"]').forEach((el) => el.remove())
  })

  it('prefills name, initial_prompt, enabled, and the matching preset', async () => {
    wrapper = await openEditDialog({ routine: baseRoutine, taskName: 'Daily' })
    const nameInput = document.querySelector<HTMLInputElement>('[data-testid="edit-routine-name"]')!
    expect(nameInput.value).toBe('Daily')
    const promptTextarea = document.querySelector<HTMLTextAreaElement>(
      '[data-testid="edit-routine-initial-prompt"]',
    )!
    expect(promptTextarea.value).toBe('summarize commits')
    const enabledBox = document.querySelector<HTMLInputElement>('[data-testid="edit-routine-enabled"]')!
    expect(enabledBox.checked).toBe(true)
    // The weekday preset is highlighted (we check via the cron preview
    // containing the original schedule, which is the more user-visible signal).
    expect(document.querySelector('[data-testid="edit-schedule-preview"]')?.textContent).toContain('0 9 * * 1-5')
  })

  it('does not render when routine=null (closed state)', () => {
    const w = mount(EditRoutineDialog, {
      props: { show: false, routine: null, taskName: 'X' },
      attachTo: document.body,
    })
    expect(document.querySelector('[data-testid="edit-routine-dialog"]')).toBeNull()
    w.unmount()
  })

  it('emits `submit` with the right payload when the form is saved', async () => {
    wrapper = await openEditDialog({ routine: baseRoutine, taskName: 'Daily' })
    // Change the name and submit.
    const nameInput = document.querySelector<HTMLInputElement>('[data-testid="edit-routine-name"]')!
    nameInput.value = 'Renamed standup'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    const submit = document.querySelector<HTMLButtonElement>('[data-testid="edit-routine-submit"]')!
    submit.click()

    const emitted = wrapper.emitted('submit')
    expect(emitted).toBeDefined()
    expect(emitted!.length).toBe(1)
    const payload = emitted![0]![0] as Record<string, unknown>
    expect(payload).toMatchObject({
      name: 'Renamed standup',
      initial_prompt: 'summarize commits',
      schedule: '0 9 * * 1-5',
      enabled: true,
    })
  })

  it('shows the custom cron input when the schedule is not a preset match', async () => {
    wrapper = await openEditDialog({
      routine: { ...baseRoutine, schedule: '15,45 * * * *' },
      taskName: 'Daily',
    })
    // '15,45 * * * *' doesn't match any preset; the custom input
    // should be revealed automatically.
    const input = document.querySelector<HTMLInputElement>('[data-testid="edit-custom-cron-input"]')
    expect(input).not.toBeNull()
    expect(input!.value).toBe('15,45 * * * *')
  })
})
