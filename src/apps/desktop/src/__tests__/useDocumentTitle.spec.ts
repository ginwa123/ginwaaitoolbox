import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { defineComponent, h, nextTick } from 'vue'
import { mount } from '@vue/test-utils'
import { useNavigationStore } from '../stores/navigation'
import { useDocumentTitle } from '../composables/useDocumentTitle'
import { makeLocalStorageStub } from './helpers'

const routeQuery: Record<string, string> = {}

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: () => ({ query: routeQuery, path: '/app', fullPath: '/app' }),
    useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
  }
})

function mountTitleSync() {
  const Host = defineComponent({
    setup() {
      useDocumentTitle()
      return () => h('div')
    },
  })
  return mount(Host)
}

describe('useDocumentTitle — browser tab follows session name', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.title = 'Pabrik'
    for (const k of Object.keys(routeQuery)) delete routeQuery[k]
  })

  it('shows the active chat name while a session is open', async () => {
    routeQuery.view = 'chat'
    routeQuery.session = 'chat_1'
    const navigationStore = useNavigationStore()
    navigationStore.setActiveChat('chat_1', 'agent tool present files')
    const wrapper = mountTitleSync()
    await nextTick()
    expect(document.title).toBe('agent tool present files - Pabrik')
    wrapper.unmount()
  })

  it('falls back to plain Pabrik with no active view', async () => {
    const wrapper = mountTitleSync()
    await nextTick()
    expect(document.title).toBe('Pabrik')
    wrapper.unmount()
  })
})
