import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { ApiError } from '../../../api'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const { getGitChangesMock, getPrDiffMock, getPrStatusMock, stageGitFilesMock } = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getPrDiffMock: vi.fn(),
  getPrStatusMock: vi.fn(),
  stageGitFilesMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFileDiff: vi.fn(),
    getGitFolderDiffs: vi.fn(async () => ({ diffs: [] })),
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
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
    clearFolderDiffCache()
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
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      title: 'Test',
      pr_url: 'https://github.com/acme/app/pull/42',
      number: 42,
      mergeable: '',
      merge_state: '',
      head_ref: 'feature',
      base_ref: 'main',
      author: 'acme',
      created_at: '',
      updated_at: '',
      merged_at: '',
      closed_at: '',
      additions: 0,
      deletions: 0,
      changed_files: 2,
    })
  })

  it('switches to PR mode when prUrl is set and lists PR files', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
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

  it('emits show-diff on PR file click without stage buttons', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-file-foo.txt"]').trigger('click')
    await flushPromises()
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({ path: 'foo.txt', staged: false, added: 1, removed: 1 })
    // Read-only: no stage/unstage buttons anywhere in PR mode.
    expect(wrapper.find('button[title="Stage file"]').exists()).toBe(false)
    expect(wrapper.find('button[title="Unstage file"]').exists()).toBe(false)
    expect(stageGitFilesMock).not.toHaveBeenCalled()
    // Panel is list-only: no inline diff section rendered.
    expect(wrapper.find('[data-testid="sidebar-diff-selected"]').exists()).toBe(false)
  })

  it('shows retry on PR diff failure', async () => {
    getPrDiffMock.mockRejectedValueOnce(new Error('nope'))
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-retry"]').exists()).toBe(true)
  })

  it('stays in worktree mode when prUrl is empty', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: '' },
    })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledWith('/repo')
    expect(getPrDiffMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="sidebar-pr-link"]').exists()).toBe(false)
  })

  it('shows Merged badge and notice when PR is merged', async () => {
    getPrStatusMock.mockResolvedValueOnce({
      status: 'merged',
      state: 'MERGED',
      title: 'Test',
      pr_url: 'https://github.com/acme/app/pull/42',
      number: 42,
      mergeable: '',
      merge_state: '',
      head_ref: 'feature',
      base_ref: 'main',
      author: 'acme',
      created_at: '',
      updated_at: '',
      merged_at: '',
      closed_at: '',
      additions: 0,
      deletions: 0,
      changed_files: 2,
    })
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42', prProvider: 'github' },
    })
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-pr-status"]').text()).toBe('Merged')
    expect(wrapper.find('[data-testid="sidebar-pr-merged-notice"]').exists()).toBe(true)
  })

  it('renders the server error body on PR diff failure instead of a generic string', async () => {
    getPrDiffMock.mockRejectedValueOnce(
      new ApiError(
        502,
        'Bad Gateway',
        JSON.stringify({ error: 'failed to fetch PR diff: gh: HTTP 401: Bad credentials' }),
      ),
    )
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    const err = wrapper.get('[data-testid="sidebar-pr-error"]')
    expect(err.text()).toContain('HTTP 401')
    expect(err.text()).not.toBe('Failed to load PR diff')
  })

  it('shows the server status error inline when PR status fetch fails', async () => {
    getPrStatusMock.mockRejectedValueOnce(
      new ApiError(
        502,
        'Bad Gateway',
        JSON.stringify({
          error: 'failed to fetch PR status: gh: To authenticate, run: gh auth login',
        }),
      ),
    )
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42' },
    })
    await flushPromises()
    // Badge hidden (unknown state) but the real cause is visible inline.
    expect(wrapper.find('[data-testid="sidebar-pr-status"]').exists()).toBe(false)
    const statusErr = wrapper.get('[data-testid="sidebar-pr-status-error"]')
    expect(statusErr.text()).toContain('gh auth login')
  })
})
