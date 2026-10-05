/**
 * Folder-mode batch diff (server-lag fix): worktree mode prefers ONE
 * POST /git/file/diffs with `folder: ""` — the server enumerates the changed
 * paths itself — over N parallel GET /git/file/diff. The per-file fallback
 * exists only for a pre-batch server, so it must be BOUNDED and it must LOG;
 * an unbounded silent fallback is what produced 1009 diff requests a session.
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
  getGitFolderDiffsMock,
  getPrDiffMock,
  getPrStatusMock,
} = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  getGitFileDiffMock: vi.fn(),
  getGitFileDiffsMock: vi.fn(),
  getGitFolderDiffsMock: vi.fn(),
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
    getGitFolderDiffs: getGitFolderDiffsMock,
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

// What the SERVER returns for folder mode: every changed path, staged side
// first for anything both-staged-and-modified, regardless of what the client
// asked for — the client named a folder, not a file list.
const FOLDER_RESULT = {
  diffs: [
    { path: 'staged.txt', diff_content: diffFor('staged.txt'), staged: true },
    { path: 'dirty.txt', diff_content: diffFor('dirty.txt'), staged: false },
    { path: 'new.txt', diff_content: diffFor('new.txt'), staged: false },
  ],
}

const mountPanel = () =>
  mount(SidebarDiffPanel, {
    global: { plugins: [testRouter] },
    props: { cwd: '/repo' },
  })

describe('SidebarDiffPanel folder diff', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue(FOLDER_RESULT)
    getGitFileDiffMock.mockImplementation((cwd: string, path: string, staged: boolean) =>
      Promise.resolve({ path, diff_content: diffFor(path), staged }),
    )
  })

  it('uses ONE folder call instead of N per-file fetches', async () => {
    const wrapper = mountPanel()
    await flushPromises()
    // Whole repo, no file list — the server walks it.
    expect(getGitFolderDiffsMock).toHaveBeenCalledTimes(1)
    expect(getGitFolderDiffsMock).toHaveBeenCalledWith('/repo')
    expect(getGitFileDiffsMock).not.toHaveBeenCalled()
    expect(getGitFileDiffMock).not.toHaveBeenCalled()
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    const files = listed![0]![0] as Array<{ path: string; lines: unknown[] }>
    expect(files.map((f) => f.path)).toEqual(['staged.txt', 'dirty.txt', 'new.txt'])
    expect(files.every((f) => f.lines.length > 0)).toBe(true)
  })

  it('says so when it degrades to per-file fetches', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    getGitFolderDiffsMock.mockRejectedValue(new Error('404'))
    const wrapper = mountPanel()
    await flushPromises()
    expect(getGitFileDiffMock).toHaveBeenCalledTimes(3)
    const listed = wrapper.emitted('show-diff-list')
    expect(listed).toHaveLength(1)
    // The flood was invisible for a long time; the reason must be in the console.
    expect(warn).toHaveBeenCalled()
    expect(String(warn.mock.calls[0]![0])).toContain('folder diff failed')
    warn.mockRestore()
  })

  it('caps the degraded per-file fan-out', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {})
    const many = Array.from({ length: 60 }, (_, i) => ({
      index_status: ' ',
      worktree_status: 'M',
      path: `f${i}.txt`,
    }))
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: true,
      staged_files: [],
      modified_files: many,
      untracked_files: [],
    })
    getGitFolderDiffsMock.mockRejectedValue(new Error('404'))
    const wrapper = mountPanel()
    await flushPromises()
    // 60 changed files must NOT become 60 requests, once per 30s poll.
    expect(getGitFileDiffMock.mock.calls.length).toBeLessThan(60)
    // …and every row is still emitted, so the UI shows a degraded file rather
    // than a file that silently vanished.
    const listed = wrapper.emitted('show-diff-list')
    const files = listed![0]![0] as Array<{ path: string }>
    expect(files).toHaveLength(60)
  })
})
