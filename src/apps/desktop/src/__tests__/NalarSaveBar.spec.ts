import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import NalarSaveBar from '../components/nalar/NalarSaveBar.vue'

describe('NalarSaveBar', () => {
  it('renders nothing when not dirty', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: false, unsavedCount: 0, saving: false },
    })
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)
  })

  it('renders the dirty pill with the count when dirty', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 3, saving: false },
    })
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('3 unsaved changes')
  })

  it('uses singular "change" when unsavedCount is 1', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    expect(wrapper.text()).toContain('1 unsaved change')
    expect(wrapper.text()).not.toContain('1 unsaved changes')
  })

  it('emits reset when the Reset button is clicked', async () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    await wrapper.find('[data-testid="reset-btn"]').trigger('click')
    expect(wrapper.emitted('reset')).toBeTruthy()
  })

  it('emits save when the Save button is clicked', async () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    expect(wrapper.emitted('save')).toBeTruthy()
  })

  it('disables both buttons when saving is true', () => {
    const wrapper = mount(NalarSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: true },
    })
    expect((wrapper.find('[data-testid="reset-btn"]').element as HTMLButtonElement).disabled).toBe(true)
    expect((wrapper.find('[data-testid="save-btn"]').element as HTMLButtonElement).disabled).toBe(true)
  })
})
