import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import WriteFile from '../WriteFile.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

describe('WriteFile.vue — readable content when expanded', () => {
  it('renders content as real lines, not escaped JSON, and excludes it from Arguments', () => {
    const wrapper = mount(WriteFile, {
      props: {
        content: { file_write: '/proj/out.txt', error: null },
        parameters: JSON.stringify({ path: '/proj/out.txt', content: 'line1\nline2\nline3' }),
        expanded: true,
      } as never,
    })
    const html = wrapper.html()
    // Readable lines present
    expect(html).toContain('line1')
    expect(html).toContain('line2')
    // Content label with line count
    expect(wrapper.text()).toContain('Content')
    expect(wrapper.text()).toContain('3L')
    // Arguments no longer repeats the blob as escaped JSON
    expect(html).not.toContain('\\n')
    // Path still visible in Arguments (only non-excluded keys)
    expect(html).toContain('/proj/out.txt')
    // Header stays expandable + shows line count
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.findComponent(ToolCardHeader).props('rightMeta')).toBe('3L')
  })

  it('content-only args are still expandable', () => {
    const wrapper = mount(WriteFile, {
      props: {
        content: { file_write: '/proj/only.txt', error: null },
        parameters: JSON.stringify({ content: 'hello' }),
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('hello')
  })

  it('empty content renders (empty) placeholder', () => {
    const wrapper = mount(WriteFile, {
      props: {
        content: { file_write: '/proj/empty.txt', error: null },
        parameters: JSON.stringify({ path: '/proj/empty.txt', content: '' }),
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).toContain('(empty)')
  })
})
