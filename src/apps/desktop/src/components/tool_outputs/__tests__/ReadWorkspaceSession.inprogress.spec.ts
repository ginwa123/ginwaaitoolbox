import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ReadWorkspaceSession from '../ReadWorkspaceSession.vue'

describe('ReadWorkspaceSession.vue — in-progress', () => {
  it('shows query from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: '',
        parameters: '<query>login bug</query>',
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('login bug')
    expect(html).toContain('workspace search')
    expect(html).not.toContain('read_workspace_session ·')
  })

  it('shows session fallback from :parameters when :content is empty', () => {
    const wrapper = mount(ReadWorkspaceSession, {
      props: {
        content: '',
        parameters: '<session_id>s_42</session_id>',
      } as never,
    })
    expect(wrapper.html()).toContain('s_42')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(ReadWorkspaceSession, {
      props: {
        content: '',
        parameters: '<query>login bug</query>',
      } as never,
    })
    expect(running.find('[data-testid="read-workspace-session-running"]').exists()).toBe(true)
    const done = mount(ReadWorkspaceSession, {
      props: {
        content:
          '<read_workspace_session behavior="search"><query>login bug</query><count>0</count></read_workspace_session>',
        parameters: '<query>login bug</query>',
      } as never,
    })
    expect(done.find('[data-testid="read-workspace-session-running"]').exists()).toBe(false)
  })
})
