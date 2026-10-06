import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const { getGitChangesMock, getGitCommitsMock, getGitCommitDetailMock, getGitCommitFileDiffMock } =
  vi.hoisted(() => ({
    getGitChangesMock: vi.fn(),
    getGitCommitsMock: vi.fn(),
    getGitCommitDetailMock: vi.fn(),
    getGitCommitFileDiffMock: vi.fn(),
  }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: vi.fn(async () => ({ diffs: [] })),
    getGitCommits: getGitCommitsMock,
    getGitCommitDetail: getGitCommitDetailMock,
    getGitCommitFileDiff: getGitCommitFileDiffMock,
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

const COMMIT = {
  sha: '3bc0e389abc123def45678901234567890123456',
  short_sha: '3bc0e389',
  author: 'Alice Example',
  email: 'alice@x.io',
  timestamp: 1700000000,
  subject: 'feat(chat): prefetch older messages',
  body: '',
}

const DIFF = `diff --git a/src/main.zig b/src/main.zig
--- a/src/main.zig
+++ b/src/main.zig
@@ -1 +1 @@
-old
+new`

const makeRouter = async () => {
  const r = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await r.push({ path: '/', query: {} })
  await r.isReady()
  return r
}

const mountOnCommits = async () => {
  const router = await makeRouter()
  const wrapper = mount(SidebarDiffPanel, {
    global: { plugins: [router] },
    props: { cwd: '/repo' },
  })
  await flushPromises()
  await wrapper.get('[data-testid="sidebar-tab-commits"]').trigger('click')
  await flushPromises()
  const commitRow = wrapper.findAll('button').find((b) => b.text().includes('prefetch older'))
  await commitRow!.trigger('click')
  await flushPromises()
  return wrapper
}

describe('SidebarDiffPanel commits file click', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
    getGitCommitsMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      total_count: 1,
      commits: [COMMIT],
    })
    getGitCommitDetailMock.mockResolvedValue({
      ...COMMIT,
      files: [{ status: 'M', path: 'src/main.zig' }],
    })
    getGitCommitFileDiffMock.mockResolvedValue({
      sha: COMMIT.sha,
      path: 'src/main.zig',
      diff_content: DIFF,
    })
  })

  it('forwards the file diff to the center column via show-diff', async () => {
    const wrapper = await mountOnCommits()
    const fileRow = wrapper.findAll('button').find((b) => b.text().includes('src/main.zig'))
    expect(fileRow).toBeTruthy()
    await fileRow!.trigger('click')
    await flushPromises()
    expect(getGitCommitFileDiffMock).toHaveBeenCalledWith('/repo', COMMIT.sha, 'src/main.zig')
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    const selection = emitted![0]![0] as {
      path: string
      staged: boolean
      lines: unknown[]
      added: number
      removed: number
    }
    expect(selection.path).toBe('src/main.zig')
    expect(selection.staged).toBe(false)
    expect(selection.added).toBe(1)
    expect(selection.removed).toBe(1)
    expect(selection.lines.length).toBeGreaterThan(0)
  })

  it('emits an error selection when the file diff fails', async () => {
    getGitCommitFileDiffMock.mockResolvedValue(null)
    const wrapper = await mountOnCommits()
    const fileRow = wrapper.findAll('button').find((b) => b.text().includes('src/main.zig'))
    await fileRow!.trigger('click')
    await flushPromises()
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({
      path: 'src/main.zig',
      error: 'Failed to load commit file diff',
    })
  })
})
