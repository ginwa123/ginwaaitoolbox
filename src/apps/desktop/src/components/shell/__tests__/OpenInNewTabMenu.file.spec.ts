import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import OpenInNewTabMenu from '../../shell/OpenInNewTabMenu.vue'

describe('OpenInNewTabMenu file item', () => {
  it('hides the file item by default (chat hosts unchanged)', () => {
    const wrapper = mount(OpenInNewTabMenu, {
      props: { x: 10, y: 20 },
      global: { stubs: { teleport: true } },
    })
    expect(wrapper.find('[data-testid="open-new-tab-item"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="open-file-new-tab-item"]').exists()).toBe(false)
  })

  it('shows only the file item for file-only hosts', () => {
    const wrapper = mount(OpenInNewTabMenu, {
      props: { x: 10, y: 20, showChat: false, showFile: true },
      global: { stubs: { teleport: true } },
    })
    expect(wrapper.find('[data-testid="open-new-tab-item"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="open-file-new-tab-item"]').exists()).toBe(true)
  })

  it('emits openFile on file item click', async () => {
    const wrapper = mount(OpenInNewTabMenu, {
      props: { x: 10, y: 20, showChat: false, showFile: true },
      global: { stubs: { teleport: true } },
    })
    await wrapper.get('[data-testid="open-file-new-tab-item"]').trigger('click')
    expect(wrapper.emitted('openFile')).toHaveLength(1)
  })
})
