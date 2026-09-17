import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import FileInput from '../components/file/FileInput.vue'

function mountInput(props: Record<string, unknown> = {}) {
  return mount(FileInput, {
    props: { cwd: '/tmp', ...props },
  })
}

describe('FileInput initializing gate', () => {
  it('enables textarea + send button when ready', () => {
    const wrapper = mountInput()
    const textarea = wrapper.find('[data-testid="chat-message-textarea"]')
    expect(textarea.attributes('disabled')).toBeUndefined()
    expect(
      wrapper.find('[data-testid="send-message-button"]').attributes('disabled'),
    ).toBeUndefined()
    wrapper.unmount()
  })

  it('disables textarea + send button while initializing', () => {
    const wrapper = mountInput({ isInitializing: true })
    expect(
      wrapper.find('[data-testid="chat-message-textarea"]').attributes('disabled'),
    ).toBeDefined()
    expect(wrapper.find('[data-testid="send-message-button"]').attributes('disabled')).toBeDefined()
    wrapper.unmount()
  })
})
