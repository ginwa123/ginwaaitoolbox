import { describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import GitFileViewer from '../GitFileViewer.vue'

vi.mock('../../../api', () => ({
  getGitFileDiff: vi.fn(async () => ({
    path: 'dirty.txt',
    diff_content: ['@@ -1,1 +1,1 @@', '-old line', '+new line'].join('\n'),
  })),
}))

describe('GitFileViewer', () => {
  it('has no Wrap toggle and soft-wraps diff lines by default', async () => {
    const wrapper = mount(GitFileViewer, {
      props: { cwd: '/repo', filePath: 'dirty.txt', fileName: 'dirty.txt' },
    })
    await flushPromises()
    expect(wrapper.text()).not.toContain('Wrap')
    expect(wrapper.find('button[title="Toggle word wrap"]').exists()).toBe(false)
    expect(wrapper.find('.diff-wrap').exists()).toBe(true)
  })
})
