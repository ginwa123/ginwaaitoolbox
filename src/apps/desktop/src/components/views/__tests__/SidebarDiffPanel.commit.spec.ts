import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const {
  getGitChangesMock,
  getGitFolderDiffsMock,
  stageGitFilesMock,
  unstageGitFilesMock,
  commitGitChangesMock,
} = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFolderDiffsMock: vi.fn(),
  stageGitFilesMock: vi.fn(),
  unstageGitFilesMock: vi.fn(),
  commitGitChangesMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    stageGitFiles: stageGitFilesMock,
    unstageGitFiles: unstageGitFilesMock,
    commitGitChanges: commitGitChangesMock,
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

const UNSTAGED_ONLY = {
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

describe('SidebarDiffPanel commit box', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: DIFF, staged: false }],
    })
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
    commitGitChangesMock.mockResolvedValue({
      success: true,
      message: 'Committed successfully',
      commit_sha: 'abc123def456abc123def456abc123def456abc12',
    })
  })

  it('renders the commit message input with a disabled Commit button when empty', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    const input = wrapper.get('[data-testid="sidebar-commit-message"]')
    expect((input.element as HTMLTextAreaElement).placeholder).toBe('Commit message…')
    const button = wrapper.get('[data-testid="sidebar-commit-button"]')
    expect(button.text()).toBe('Commit')
    // Empty message: disabled even though a file is staged.
    expect(button.attributes('disabled')).toBeDefined()
    expect(commitGitChangesMock).not.toHaveBeenCalled()
  })

  it('enables Commit once a message is typed and commits on click', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    await wrapper
      .get('[data-testid="sidebar-commit-message"]')
      .setValue('fix: tidy the sidebar')
    await flushPromises()
    const button = wrapper.get('[data-testid="sidebar-commit-button"]')
    expect(button.attributes('disabled')).toBeUndefined()
    await button.trigger('click')
    await flushPromises()
    expect(commitGitChangesMock).toHaveBeenCalledWith('/repo', 'fix: tidy the sidebar')
    // Success clears the box and reloads the file list.
    expect(
      (wrapper.get('[data-testid="sidebar-commit-message"]').element as HTMLTextAreaElement)
        .value,
    ).toBe('')
    expect(getGitChangesMock.mock.calls.length).toBeGreaterThan(1)
    expect(wrapper.find('[data-testid="sidebar-commit-error"]').exists()).toBe(false)
  })

  it('stays disabled with a hint when nothing is staged', async () => {
    getGitChangesMock.mockResolvedValue(UNSTAGED_ONLY)
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-commit-message"]').setValue('wont commit')
    await flushPromises()
    expect(
      wrapper.get('[data-testid="sidebar-commit-button"]').attributes('disabled'),
    ).toBeDefined()
    expect(wrapper.get('[data-testid="sidebar-commit-hint"]').text()).toBe(
      'Stage files to enable commit',
    )
  })

  it('shows the server error text when the commit fails', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const { ApiError } = await import('../../../api')
    commitGitChangesMock.mockRejectedValueOnce(
      new ApiError(
        400,
        'Bad Request',
        JSON.stringify({ error: 'nothing to commit, working tree clean' }),
      ),
    )
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-commit-message"]').setValue('stale attempt')
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-commit-button"]').trigger('click')
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-commit-error"]').text()).toContain(
      'nothing to commit, working tree clean',
    )
    // The message stays so the user can adjust and retry.
    expect(
      (wrapper.get('[data-testid="sidebar-commit-message"]').element as HTMLTextAreaElement)
        .value,
    ).toBe('stale attempt')
  })
})
