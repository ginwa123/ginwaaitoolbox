/**
 * Regression tests for the "active state leaks across Chats ↔ workspace
 * item" bug. Selecting a chat must clear `activeWorkspaceItemId` in the
 * workspaces store, and vice versa. Before the fix these tests fail.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'

import * as api from '../api'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import ChatsList from '../components/ChatsList.vue'
import { mount } from '@vue/test-utils'
import { makeLocalStorageStub } from './helpers'

// ChatsList calls useRouter() in setup; the `mocks: { $router: ... }`
// option below only patches `this.$router` (Options API), so we must
// stub the composable at module level. The $router global is still
// provided for completeness.
vi.mock('vue-router', () => ({
  useRouter: () => ({ replace: vi.fn() }),
  useRoute: () => ({}),
}))

function mountChatsList() {
  return mount(ChatsList, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      // Real Vue ref — ChatsList has `watch(processingState, ..., { deep: true })`
      // (lines 110-119 and 367-372). A plain `{ value: {} }` object logs
      // `[Vue warn]: Invalid watch source` and turns the watchers into silent
      // no-ops, hiding reactivity regressions.
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

describe('sidebar active-state exclusivity', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('clicking a chat row clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_42')
    expect(ws.activeWorkspaceItemId).toBe('item_42')

    const nav = useNavigationStore()
    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push fake item into the local navItems ref
    wrapper.vm.navItems = [
      { id: 'chat_abc', name: 'My Chat', active: false, processing: false },
    ]
    // @ts-expect-error: invoke internal method
    await wrapper.vm.setActive('chat_abc')

    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('createChat clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_99')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: invoke internal method
    wrapper.vm.createChat()

    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('removing the active chat clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_77')
    const nav = useNavigationStore()
    nav.setActiveChat('chat_del', 'Doomed Chat')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push a fake active chat
    wrapper.vm.navItems = [
      { id: 'chat_del', name: 'Doomed Chat', active: true, processing: false },
    ]
    vi.spyOn(api, 'deleteChat').mockResolvedValue({ success: true })
    await wrapper.vm.removeChat('chat_del')

    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('removing a non-active chat does NOT clear activeWorkspaceItemId', async () => {
    // Guards the `if (wasActive)` reset in removeChat: deleting an
    // inactive chat must not disturb the workspace-item selection.
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_keep')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push a fake navItems with a different ACTIVE chat
    wrapper.vm.navItems = [
      { id: 'chat_active', name: 'Active', active: true, processing: false },
      { id: 'chat_doomed', name: 'Doomed', active: false, processing: false },
    ]
    vi.spyOn(api, 'deleteChat').mockResolvedValue({ success: true })
    // No @ts-expect-error needed here: `removeChat` is exposed via
    // ChatsList.vue's `defineExpose({ ...removeChat, ... })`. Compare with
    // the first test, which DOES need it for `setActive` (closure-only,
    // not exposed). The asymmetry reflects `defineExpose` membership.
    await wrapper.vm.removeChat('chat_doomed')

    expect(ws.activeWorkspaceItemId).toBe('item_keep')
  })
})
