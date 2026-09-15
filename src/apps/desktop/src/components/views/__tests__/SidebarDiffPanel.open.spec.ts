import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'

const { getGitChangesMock, getGitFileDiffMock, getPrDiffMock } = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFileDiffMock: vi.fn(),
  getPrDiffMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFileDiff: getGitFileDiffMock,
    getPrDiff: getPrDiffMock,
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const CHANGES = {
  is_git_repo: true,
  branch: 'main',
  has_changes: true,
  staged_files: [],
  modified_files: [{ index_status: ' ', worktree_status: 'M', path: 'dirty.txt' }],
  untracked_files: [],
}

const DIFF = `diff --git a/dirty.txt b/dirty.txt
--- a/dirty.txt
+++ b/dirty.txt
@@ -1,2 +1,2 @@
 keep
-old
+new`

describe('SidebarDiffPanel open-file', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFileDiffMock.mockResolvedValue({ path: 'dirty.txt', diff_content: DIFF, staged: false })
    getPrDiffMock.mockResolvedValue({
      pr_url: 'https://github.com/acme/app/pull/1',
      base: 'main',
      head: 'feature',
      diff_content: DIFF,
      truncated: false,
    })
  })

  it('emits open-file with path on worktree file-row click', async () => {
    const wrapper = mount(SidebarDiffPanel, { props: { cwd: '/repo' } })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('open-file')).toEqual([[{ path: 'dirty.txt' }]])
  })

  it('header Open button emits open-file with first added line', async () => {
    const wrapper = mount(SidebarDiffPanel, { props: { cwd: '/repo' } })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-open-file"]').trigger('click')
    // First '+' line in the sample diff is newLine 2.
    expect(wrapper.emitted('open-file')).toContainEqual([{ path: 'dirty.txt', line: 2 }])
  })

  it('emits open-file on PR file-row click', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/1' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-file-dirty.txt"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('open-file')).toEqual([[{ path: 'dirty.txt' }]])
  })
})
