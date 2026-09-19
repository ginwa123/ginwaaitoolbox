import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ToolParameters from '../ToolParameters.vue'

describe('ToolParameters exclude', () => {
  it('hides excluded keys but keeps the rest', () => {
    const wrapper = mount(ToolParameters, {
      props: {
        parameters: JSON.stringify({ path: '/a.txt', old_str: 'AAA', new_str: 'BBB' }),
        exclude: ['old_str', 'new_str'],
      },
    })
    const pre = wrapper.find('pre')
    expect(pre.exists()).toBe(true)
    expect(pre.text()).toContain('/a.txt')
    expect(pre.text()).not.toContain('AAA')
    expect(pre.text()).not.toContain('old_str')
  })

  it('renders nothing when every key is excluded', () => {
    const wrapper = mount(ToolParameters, {
      props: {
        parameters: JSON.stringify({ old_str: 'AAA', new_str: 'BBB' }),
        exclude: ['old_str', 'new_str'],
      },
    })
    expect(wrapper.find('details').exists()).toBe(false)
  })

  it('passes raw/XML payloads through untouched', () => {
    const raw = '<path>/foo</path>'
    const wrapper = mount(ToolParameters, {
      props: { parameters: raw, exclude: ['path'] },
    })
    expect(wrapper.find('pre').text()).toContain(raw)
  })
})
