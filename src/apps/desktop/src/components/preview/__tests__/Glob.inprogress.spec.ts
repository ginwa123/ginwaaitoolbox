import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import Glob from '../Glob.vue'

describe('Glob.vue — in-progress', () => {
  it('shows pattern from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(Glob, {
      props: {
        content: '',
        parameters: '<pattern>**/*.zig</pattern><path>/tmp/repo</path>',
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('**/*.zig')
    expect(html).not.toContain('unknown')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(Glob, {
      props: {
        content: '',
        parameters: '<pattern>**/*.zig</pattern>',
      } as never,
    })
    expect(running.find('[data-testid="glob-running"]').exists()).toBe(true)
    const done = mount(Glob, {
      props: {
        content: {
          pattern: '**/*.zig',
          total: 0,
          returned: 0,
          offset: 0,
          truncated: 0,
          files: [],
          warning: null,
        },
        parameters: '<pattern>**/*.zig</pattern>',
      } as never,
    })
    expect(done.find('[data-testid="glob-running"]').exists()).toBe(false)
  })
})
