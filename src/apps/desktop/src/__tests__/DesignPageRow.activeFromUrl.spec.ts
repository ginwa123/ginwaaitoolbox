// src/apps/desktop/src/__tests__/DesignPageRow.activeFromUrl.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, reactive } from 'vue'
import { mount } from '@vue/test-utils'

import DesignPageRow from '../components/workspace/DesignPageRow.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const basePage = {
  id: 'page_42',
  name: 'Task Dialog',
  workspace_item_id: 'item_design',
  workspace_item_task_id: 'task_42',
  position: 0,
  created_at: '2026-01-01',
  updated_at: '2026-01-01',
  width: 1440,
  height: 1024,
}

function mountRow(overrides: { isActivePage?: boolean } = {}) {
  const wrapper = mount(DesignPageRow, {
    props: {
      page: basePage,
      workspaceId: 'ws_1',
      itemId: 'item_design',
      isActivePage: overrides.isActivePage ?? false,
    },
  })
  return { wrapper }
}

describe('DesignPageRow — page row active state from URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })
  afterEach(() => { vi.restoreAllMocks() })

  it('page row is active when URL is ?view=workspace&pageId=Z (this page)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_design', pageId: 'page_42' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_design&pageId=page_42',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const { wrapper } = mountRow()
    await nextTick()
    const row = wrapper.find('[data-page-id="page_42"]')
    expect(row.exists()).toBe(true)
    expect(row.attributes('style')).toContain('--semantic-active-bg')
  })

  it('page row is NOT active when URL is ?view=workspace&pageId=OTHER', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_design', pageId: 'page_other' },
      path: '/app',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      fullPath: '/app?view=workspace&itemId=item_design&pageId=page_other',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const { wrapper } = mountRow()
    await nextTick()
    const row = wrapper.find('[data-page-id="page_42"]')
    expect(row.exists()).toBe(true)
    expect(row.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('page row is NOT active when URL is ?view=chat', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_xyz' },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      path: '/app',
      fullPath: '/app?view=chat&session=chat_xyz',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const { wrapper } = mountRow()
    await nextTick()
    const row = wrapper.find('[data-page-id="page_42"]')
    expect(row.exists()).toBe(true)
    expect(row.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('page row active state reacts to URL changes mid-mount', async () => {
    const route = reactive({
      query: {} as Record<string, string>,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      path: '/app',
      fullPath: '/app',
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue(route as any)
    const { wrapper } = mountRow()
    await nextTick()
    let row = wrapper.find('[data-page-id="page_42"]')
    expect(row.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    route.query = { view: 'workspace', itemId: 'item_design', pageId: 'page_42' }
    await nextTick()
    row = wrapper.find('[data-page-id="page_42"]')
    expect(row.attributes('style')).toContain('--semantic-active-bg')
  })
})
