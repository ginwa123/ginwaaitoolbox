import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

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
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('open-file')).toEqual([[{ path: 'dirty.txt' }]])
  })

  it('header Open button emits open-file with first added line', async () => {
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] }, props: { cwd: '/repo' } })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').trigger('click')
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-diff-open-file"]').trigger('click')
    // First '+' line in the sample diff is newLine 2.
    expect(wrapper.emitted('open-file')).toContainEqual([{ path: 'dirty.txt', line: 2 }])
  })

  it('emits open-file on PR file-row click', async () => {
    const wrapper = mount(SidebarDiffPanel, { global: { plugins: [testRouter] },
      props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/1' },
    })
    await flushPromises()
    await wrapper.get('[data-testid="sidebar-pr-file-dirty.txt"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('open-file')).toEqual([[{ path: 'dirty.txt' }]])
  })
})

describe('SidebarDiffPanel file context menu', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFileDiffMock.mockResolvedValue({ path: 'dirty.txt', diff_content: DIFF, staged: false })
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
      expect(href).toContain(`file=${btoa('dirty.txt')}`)
      // Menu action does not navigate inline (no open-file emit).
      expect(wrapper.emitted('open-file')).toBeUndefined()
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
      expect(wrapper.emitted('open-file')).toBeUndefined()
    } finally {
      openSpy.mockRestore()
    }
  })
})

describe('SidebarDiffPanel list collapse', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue(CHANGES)
    getGitFileDiffMock.mockResolvedValue({ path: 'dirty.txt', diff_content: DIFF, staged: false })
  })

  it('selecting a file collapses the list behind a breadcrumb; back restores', async () => {
    const wrapper = mount(SidebarDiffPanel, {
      props: { cwd: '/repo' },
      global: { plugins: [testRouter] },
    })
    await flushPromises()
    const list = wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
    expect(list.isVisible()).toBe(true)
    await list.trigger('click')
    await flushPromises()
    // List group hidden via v-show (display:none on the group container;
    // VTU isVisible does not walk ancestors, so assert the container).
    const rowEl = wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]')
    expect((rowEl.element.parentElement as HTMLElement).style.display).toBe('none')
    // Breadcrumb shown with count.
    const back = wrapper.get('[data-testid="sidebar-diff-back"]')
    expect(back.text()).toContain('All changes (1)')
    await back.trigger('click')
    expect(
      (wrapper.get('[data-testid="sidebar-diff-file-unstaged-dirty.txt"]').element.parentElement as HTMLElement)
        .style.display,
    ).not.toBe('none')
    expect(wrapper.find('[data-testid="sidebar-diff-back"]').exists()).toBe(false)
  })
})
