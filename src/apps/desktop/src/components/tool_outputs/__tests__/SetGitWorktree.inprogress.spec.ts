import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import SetGitWorktree from '../SetGitWorktree.vue'

const makeWrapper = (props: { content: string; parameters?: string }) =>
  mount(SetGitWorktree, { props: props as never })

describe('SetGitWorktree.vue — in-progress placeholder', () => {
  it('shows running badge without the error border when content empty', () => {
    const wrapper = makeWrapper({
      content: '',
      parameters: '<path>/proj/worktree-x</path><branch>worktree/x</branch>',
    })
    const html = wrapper.html()
    expect(html.toLowerCase()).toContain('running')
    expect(wrapper.find('[data-testid="tool-card-running"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="set-git-worktree"]').classes()).not.toContain('border-red-500/50')
  })

  it('renders path/branch when completed (no running badge)', () => {
    const wrapper = makeWrapper({
      content: '<set_git_worktree><path>/proj/worktree-x</path><branch>worktree/x</branch><created>true</created></set_git_worktree>',
      parameters: '<path>/proj/worktree-x</path><branch>worktree/x</branch>',
    })
    const html = wrapper.html()
    expect(html).toContain('worktree-x')
    expect(html.toLowerCase()).not.toContain('running')
    expect(wrapper.find('[data-testid="tool-card-running"]').exists()).toBe(false)
  })
})
