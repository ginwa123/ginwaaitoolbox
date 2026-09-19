/**
 * Batch diff (server-lag fix): worktree mode prefers POST /git/file/diffs
 * (<=2 git spawns) over N parallel GET /git/file/diff. Falls back to a
 * concurrency-limited per-file fetch when the batch route is missing.
 */
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const {
  getGitChangesMock,
  getGitFileDiffMock,
  getGitFileDiffsMock,
  getPrDiffMock,
  getPrStatusMock,
} = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFileDiffMock: vi.fn(),
  getGitFileDiffsMock: vi.fn(),
  getPrDiffMock: vi.fn(),
  getPrStatusMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFileDiff: getGitFileDiffMock,
    getGitFileDiffs: getGitFileDiffsMock,
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
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

const diffFor = (path: string) =>
  `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n-old\n+new`

describe('SidebarDiffPanel batch diff', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFileDiffsMock.mockImplementation(
      (cwd: string, files: { file: string; staged: boolean }[]) =>
        Promise.resolve({
          diffs: files.map((f) => ({
            path: f.file,
            diff_content: diffFor(f.file),
            staged: f.staged,
          })),
        }),
    )
    getGitFileDiffMock.mockImplementation((cwd: string, path: string, staged: boolean) =>
      Promise.resolve({ path, diff_content: diffFor(path), staged }),
    )
  })

  it('uses one batch call instead of N per-file fetches', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    expect(getGitFileDiffsMock).toHaveBeenCalledTimes(1)
    expect(getGitFileDiffsMock).toHaveBeenCalledWith('/repo', [
      { file: 'staged.txt', staged: true },
      { file: 'dirty.txt', staged: false },
      { file: 'new.txt', staged: false },
    ])
    expect(getGitFileDiffMock).not.toHaveBeenCalled()
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    const files = listed![0]![0] as Array<{ path: string; lines: unknown[] }>
    expect(files.map((f) => f.path)).toEqual(['staged.txt', 'dirty.txt', 'new.txt'])
  })

  it('falls back to per-file fetch when the batch route is missing', async () => {
    getGitFileDiffsMock.mockRejectedValue(new Error('404'))
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    expect(getGitFileDiffsMock).toHaveBeenCalledTimes(1)
    expect(getGitFileDiffMock).toHaveBeenCalledTimes(3)
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
  })
})
