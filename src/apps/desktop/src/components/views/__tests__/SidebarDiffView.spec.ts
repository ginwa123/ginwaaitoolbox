import { describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import SidebarDiffView from '../chat_right_sidebar/SidebarDiffView.vue'
import type { ParsedDiffLine } from '../chat_right_sidebar/parseUnifiedDiff'

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual }
})

const LINES: ParsedDiffLine[] = [
  { type: 'hunk', content: '@@ -1,2 +1,2 @@', lineIndex: 0 },
  { type: 'context', content: 'keep', oldLineNum: 1, newLineNum: 1, lineIndex: 1 },
  { type: 'remove', content: 'old', oldLineNum: 2, lineIndex: 2 },
  { type: 'add', content: 'new', newLineNum: 2, lineIndex: 3 },
]

function mountView(extra: Record<string, unknown> = {}) {
  return mount(SidebarDiffView, {
    props: {
      path: 'dirty.txt',
      lines: LINES,
      added: 1,
      removed: 1,
      staged: false,
      loading: false,
      error: null,
      cwd: '/repo',
      showBack: true,
      backLabel: 'Back to chat',
      ...extra,
    },
  })
}

describe('SidebarDiffView', () => {
  it('renders header with path, stats and back button', () => {
    const wrapper = mountView()
    expect(wrapper.get('[data-testid="sidebar-diff-selected"]').text()).toBe('dirty.txt')
    expect(wrapper.get('[data-testid="sidebar-diff-back"]').text()).toContain('Back to chat')
    expect(wrapper.text()).toContain('+1')
    expect(wrapper.text()).toContain('-1')
  })

  it('hides the back button when showBack is false', () => {
    const wrapper = mountView({ showBack: false })
    expect(wrapper.find('[data-testid="sidebar-diff-back"]').exists()).toBe(false)
  })

  it('emits back on back click', async () => {
    const wrapper = mountView()
    await wrapper.get('[data-testid="sidebar-diff-back"]').trigger('click')
    expect(wrapper.emitted('back')).toHaveLength(1)
  })

  it('emits open with first added line on Open click', async () => {
    const wrapper = mountView()
    await wrapper.get('[data-testid="sidebar-diff-open-file"]').trigger('click')
    expect(wrapper.emitted('open')).toEqual([[{ path: 'dirty.txt', line: 2 }]])
  })

  it('shows loading and error states', () => {
    expect(mountView({ loading: true }).text()).not.toContain('No changes')
    const err = mountView({ lines: [], error: 'boom' })
    expect(err.text()).toContain('boom')
  })

  it('emits retry on retry click', async () => {
    const err = mountView({ lines: [], error: 'boom' })
    await err.get('[data-testid="sidebar-diff-retry"]').trigger('click')
    expect(err.emitted('retry')).toHaveLength(1)
  })

  it('opens mini-chat on diff row click and submits review', async () => {
    const wrapper = mountView()
    const rows = wrapper.findAll('tr.diff-line, tr')
    expect(rows.length).toBeGreaterThan(0)
    // Click the first added row (has cursor pointer + click handler).
    const addRow = wrapper.findAll('tr').find((r) => r.text().includes('new'))
    expect(addRow?.exists()).toBe(true)
    await addRow!.trigger('click')
    await flushPromises()
    expect(wrapper.emitted('submit-review')).toBeUndefined()
    // Mini-chat popup appears with a FileInput; submit via its emit.
    const fileInput = wrapper.findComponent({ name: 'FileInput' })
    expect(fileInput.exists()).toBe(true)
    await fileInput.vm.$emit('submit', 'looks good')
    const submitted = wrapper.emitted('submit-review')
    expect(submitted).toHaveLength(1)
    expect(String(submitted![0]![0])).toContain('looks good')
    expect(String(submitted![0]![0])).toContain('dirty.txt')
  })
})
