import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import WorkspaceItemTaskRow from '../components/workspace/WorkspaceItemTaskRow.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
    useRoute: () => ({ query: {}, path: '/', fullPath: '/' }),
  }
})

describe('WorkspaceItemTaskRow — right-click context menu', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  it('emits openTaskInBackground with row ids when the menu item clicks', async () => {
    const wrapper = mount(WorkspaceItemTaskRow, {
      attachTo: document.body,
      props: {
        task: { id: 'task_9', name: 'Fix login' },
        workspaceId: 'ws_1',
        itemId: 'item_7',
      },
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await nextTick()
    const row = wrapper.find('[data-task-row]')
    expect(row.exists()).toBe(true)
    await row.trigger('contextmenu', { clientX: 50, clientY: 60 })
    await nextTick()
    const item = document.body.querySelector(
      '[data-testid="open-new-tab-item"]',
    ) as HTMLButtonElement
    expect(item).toBeTruthy()
    item.click()
    await nextTick()
    expect(wrapper.emitted('openTaskInBackground')).toHaveLength(1)
    expect(wrapper.emitted('openTaskInBackground')?.[0]).toEqual([
      { workspaceId: 'ws_1', itemId: 'item_7', taskId: 'task_9' },
    ])
    expect(wrapper.emitted('selectTask')).toBeUndefined()
    wrapper.unmount()
  })
})
