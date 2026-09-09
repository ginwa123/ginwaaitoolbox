import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import UserPillRail, { type UserPill } from '../UserPillRail.vue'

const pills: UserPill[] = [
  { groupIndex: 0, key: 'msg-1', preview: 'hello world', title: 'hello world' },
  { groupIndex: 3, key: 'msg-4', preview: 'second question', title: 'second question' },
  { groupIndex: 7, key: 'msg-8', preview: 'third one here', title: 'third one here' },
]

describe('UserPillRail', () => {
  it('renders one pill per user group', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: null },
      attachTo: document.body,
    })
    expect(wrapper.findAll('[data-testid="user-pill"]').length).toBe(3)
    wrapper.unmount()
  })

  it('renders an accessible label + tooltip per pill', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: null },
      attachTo: document.body,
    })
    const buttons = wrapper.findAll('[data-testid="user-pill"]')
    expect(buttons[0]!.attributes('aria-label')).toBe('Jump to message: hello world')
    expect(buttons[0]!.attributes('title')).toBe('hello world')
    expect(wrapper.find('[data-testid="user-pill-rail"]').attributes('aria-label')).toBe(
      'Jump to user messages',
    )
    wrapper.unmount()
  })

  it('click emits jump with the pill groupIndex + stable key', async () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: null },
      attachTo: document.body,
    })
    await wrapper.findAll('[data-testid="user-pill"]')[1]!.trigger('click')
    expect(wrapper.emitted('jump')).toEqual([[3, 'msg-4']])
    wrapper.unmount()
  })

  it('highlights only the active pill', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: 3 },
      attachTo: document.body,
    })
    const buttons = wrapper.findAll('[data-testid="user-pill"]')
    expect(buttons[0]!.classes()).not.toContain('user-pill--active')
    expect(buttons[1]!.classes()).toContain('user-pill--active')
    expect(buttons[2]!.classes()).not.toContain('user-pill--active')
    wrapper.unmount()
  })

  it('renders no pills for an empty list', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills: [], activeGroupIndex: null },
      attachTo: document.body,
    })
    expect(wrapper.findAll('[data-testid="user-pill"]').length).toBe(0)
    wrapper.unmount()
  })
})
