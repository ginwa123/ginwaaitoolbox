import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ReadCompactedMessages from '../ReadCompactedMessages.vue'

describe('ReadCompactedMessages.vue — in-progress', () => {
  it('shows mode from :parameters when :content is empty, not bare read', () => {
    const wrapper = mount(ReadCompactedMessages, {
      props: {
        content: '',
        parameters: '{"mode":"index"}',
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('index mode')
    expect(html).not.toContain('>read<')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(ReadCompactedMessages, {
      props: {
        content: '',
        parameters: '{"mode":"full"}',
      } as never,
    })
    expect(running.find('[data-testid="read-compacted-messages-running"]').exists()).toBe(true)
    const done = mount(ReadCompactedMessages, {
      props: {
        content: { mode: 'index', count: 0, message_index: [] },
        parameters: '{"mode":"index"}',
      } as never,
    })
    expect(done.find('[data-testid="read-compacted-messages-running"]').exists()).toBe(false)
  })
})
