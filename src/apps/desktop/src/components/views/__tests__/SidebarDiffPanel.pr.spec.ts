import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'

const { getGitChangesMock, getPrDiffMock, stageGitFilesMock } = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getPrDiffMock: vi.fn(),
  stageGitFilesMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFileDiff: vi.fn(),
    getPrDiff: getPrDiffMock,
    stageGitFiles: stageGitFilesMock,
    unstageGitFiles: vi.fn(),
  }
})

const PR_DIFF = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1 +1 @@
-old
+new
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..abc1234
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello`

describe('SidebarDiffPanel PR mode', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
    getPrDiffMock.mockResolvedValue({
      pr_url: 'https://github.com/acme/app/pull/42',
      base: 'main',
      head: 'feature',
      diff_content: PR_DIFF,
      truncated: false,
    })
  })

  it('switches to PR mode when prUrl is set and lists PR files', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42', prProvider: 'github' },
    })
    await flushPromises()
    expect(getPrDiffMock).toHaveBeenCalledWith('/repo', 'https://github.com/acme/app/pull/42', {
      provider: 'github',
    })
    expect(getGitChangesMock).not.toHaveBeenCalled()
    expect(wrapper.get('[data-testid="sidebar-pr-link"]').text()).toBe('#42')
    expect(wrapper.get('[data-testid="sidebar-pr-count"]').text()).toBe('2')
    expect(wrapper.text()).toContain('PR files (2)')
  })

  it('loads inline diff on PR file click without stage buttons', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-file-foo.txt"]').trigger('click')
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-diff-selected"]').text()).toBe('foo.txt')
    // Read-only: no stage/unstage buttons anywhere in PR mode.
    expect(wrapper.find('button[title="Stage file"]').exists()).toBe(false)
    expect(wrapper.find('button[title="Unstage file"]').exists()).toBe(false)
    expect(stageGitFilesMock).not.toHaveBeenCalled()
  })

  it('shows retry on PR diff failure', async () => {
    getPrDiffMock.mockRejectedValueOnce(new Error('nope'))
    const wrapper = mount(SidebarDiffPanel, {
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-retry"]').exists()).toBe(true)
  })

  it('stays in worktree mode when prUrl is empty', async () => {
    const wrapper = mount(SidebarDiffPanel, { props: { cwd: '/repo', prUrl: '' } })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledWith('/repo')
    expect(getPrDiffMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="sidebar-pr-link"]').exists()).toBe(false)
  })
})
