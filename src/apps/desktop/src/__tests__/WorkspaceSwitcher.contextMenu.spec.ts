import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount } from '@vue/test-utils'
import WorkspaceSwitcher from '../components/workspace/WorkspaceSwitcher.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
    useRoute: () => ({ query: {}, path: '/', fullPath: '/' }),
  }
})

const workspaces = [
  { id: 'ws_1', name: 'upload tools', items: [] },
  { id: 'ws_2', name: 'landing page', items: [] },
]

describe('WorkspaceSwitcher — right-click context menu', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  async function mountOpen() {
    const wrapper = mount(WorkspaceSwitcher, {
      attachTo: document.body,
      props: { workspaces: workspaces as never, activeWorkspaceId: 'ws_1' },
    })
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await nextTick()
    return wrapper
  }

  it('right-click opens menu with Open in new tab, click emits openWorkspaceInBackground', async () => {
    const wrapper = await mountOpen()
    const option = wrapper.find('[data-testid="workspace-switcher-option-ws_2"]')
    expect(option.exists()).toBe(true)
    await option.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const item = document.body.querySelector(
      '[data-testid="open-new-tab-item"]',
    ) as HTMLButtonElement
    expect(item).toBeTruthy()
    expect(item?.textContent).toContain('Open in new tab')
    item.click()
    await nextTick()
    expect(wrapper.emitted('openWorkspaceInBackground')).toHaveLength(1)
    expect(wrapper.emitted('openWorkspaceInBackground')?.[0]).toEqual(['ws_2'])
    expect(wrapper.emitted('select')).toBeUndefined()
    wrapper.unmount()
  })

  it('middle-click opens in background without navigating', async () => {
    const wrapper = await mountOpen()
    const option = wrapper.find('[data-testid="workspace-switcher-option-ws_2"]')
    await option.trigger('auxclick', { button: 1 })
    await nextTick()
    expect(wrapper.emitted('openWorkspaceInBackground')?.[0]).toEqual(['ws_2'])
    expect(wrapper.emitted('select')).toBeUndefined()
    wrapper.unmount()
  })

  it('ctrl+click opens in background without navigating', async () => {
    const wrapper = await mountOpen()
    const option = wrapper.find('[data-testid="workspace-switcher-option-ws_2"]')
    await option.trigger('click', { ctrlKey: true })
    await nextTick()
    expect(wrapper.emitted('openWorkspaceInBackground')?.[0]).toEqual(['ws_2'])
    expect(wrapper.emitted('select')).toBeUndefined()
    wrapper.unmount()
  })
})
