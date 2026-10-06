import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

const { getGitChangesMock, getGitFileDiffMock, getGitFolderDiffsMock, getPrDiffMock, getPrStatusMock } = vi.hoisted(
  () => ({
    getGitChangesMock: vi.fn(),
    getGitFileDiffMock: vi.fn(),
    getGitFolderDiffsMock: vi.fn(),
    getPrDiffMock: vi.fn(),
    getPrStatusMock: vi.fn(),
  }),
)

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFileDiff: getGitFileDiffMock,
    getGitFolderDiffs: getGitFolderDiffsMock,
    getPrDiff: getPrDiffMock,
    getPrStatus: getPrStatusMock,
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

describe('SidebarDiffPanel show-diff', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: DIFF, staged: false }],
    })
    getPrDiffMock.mockResolvedValue({
      pr_url: 'https://github.com/acme/app/pull/1',
      base: 'main',
      head: 'feature',
      diff_content: DIFF,
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

  it('emits show-diff with parsed payload on worktree file-row click', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({
      path: 'dirty.txt',
      staged: false,
      added: 1,
      removed: 1,
    })
  })

  it('emits show-diff on PR file-row click', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/1' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-file-dirty.txt"]').trigger('click')
    await flushPromises()
    const emitted = wrapper.emitted('show-diff')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toMatchObject({ path: 'dirty.txt', staged: false })
  })
})

describe('SidebarDiffPanel file context menu', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFolderDiffsMock.mockResolvedValue({
      diffs: [{ path: 'dirty.txt', diff_content: DIFF, staged: false }],
    })
  })

  it('right-click shows the file menu; item opens code-editor URL in new tab', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    try {
      const wrapper = mount(SidebarDiffPanel, {
        props: { cwd: '/repo' },
        global: { plugins: [testRouter] },
      })
      await flushPromises()
      await wrapper
        .get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
        .trigger('contextmenu')
      const menu = document.body.querySelector('[data-testid="open-new-tab-menu"]')
      expect(menu).not.toBeNull()
      const item = document.body.querySelector(
        '[data-testid="open-file-new-tab-item"]',
      ) as HTMLButtonElement
      expect(item).not.toBeNull()
      item.click()
      await flushPromises()
      expect(openSpy).toHaveBeenCalledTimes(1)
      const href = String(openSpy.mock.calls[0]?.[0] ?? '')
      expect(href).toContain('view=code-editor')
      // Readable link: plain relative path, no base64, no cwd leak.
      expect(href).toContain('file=dirty.txt')
      expect(href).not.toContain('cwd=')
      // Menu action does not navigate inline (no open-file emit).
      expect(wrapper.emitted('show-diff')).toBeUndefined()
    } finally {
      openSpy.mockRestore()
    }
  })

  it('ctrl+click opens new tab without inline navigation', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    try {
      const wrapper = mount(SidebarDiffPanel, {
        props: { cwd: '/repo' },
        global: { plugins: [testRouter] },
      })
      await flushPromises()
      await wrapper
        .get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
        .trigger('click', { ctrlKey: true })
      expect(openSpy).toHaveBeenCalledTimes(1)
      expect(wrapper.emitted('show-diff')).toBeUndefined()
    } finally {
      openSpy.mockRestore()
    }
  })
})
