import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import ChatView from '../components/views/ChatView.vue'

describe('renderResponse — nalar_browser inline preview', () => {
  beforeEach(() => {
    // ChatView setup() now reads useNavigationStore() to wire the
    // sub-agent peek panel. Pinia must be active and localStorage
    // must be stubbed (navigation.ts reads it at store init).
    // See nav.spec.ts / chatViewWorktree.spec.ts for the same pattern.
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => { store[k] = String(v) },
        removeItem: (k: string) => { delete store[k] },
        clear: () => { for (const k in store) delete store[k] },
        key: () => null,
        length: 0,
      } as Storage)
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())
  })

  it('mounts ChatView without crashing (smoke test for the new renderResponse branch)', () => {
    const wrapper = mount(ChatView, {
      props: { chatId: 'session_test', chatName: 'Test' },
    })
    expect(wrapper.exists()).toBe(true)
  })
})
