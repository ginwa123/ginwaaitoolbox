import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { describe, it, expect } from 'vitest'
import InlineEditableText from '@/components/InlineEditableText.vue'

describe('InlineEditableText', () => {
  it('renders the value in display mode by default', () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
    })
    expect(wrapper.text()).toContain('Sprint 12')
    expect(wrapper.find('[data-testid="iet-display"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="iet-edit"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('swaps to edit mode when the display is clicked', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="iet-edit"]').exists()).toBe(true)
    const input = wrapper.find('[data-testid="iet-input"]').element as HTMLInputElement
    expect(input.value).toBe('Sprint 12')
    wrapper.unmount()
  })

  it('emits save with the trimmed value when Save is clicked', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('  Sprint 13  ')
    await wrapper.find('[data-testid="iet-save"]').trigger('click')
    const emitted = wrapper.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })

  it('emits save when the input loses focus after a non-empty edit', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('Sprint 13')
    await input.trigger('blur')
    const emitted = wrapper.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })

  it('does not emit save when the trimmed value equals the original', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('  Sprint 12  ')
    await wrapper.find('[data-testid="iet-save"]').trigger('click')
    expect(wrapper.emitted('save')).toBeFalsy()
    wrapper.unmount()
  })

  it('emits cancel when Cancel is clicked', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="iet-cancel"]').trigger('click')
    expect(wrapper.emitted('cancel')).toBeTruthy()
    expect(wrapper.emitted('save')).toBeFalsy()
    wrapper.unmount()
  })

  it('emits cancel on Escape', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="iet-input"]').trigger('keydown', { key: 'Escape' })
    expect(wrapper.emitted('cancel')).toBeTruthy()
    wrapper.unmount()
  })

  it('emits save on Enter', async () => {
    const wrapper = mount(InlineEditableText, {
      props: { value: 'Sprint 12', ariaLabel: 'kanban name', testId: 'iet' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="iet-display"]').trigger('click')
    await nextTick()
    const input = wrapper.find('[data-testid="iet-input"]')
    await input.setValue('Sprint 13')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('save')?.[0]).toEqual(['Sprint 13'])
    wrapper.unmount()
  })
})