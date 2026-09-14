import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import ChatRightSidebar from '../chat_right_sidebar/ChatRightSidebar.vue'

const { getGitChangesMock } = vi.hoisted(() => ({ getGitChangesMock: vi.fn() }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFileDiff: vi.fn().mockResolvedValue({ path: '', diff_content: '', staged: false }),
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

describe('ChatRightSidebar', () => {
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
  })

  it('renders nothing when closed', () => {
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: false, width: 300 },
    })
    expect(wrapper.find('[data-testid="chat-right-sidebar"]').exists()).toBe(false)
  })

  it('renders panel with width when open', async () => {
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: true, width: 320 },
    })
    await flushPromises()
    const aside = wrapper.get('[data-testid="chat-right-sidebar"]')
    expect(aside.attributes('style')).toContain('320px')
    expect(wrapper.find('[data-testid="sidebar-diff-panel"]').exists()).toBe(true)
  })

  it('emits close on ✕ click', async () => {
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: true, width: 300 },
    })
    await flushPromises()
    await wrapper.get('[data-testid="chat-right-sidebar-close"]').trigger('click')
    expect(wrapper.emitted('update:open')).toEqual([[false]])
  })
})
