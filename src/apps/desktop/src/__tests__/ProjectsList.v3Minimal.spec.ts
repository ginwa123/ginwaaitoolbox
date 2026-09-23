/**
 * v3 minimal-flat sidebar: header shows a quiet count + search filter.
 * Typing filters projects by item name or nested task name.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'

import ProjectsList from '../components/workspace/ProjectsList.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const baseWorkspace = {
  id: 'ws_1',
  name: 'agentic coding',
  icon: 'folder',
  expanded: true,
  items: [
    {
      id: 'item_a',
      name: 'AGENTIC_KANBAN',
      item_type: 'agent',
      path: '/tmp',
      tasks: [{ id: 't1', name: 'parse-stream-chunk', is_pinned: false }],
      design_elements: [],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
    {
      id: 'item_b',
      name: 'kabelweb',
      item_type: 'agent',
      path: '/tmp',
      tasks: [],
      design_elements: [],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
  ],
}

function mountList() {
  return mount(ProjectsList, {
    props: { workspace: baseWorkspace, activeWorkspaceItemId: null },
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
      stubs: { WorkspaceItem: true },
    },
  })
}

describe('ProjectsList v3 — count + search filter', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({ query: {}, path: '/app', fullPath: '/app' } as never)
  })

  it('shows quiet project count', async () => {
    const wrapper = mountList()
    await nextTick()
    const count = wrapper.find('[data-testid="projects-count"]')
    expect(count.exists()).toBe(true)
    expect(count.text()).toBe('2')
    wrapper.unmount()
  })

  it('filters projects by name via search', async () => {
    const wrapper = mountList()
    await nextTick()
    const input = wrapper.find('[data-testid="projects-search"]')
    expect(input.exists()).toBe(true)
    await input.setValue('kabel')
    await nextTick()
    // Only kabelweb survives the filter (stubbed rows carry item id).
    expect(wrapper.html()).toContain('item_b')
    expect(wrapper.html()).not.toContain('item_a')
    wrapper.unmount()
  })

  it('shows no-results hint on empty filter', async () => {
    const wrapper = mountList()
    await nextTick()
    await wrapper.find('[data-testid="projects-search"]').setValue('zzz-nope')
    await nextTick()
    expect(wrapper.find('[data-testid="projects-no-results"]').exists()).toBe(true)
    wrapper.unmount()
  })
})
