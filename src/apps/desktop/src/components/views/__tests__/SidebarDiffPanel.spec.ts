import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'

const { getGitChangesMock, getGitFileDiffMock, stageGitFilesMock, unstageGitFilesMock } =
  vi.hoisted(() => ({
    getGitChangesMock: vi.fn(),
    getGitFileDiffMock: vi.fn(),
    stageGitFilesMock: vi.fn(),
    unstageGitFilesMock: vi.fn(),
  }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFileDiff: getGitFileDiffMock,
    stageGitFiles: stageGitFilesMock,
    unstageGitFiles: unstageGitFilesMock,
  }
})

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [{ index_status: 'M', worktree_status: ' ', path: 'staged.txt' }],
  modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'dirty.txt' }],
  untracked_files: [{ index_status: '??', worktree_status: '??', path: 'new.txt' }],
}

const DIFF = `diff --git a/dirty.txt b/dirty.txt
--- a/dirty.txt
+++ b/dirty.txt
@@ -1,2 +1,2 @@
 keep
-old
+new`

describe('SidebarDiffPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFileDiffMock.mockResolvedValue({ path: 'dirty.txt', diff_content: DIFF, staged: false })
    stageGitFilesMock.mockResolvedValue({
      success: true,
      message: '',
      staged_files: [],
      failed_files: [],
    })
    unstageGitFilesMock.mockResolvedValue({
      success: true,
      message: '',
      staged_files: [],
      failed_files: [],
    })
  })

  it('renders file groups with counts', async () => {
    const wrapper = mount(SidebarDiffPanel, { props: { cwd: '/repo' } })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledWith('/repo')
    expect(wrapper.text()).toContain('Staged Changes (1)')
    expect(wrapper.text()).toContain('Changes (1)')
    expect(wrapper.text()).toContain('Untracked (1)')
    expect(wrapper.get('[data-testid="sidebar-diff-count"]').text()).toBe('3')
  })

  it('loads inline diff on file click', async () => {
    const wrapper = mount(SidebarDiffPanel, { props: { cwd: '/repo' } })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    expect(getGitFileDiffMock).toHaveBeenCalledWith('/repo', 'dirty.txt', false)
    expect(wrapper.get('[data-testid="sidebar-diff-selected"]').text()).toBe('dirty.txt')
  })

  it('shows retry on list failure', async () => {
    getGitChangesMock.mockRejectedValueOnce(new Error('boom'))
    const wrapper = mount(SidebarDiffPanel, { props: { cwd: '/repo' } })
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-diff-retry"]').exists()).toBe(true)
  })

  it('stages a file and reloads', async () => {
    const wrapper = mount(SidebarDiffPanel, { props: { cwd: '/repo' } })
    await flushPromises()
    const row = wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
    await row.get('button[title="Stage file"]').trigger('click')
    await flushPromises()
    expect(stageGitFilesMock).toHaveBeenCalledWith('/repo', ['dirty.txt'])
  })
})
