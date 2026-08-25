/**
 * Tests for NalarGeneralSection.vue — the General tab in Nalar settings.
 *
 * Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: this section
 * surfaces three operational settings that previously lived only in
 * config.json (`notify_on_complete`, `retry_delay_ms`) plus a NEW toggle
 * (`notify_on_error`). All three are persisted through the same PUT
 * `/api/config/nalar` round-trip; this spec verifies the UI-side contract:
 *
 *   1. The two toggles reflect `modelValue` and emit `update:modelValue`
 *      with the flipped boolean when clicked.
 *   2. The retry-delay input reflects `modelValue.retry_delay_ms`
 *      (in seconds — the UI converts to ms before emitting) and emits
 *      `update:modelValue` with the new ms value when changed.
 *   3. Values are clamped to the same range the backend applies
 *      (0–60 000 ms).
 *
 * The spec runs the component standalone with `defineModel<...>` —
 * vitest's mount helper auto-wires the v-model, so the parent's
 * NalarSettings.vue is not exercised here (that's covered by
 * `NalarSettings.spec.ts`'s "General tab" tests).
 */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import NalarGeneralSection, {
  type NalarGeneralSettings,
} from '../components/nalar/NalarGeneralSection.vue'

const DEFAULT_SETTINGS: NalarGeneralSettings = {
  notify_on_complete: false,
  notify_on_error: false,
  retry_delay_ms: 0,
}

describe('NalarGeneralSection', () => {
  it('renders both toggles and the retry-delay input', () => {
    const wrapper = mount(NalarGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS } },
    })
    expect(wrapper.find('[data-testid="toggle-notify-on-complete"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="toggle-notify-on-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="input-retry-delay-seconds"]').exists()).toBe(true)
    // Human-readable copy.
    expect(wrapper.text()).toContain('Notify when agent finishes')
    expect(wrapper.text()).toContain('Notify when agent fails')
    expect(wrapper.text()).toContain('Retry delay')
  })

  it('reflects the loaded settings in the toggles + input', () => {
    const wrapper = mount(NalarGeneralSection, {
      props: {
        modelValue: {
          notify_on_complete: true,
          notify_on_error: true,
          retry_delay_ms: 15000, // 15 seconds
        },
      },
    })
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-complete"]').element as HTMLInputElement).checked,
    ).toBe(true)
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-error"]').element as HTMLInputElement).checked,
    ).toBe(true)
    expect(
      Number((wrapper.find('[data-testid="input-retry-delay-seconds"]').element as HTMLInputElement).value),
    ).toBe(15)
    expect(wrapper.text()).toContain('15000 ms')
  })

  it('clicking notify_on_complete emits update:modelValue with the flipped boolean', async () => {
    const wrapper = mount(NalarGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS, notify_on_complete: false } },
    })
    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    expect(wrapper.emitted('update:modelValue')?.[0]?.[0]).toEqual({
      notify_on_complete: true,
      notify_on_error: false,
      retry_delay_ms: 0,
    })
  })

  it('clicking notify_on_error emits update:modelValue with the flipped boolean (independent from complete)', async () => {
    // Lock the contract that the two toggles are independent — toggling
    // notify_on_error MUST NOT silently flip notify_on_complete.
    const wrapper = mount(NalarGeneralSection, {
      props: {
        modelValue: {
          notify_on_complete: true,
          notify_on_error: false,
          retry_delay_ms: 5000,
        },
      },
    })
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as NalarGeneralSettings
    expect(emitted.notify_on_error).toBe(true)
    expect(emitted.notify_on_complete).toBe(true)
    expect(emitted.retry_delay_ms).toBe(5000)
  })

  it('typing a new retry delay (in seconds) emits update:modelValue with the millisecond value', async () => {
    const wrapper = mount(NalarGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS, retry_delay_ms: 0 } },
    })
    await wrapper.find('[data-testid="input-retry-delay-seconds"]').setValue('5')
    expect(wrapper.emitted('update:modelValue')?.[0]?.[0]).toEqual({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 5000, // 5 sec → 5000 ms
    })
  })

  it('clamps retry-delay input to [0, 60] seconds (matches the backend 0–60_000 ms cap)', async () => {
    const wrapper = mount(NalarGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS } },
    })
    const input = wrapper.find('[data-testid="input-retry-delay-seconds"]')

    // Above the max → clamps to 60 sec = 60_000 ms.
    await input.setValue('999')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as NalarGeneralSettings
    expect(emitted.retry_delay_ms).toBe(60_000)

    // Negative → clamps to 0.
    await input.setValue('-5')
    const emitted2 = wrapper.emitted('update:modelValue')?.[1]?.[0] as NalarGeneralSettings
    expect(emitted2.retry_delay_ms).toBe(0)
  })

  it('toggling a control does not lose the OTHER settings (whole-object emit)', async () => {
    // The component emits the FULL settings object on each change
    // (not a partial patch). Lock that contract so the parent's
    // v-model never drops a sibling field.
    const wrapper = mount(NalarGeneralSection, {
      props: {
        modelValue: {
          notify_on_complete: true,
          notify_on_error: false,
          retry_delay_ms: 30000,
        },
      },
    })
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as NalarGeneralSettings
    expect(emitted).toEqual({
      notify_on_complete: true,
      notify_on_error: true,
      retry_delay_ms: 30000,
    })
  })
})