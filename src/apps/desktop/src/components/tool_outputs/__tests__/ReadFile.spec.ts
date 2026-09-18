import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ReadFile from '../ReadFile.vue'

const makeWrapper = (props: { content: unknown; parameters?: string; expanded?: boolean }) =>
  mount(ReadFile, { props: { expanded: true, ...props } as never })

const gutters = (wrapper: ReturnType<typeof makeWrapper>): string[] =>
  wrapper.findAll('.rf-gutter').map((s) => s.text())

const lines = (wrapper: ReturnType<typeof makeWrapper>): Array<string | null> =>
  // textContent, not .text(): VTU trims whitespace, which would hide
  // indentation regressions in the raw-content rendering.
  wrapper.findAll('.rf-line').map((s) => s.element.textContent)

describe('ReadFile.vue — line-number gutter from start_line', () => {
  it('derives 1-indexed gutter numbers from start_line', () => {
    const wrapper = makeWrapper({
      content: {
        path: '/x.txt',
        content: 'alpha\nbeta',
        total_lines: 32,
        start_line: 10,
        end_line: 11,
      },
    })
    expect(gutters(wrapper)).toEqual(['11', '12'])
    expect(lines(wrapper)).toEqual(['alpha', 'beta'])
  })

  it('starts at 1 when start_line is missing', () => {
    const wrapper = makeWrapper({
      content: { path: '/x.txt', content: 'a\nb\nc' },
    })
    expect(gutters(wrapper)).toEqual(['1', '2', '3'])
  })

  it('does not render a phantom row for a trailing newline', () => {
    const wrapper = makeWrapper({
      content: {
        path: '/x.txt',
        content: 'a\nb\n',
        total_lines: 2,
        start_line: 0,
        end_line: 1,
      },
    })
    expect(gutters(wrapper)).toEqual(['1', '2'])
    expect(wrapper.html()).toContain('2L')
  })

  it('renders raw content verbatim (indentation preserved, no prefixes)', () => {
    const wrapper = makeWrapper({
      content: {
        path: '/x.txt',
        content: '  indented\n\ttabbed',
        total_lines: 2,
        start_line: 0,
        end_line: 1,
      },
    })
    expect(lines(wrapper)).toEqual(['  indented', '\ttabbed'])
  })

  it('shows (empty) when there is no content', () => {
    const wrapper = makeWrapper({
      content: { path: '/x.txt', content: '' },
      parameters: JSON.stringify({ path: '/x.txt' }),
    })
    expect(wrapper.findAll('.rf-gutter')).toHaveLength(0)
    expect(wrapper.html()).toContain('(empty)')
  })

  it('accepts the data payload as a JSON string', () => {
    const wrapper = makeWrapper({
      content: JSON.stringify({ path: '/x.txt', content: 'a\nb', start_line: 0 }),
    })
    expect(gutters(wrapper)).toEqual(['1', '2'])
  })

  it('renders <>& in content verbatim without entity decoding', () => {
    const wrapper = makeWrapper({
      content: { path: '/x.txt', content: '<div>& "hi"</div>', start_line: 0 },
    })
    expect(lines(wrapper)).toEqual(['<div>& "hi"</div>'])
  })
})
