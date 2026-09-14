import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'

const { useRouterMock } = vi.hoisted(() => ({
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    resolve: (target: any) => ({
      href: `/app?view=${target.query.view}&session=${target.query.session}`,
    }),
  })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: () => ({ query: {}, path: '/', fullPath: '/' }) }
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(): any {
  return { close: vi.fn(), reconnect: vi.fn(), getState: () => 'connecting', onStateChange: () => () => {} }
}

describe('ChatsList — right-click context menu', () => {
  let app: VueApp
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', { value: makeLocalStorageStub(), writable: true, configurable: true })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [{ session_id: 'chat_1', session_name: 'Hello', updated_at: '2026-06-18T10:00:00Z' }],
      has_more: false,
      next_cursor: null, total: 1,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })

  it('right-click opens menu with Open chat in new tab, click opens a real browser tab', async () => {
    const openSpy = vi.spyOn(window, 'open').mockReturnValue(null)
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()
    const row = wrapper.findAll('button').find((b) => b.text().includes('Hello'))
    expect(row).toBeTruthy()
    await row!.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const menu = document.body.querySelector('[data-testid="open-new-tab-menu"]')
    expect(menu).toBeTruthy()
    const item = document.body.querySelector('[data-testid="open-new-tab-item"]') as HTMLButtonElement
    expect(item?.textContent).toContain('Open chat in new tab')
    expect(item?.querySelector('span[aria-hidden="true"]')).toBeTruthy()
    item.click()
    await nextTick()
    expect(openSpy).toHaveBeenCalledExactlyOnceWith(
      expect.stringContaining('session=chat_1'),
      '_blank',
      'noopener',
    )
    expect(document.body.querySelector('[data-testid="open-new-tab-menu"]')).toBeNull()
    wrapper.unmount()
    openSpy.mockRestore()
  })
})
