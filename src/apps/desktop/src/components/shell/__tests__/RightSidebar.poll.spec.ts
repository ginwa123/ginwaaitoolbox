import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import RightSidebar from '../RightSidebar.vue'

const { getGitChangesMock } = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
  }
})

describe('RightSidebar git poll', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('polls git status every 30s and stops on unmount', async () => {
    const wrapper = mount(RightSidebar, {
      props: { cwd: '/repo' },
      global: { stubs: { FolderExplorer: true, RightSideBarSkillList: true } },
    })
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(30000)
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledTimes(2)
    wrapper.unmount()
    await vi.advanceTimersByTimeAsync(60000)
    await flushPromises()
    expect(getGitChangesMock).toHaveBeenCalledTimes(2)
  })
})
