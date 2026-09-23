/**
 * Conflict-only PR UI for SidebarDiffPanel (quiet-when-clean).
 *
 * Contract: CONFLICTING/DIRTY shows the red "Merge conflicts" badge plus
 * the "This branch has conflicts that must be resolved" banner with a
 * Resolve link to <pr-url>/conflicts. MERGEABLE/CLEAN, UNKNOWN, and empty
 * mergeable render exactly as before (no badge, no banner).
 */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffPanel from '../chat_right_sidebar/SidebarDiffPanel.vue'
import { createRouter, createMemoryHistory } from 'vue-router'

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
+new`

function prStatusPayload(overrides: Record<string, string> = {}) {
  return {
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
    changed_files: 1,
    ...overrides,
  }
}

function mountPrPanel() {
  return mount(SidebarDiffPanel, {
    global: { plugins: [testRouter] },
    props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42', prProvider: 'github' },
  })
}

describe('SidebarDiffPanel PR conflict UI', () => {
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
    getPrStatusMock.mockResolvedValue(prStatusPayload())
  })

  it('shows the conflict badge and banner when mergeable is CONFLICTING', async () => {
    getPrStatusMock.mockResolvedValue(
      prStatusPayload({ mergeable: 'CONFLICTING', merge_state: 'DIRTY' }),
    )
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.get('[data-testid="sidebar-pr-conflict-badge"]').text()).toContain(
      'Merge conflicts',
    )
    const notice = wrapper.get('[data-testid="sidebar-pr-conflict-notice"]')
    expect(notice.text()).toContain('This branch has conflicts that must be resolved')
    expect(notice.find('a').attributes('href')).toBe(
      'https://github.com/acme/app/pull/42/conflicts',
    )
    // The Open badge stays alongside the conflict badge.
    expect(wrapper.get('[data-testid="sidebar-pr-status"]').text()).toBe('Open')
  })

  it('shows the conflict UI when only merge_state is DIRTY', async () => {
    getPrStatusMock.mockResolvedValue(prStatusPayload({ mergeable: '', merge_state: 'DIRTY' }))
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-badge"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-notice"]').exists()).toBe(true)
  })

  it('stays quiet (no badge, no banner) when the PR is mergeable', async () => {
    getPrStatusMock.mockResolvedValue(
      prStatusPayload({ mergeable: 'MERGEABLE', merge_state: 'CLEAN' }),
    )
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-badge"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-notice"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="sidebar-pr-status"]').text()).toBe('Open')
  })

  it('stays quiet when mergeable is unknown (today behavior)', async () => {
    getPrStatusMock.mockResolvedValue(prStatusPayload({ mergeable: '', merge_state: '' }))
    const wrapper = mountPrPanel()
    await flushPromises()
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-badge"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="sidebar-pr-conflict-notice"]').exists()).toBe(false)
  })
})
