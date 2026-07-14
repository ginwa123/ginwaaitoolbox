/**
 * Tests for WorkspaceItemMemoriesView.vue. Covers the 4 rendering states
 * (empty cwd, empty list, populated list, header subtitle) and asserts
 * that the API is not called when cwd is falsy.
 *
 * Mocks the api module so no network calls happen. Mirrors the
 * MemoryList.spec.ts pattern (vi.mock + setActivePinia).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import WorkspaceItemMemoriesView from '../components/WorkspaceItemMemoriesView.vue'

// Mock the api module so no network calls happen.
// Spread `...actual` so non-mocked functions (e.g. types) remain real.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listLocalMemories: vi.fn(),
    getLocalMemoryDetail: vi.fn(),
    createLocalMemory: vi.fn(),
    updateLocalMemory: vi.fn(),
    deleteLocalMemory: vi.fn(),
  }
})

import { listLocalMemories } from '../api'
const mockList = listLocalMemories as unknown as ReturnType<typeof vi.fn>

describe('WorkspaceItemMemoriesView', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    mockList.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders empty state when no memories exist for cwd', async () => {
    mockList.mockResolvedValue({ memories: [] })
    const w = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '/tmp/proj', itemName: 'My Project' },
      attachTo: document.body,
    })
    wrapper = w
    await flushPromises()
    expect(document.body.textContent).toContain('No memories yet')
    expect(document.body.textContent).toContain('My Project')
  })

  it('renders list of memories after fetch', async () => {
    mockList.mockResolvedValue({
      memories: [
        { name: 'rule-a.md', title: 'Rule A', path: '/tmp/proj/.nalar/memories/rule-a.md', size: 256 },
        { name: 'rule-b.md', title: 'Rule B', path: '/tmp/proj/.nalar/memories/rule-b.md', size: 1024 },
      ],
    })
    const w = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '/tmp/proj' },
      attachTo: document.body,
    })
    wrapper = w
    await flushPromises()
    expect(document.body.textContent).toContain('Rule A')
    expect(document.body.textContent).toContain('Rule B')
  })

  it('shows the cwd in the header subtitle', async () => {
    mockList.mockResolvedValue({ memories: [] })
    const w = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '/home/u/proj' },
      attachTo: document.body,
    })
    wrapper = w
    await flushPromises()
    expect(document.body.textContent).toContain('/home/u/proj')
    expect(document.body.textContent).toContain('.nalar/memories')
  })

  it('does not call API when cwd is empty', async () => {
    const w = mount(WorkspaceItemMemoriesView, {
      props: { cwd: '' },
      attachTo: document.body,
    })
    wrapper = w
    await flushPromises()
    expect(mockList).not.toHaveBeenCalled()
    expect(document.body.textContent).toContain('No path')
  })
})