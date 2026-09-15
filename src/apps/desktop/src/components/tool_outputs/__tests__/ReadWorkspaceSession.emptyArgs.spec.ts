import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ReadWorkspaceSession from '../ReadWorkspaceSession.vue'

const EMPTY_SEARCH = [
  `<read_workspace_session behavior="search" offset="0" limit="20">`,
  `  <query>no-such-string</query>`,
  `  <count>0</count>`,
  `  <total_count>0</total_count>`,
  `  <results>`,
  `  </results>`,
  `</read_workspace_session>`,
].join('\n')

describe('ReadWorkspaceSession.vue — empty results with args shows Arguments when expanded', () => {
  it('expanded body shows Arguments on empty results', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: EMPTY_SEARCH,
        parameters: '{"query":"no-such-string"}',
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="read-workspace-session-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })

  it('header click expands on empty results when args present', async () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: EMPTY_SEARCH,
        parameters: '{"query":"no-such-string"}',
      },
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('Arguments')
  })
})
