import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount } from '@vue/test-utils'
import DesignPageRow from '../components/workspace/DesignPageRow.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
    useRoute: () => ({ query: {}, path: '/', fullPath: '/' }),
  }
})

const page = {
  id: 'page_1',
  workspace_item_id: 'item_7',
  name: 'Landing hero',
  workspace_item_task_id: 'task_3',
  width: 800,
  height: 600,
  position: 0,
}

describe('DesignPageRow — right-click context menu', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  it('right-click opens menu with Open in new tab, click emits openDesignPageInBackground', async () => {
    const wrapper = mount(DesignPageRow, {
      attachTo: document.body,
      props: { page: page as never, workspaceId: 'ws_1', itemId: 'item_7', isActivePage: false },
    })
    await nextTick()
    const row = wrapper.find('[data-testid="design-page-row-page_1"]')
    expect(row.exists()).toBe(true)
    await row.trigger('contextmenu', { clientX: 80, clientY: 90 })
    await nextTick()
    const item = document.body.querySelector(
      '[data-testid="open-new-tab-item"]',
    ) as HTMLButtonElement
    expect(item).toBeTruthy()
    expect(item?.textContent).toContain('Open in new tab')
    item.click()
    await nextTick()
    expect(wrapper.emitted('openDesignPageInBackground')).toHaveLength(1)
    expect(wrapper.emitted('openDesignPageInBackground')?.[0]).toEqual([page])
    expect(wrapper.emitted('selectPage')).toBeUndefined()
    wrapper.unmount()
  })

  it('middle-click opens in background without selecting', async () => {
    const wrapper = mount(DesignPageRow, {
      attachTo: document.body,
      props: { page: page as never, workspaceId: 'ws_1', itemId: 'item_7', isActivePage: false },
    })
    await nextTick()
    const row = wrapper.find('[data-testid="design-page-row-page_1"]')
    await row.trigger('auxclick', { button: 1 })
    await nextTick()
    expect(wrapper.emitted('openDesignPageInBackground')).toHaveLength(1)
    expect(wrapper.emitted('selectPage')).toBeUndefined()
    wrapper.unmount()
  })
})
