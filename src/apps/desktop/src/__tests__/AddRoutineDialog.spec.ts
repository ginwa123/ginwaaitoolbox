/**
 * Tests for the AddRoutineDialog — the create form. Covers the
 * preset → cron mapping, the custom toggle revealing the cron
 * input, inline cron validation rejecting bad expressions, and
 * submit firing the right payload shape.
 *
 * Note on Teleport + mount: this dialog uses <Teleport to="body">,
 * so we follow the same pattern as imagePreview.spec.ts: attach
 * the wrapper to document.body, query the teleported content via
 * `document.querySelector`, and interact via `element.click()`.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'

import AddRoutineDialog from '../components/dialogs/AddRoutineDialog.vue'

function mountDialog(props: { show: boolean; projectName?: string; apiError?: string | null }) {
  return mount(AddRoutineDialog, { props, attachTo: document.body })
}

describe('AddRoutineDialog', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    // No pinia needed.
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Defensive cleanup of any teleported nodes.
    document.querySelectorAll('[data-testid="add-routine-dialog"]').forEach((el) => el.remove())
  })

  it('preselects "every5" preset and shows the corresponding cron in the preview', async () => {
    wrapper = mountDialog({ show: true })
    await nextTick()
    expect(document.querySelector('[data-testid="preset-every5"]')).not.toBeNull()
    expect(document.querySelector('[data-testid="routine-schedule-preview"]')?.textContent).toContain('*/5 * * * *')
  })

  it('updates the cron preview when a different preset is selected', async () => {
    wrapper = mountDialog({ show: true })
    await nextTick()
    const hourly = document.querySelector<HTMLElement>('[data-testid="preset-hourly"]')!
    expect(hourly).toBeTruthy()
    hourly.click()
    await nextTick()
    expect(document.querySelector('[data-testid="routine-schedule-preview"]')?.textContent).toContain('0 * * * *')
  })

  it('reveals a cron text input when the custom toggle is checked', async () => {
    wrapper = mountDialog({ show: true })
    await nextTick()
    expect(document.querySelector('[data-testid="custom-cron-input"]')).toBeNull()
    const toggle = document.querySelector<HTMLInputElement>('[data-testid="custom-cron-toggle"]')!
    expect(toggle).toBeTruthy()
    toggle.click()
    await nextTick()
    expect(document.querySelector('[data-testid="custom-cron-input"]')).not.toBeNull()
  })

  it('shows an inline error when the user submits an invalid custom cron', async () => {
    wrapper = mountDialog({ show: true })
    await nextTick()
    // Fill required fields.
    const nameInput = document.querySelector<HTMLInputElement>('[data-testid="routine-name"]')!
    nameInput.value = 'Bad'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    const promptArea = document.querySelector<HTMLTextAreaElement>('[data-testid="routine-initial-prompt"]')!
    promptArea.value = 'do thing'
    promptArea.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    // Switch to custom + bad cron
    const toggle = document.querySelector<HTMLInputElement>('[data-testid="custom-cron-toggle"]')!
    toggle.click()
    await nextTick()
    const cronInput = document.querySelector<HTMLInputElement>('[data-testid="custom-cron-input"]')!
    cronInput.value = 'not a cron'
    cronInput.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    const submit = document.querySelector<HTMLButtonElement>('[data-testid="routine-submit"]')!
    submit.click()
    await nextTick()
    const errEl = document.querySelector('[data-testid="routine-error"]')
    expect(errEl).not.toBeNull()
    expect(errEl?.textContent).toMatch(/cron/i)
    // No `create` emitted
    expect(wrapper!.emitted('create')).toBeUndefined()
  })

  it('emits `create` with the right payload when submitted with a valid preset', async () => {
    wrapper = mountDialog({ show: true })
    await nextTick()
    const nameInput = document.querySelector<HTMLInputElement>('[data-testid="routine-name"]')!
    nameInput.value = 'Daily standup'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    const promptArea = document.querySelector<HTMLTextAreaElement>('[data-testid="routine-initial-prompt"]')!
    promptArea.value = 'summarize'
    promptArea.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    const daily = document.querySelector<HTMLElement>('[data-testid="preset-daily"]')!
    daily.click()
    await nextTick()
    const hourInput = document.querySelector<HTMLInputElement>('[data-testid="routine-time-hour"]')!
    hourInput.value = '9'
    hourInput.dispatchEvent(new Event('input', { bubbles: true }))
    const minuteInput = document.querySelector<HTMLInputElement>('[data-testid="routine-time-minute"]')!
    minuteInput.value = '30'
    minuteInput.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    const submit = document.querySelector<HTMLButtonElement>('[data-testid="routine-submit"]')!
    submit.click()

    const emitted = wrapper.emitted('create')
    expect(emitted).toBeDefined()
    expect(emitted!.length).toBe(1)
    const payload = emitted![0]![0] as Record<string, unknown>
    expect(payload).toMatchObject({
      name: 'Daily standup',
      initial_prompt: 'summarize',
      enabled: true,
      schedule: '30 9 * * *',
    })
  })

  it('disables the submit button when name or initial_prompt is empty', async () => {
    wrapper = mountDialog({ show: true })
    await nextTick()
    const submit = document.querySelector<HTMLButtonElement>('[data-testid="routine-submit"]')!
    expect(submit.disabled).toBe(true)
    const nameInput = document.querySelector<HTMLInputElement>('[data-testid="routine-name"]')!
    nameInput.value = 'X'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    expect(submit.disabled).toBe(true)
    const promptArea = document.querySelector<HTMLTextAreaElement>('[data-testid="routine-initial-prompt"]')!
    promptArea.value = 'Y'
    promptArea.dispatchEvent(new Event('input', { bubbles: true }))
    await nextTick()
    expect(submit.disabled).toBe(false)
  })
})
