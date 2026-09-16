import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import GitCommits from '../GitCommits.vue'

const { getGitCommitsMock, getGitCommitDetailMock, getGitCommitFileDiffMock } = vi.hoisted(() => ({
  getGitCommitsMock: vi.fn(),
  getGitCommitDetailMock: vi.fn(),
  getGitCommitFileDiffMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitCommits: getGitCommitsMock,
    getGitCommitDetail: getGitCommitDetailMock,
    getGitCommitFileDiff: getGitCommitFileDiffMock,
  }
})

const COMMITS = {
  is_git_repo: true,
  branch: 'main',
  total_count: 300,
  commits: [
    {
      sha: '3bc0e389abc123def45678901234567890123456',
      short_sha: '3bc0e389',
      author: 'Alice Example',
      email: 'alice@x.io',
      timestamp: 1700000000,
      subject: 'feat(chat): prefetch older messages',
      body: '',
    },
    {
      sha: '8723c2ffabc123def45678901234567890123456',
      short_sha: '8723c2ff',
      author: 'Bob',
      email: 'bob@x.io',
      timestamp: 1699999999,
      subject: 'adjust ci',
      body: '',
    },
  ],
}

describe('GitCommits', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getGitCommitsMock.mockResolvedValue(COMMITS)
    getGitCommitDetailMock.mockResolvedValue(null)
    getGitCommitFileDiffMock.mockResolvedValue(null)
  })

  it('renders lazygit-style rows with short sha and subject', async () => {
    const wrapper = mount(GitCommits, { props: { cwd: '/repo' } })
    await flushPromises()
    expect(getGitCommitsMock).toHaveBeenCalledWith('/repo', 100, 0)
    expect(wrapper.text()).toContain('3bc0e389')
    expect(wrapper.text()).toContain('feat(chat): prefetch older messages')
    expect(wrapper.text()).toContain('2 of 300')
  })

  it('shows empty state without cwd', async () => {
    const wrapper = mount(GitCommits, { props: {} })
    await flushPromises()
    expect(getGitCommitsMock).not.toHaveBeenCalled()
    expect(wrapper.text()).toContain('Select a workspace')
  })

  it('expands a row to load read-only detail with touched files', async () => {
    getGitCommitDetailMock.mockResolvedValue({
      ...COMMITS.commits[0],
      files: [{ status: 'M', path: 'src/main.zig' }],
    })
    const wrapper = mount(GitCommits, { props: { cwd: '/repo' } })
    await flushPromises()
    const rows = wrapper.findAll('button')
    // First button is the branch refresh; commit rows follow.
    const commitRow = rows.find((b) => b.text().includes('prefetch older'))
    expect(commitRow).toBeTruthy()
    await commitRow!.trigger('click')
    await flushPromises()
    expect(getGitCommitDetailMock).toHaveBeenCalledWith(
      '/repo',
      '3bc0e389abc123def45678901234567890123456',
    )
    expect(wrapper.text()).toContain('src/main.zig')
  })

  it('prefetches the next page near the bottom', async () => {
    const fullPage = {
      ...COMMITS,
      commits: Array.from({ length: 100 }, (_, i) => ({
        ...COMMITS.commits[0],
        sha: `sha${i}`,
        short_sha: `s${i}`,
        subject: `commit ${i}`,
      })),
    }
    getGitCommitsMock.mockResolvedValueOnce(fullPage)
    getGitCommitsMock.mockResolvedValueOnce({ ...COMMITS, commits: [], total_count: 300 })
    const wrapper = mount(GitCommits, { props: { cwd: '/repo' } })
    await flushPromises()
    const scroller = wrapper.find('.overflow-y-auto')
    expect(scroller.exists()).toBe(true)
    Object.defineProperty(scroller.element, 'scrollHeight', { value: 2000 })
    Object.defineProperty(scroller.element, 'clientHeight', { value: 500 })
    Object.defineProperty(scroller.element, 'scrollTop', { value: 1200 })
    await scroller.trigger('scroll')
    await flushPromises()
    expect(getGitCommitsMock).toHaveBeenCalledWith('/repo', 100, 100)
  })

  it('clicking a touched file expands its inline diff', async () => {
    const first = COMMITS.commits[0]!
    getGitCommitDetailMock.mockResolvedValue({
      ...first,
      files: [{ status: 'M', path: 'src/main.zig' }],
    })
    getGitCommitFileDiffMock.mockResolvedValue({
      sha: first.sha,
      path: 'src/main.zig',
      diff_content: 'diff --git a/src/main.zig b/src/main.zig\n@@ -1 +1 @@\n-old\n+new\n',
    })
    const wrapper = mount(GitCommits, { props: { cwd: '/repo' } })
    await flushPromises()
    const commitRow = wrapper.findAll('button').find((b) => b.text().includes('prefetch older'))
    await commitRow!.trigger('click')
    await flushPromises()
    const fileRow = wrapper.findAll('button').find((b) => b.text().includes('src/main.zig'))
    expect(fileRow).toBeTruthy()
    await fileRow!.trigger('click')
    await flushPromises()
    expect(getGitCommitFileDiffMock).toHaveBeenCalledWith('/repo', first.sha, 'src/main.zig')
    expect(wrapper.text()).toContain('old')
    expect(wrapper.text()).toContain('new')
  })

  it('emits commit-file-click instead of fetching when inline is off', async () => {
    const wrapper = mount(GitCommits, {
      props: { cwd: '/repo', inlineFileDiff: false },
    })
    await flushPromises()
    getGitCommitDetailMock.mockResolvedValue({
      ...COMMITS.commits[0],
      files: [{ status: 'M', path: 'src/main.zig' }],
    })
    const commitRow = wrapper.findAll('button').find((b) => b.text().includes('prefetch older'))
    await commitRow!.trigger('click')
    await flushPromises()
    const fileRow = wrapper.findAll('button').find((b) => b.text().includes('src/main.zig'))
    await fileRow!.trigger('click')
    await flushPromises()
    expect(getGitCommitFileDiffMock).not.toHaveBeenCalled()
    const emitted = wrapper.emitted('commit-file-click')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toEqual({
      commit: COMMITS.commits[0],
      file: { status: 'M', path: 'src/main.zig' },
    })
  })
})
