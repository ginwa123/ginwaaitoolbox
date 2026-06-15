import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import ChatView from '../components/ChatView.vue'

describe('renderResponse — nalar_browser inline preview', () => {
  it('mounts ChatView without crashing (smoke test for the new renderResponse branch)', () => {
    const wrapper = mount(ChatView, {
      props: { chatId: 'session_test', chatName: 'Test' },
    })
    expect(wrapper.exists()).toBe(true)
  })
})
