import { h } from 'vue'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import SettingsShell from '../components/settings/SettingsShell.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

/**
 * SettingsShell — the one chrome for user + workspace settings.
 *
 * User scope (`/app/settings`) is Pabrik-only: the old Skills/Memories
 * sidebar entries showed the ACTIVE workspace's rows without saying so,
 * so they moved to workspace scope, bound to the route workspace.
 * The open section rides in `?section=` (repo rule: every view switch
 * syncs the browser URL); the path itself is the scope.
 */

const WS_1 = { id: 'ws_1', name: 'Acme', icon: '', items: [], expanded: false }
const WS_2 = { id: 'ws_2', name: 'Beta', icon: '', items: [], expanded: false }

async function makeRouter(path: string, query: Record<string, string> = {}): Promise<Router> {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/app/settings', component: { template: '<div />' } },
      { path: '/app/:workspaceId/settings', component: { template: '<div />' } },
    ],
  })
  await router.push({ path, query })
  await router.isReady()
  return router
}

function mountShell(router: Router, props: { scope: 'user' | 'workspace'; workspaceId: string }) {
  return mount(SettingsShell, {
    props,
    global: { plugins: [router] },
    slots: {
      default: ({ section }: { section: string }) =>
        h('div', { 'data-testid': 'slot-section' }, section),
    },
  })
}

describe('SettingsShell', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    wrapper?.unmount()
    wrapper = null
    setActivePinia(createPinia())
    useWorkspacesStore().workspaces = [WS_1, WS_2]
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('user scope shows Pabrik only — no Skills/Memories menus', async () => {
    const router = await makeRouter('/app/settings')
    wrapper = mountShell(router, { scope: 'user', workspaceId: '' })
    await flushPromises()

    expect(wrapper.find('[data-testid="settings-shell"]').attributes('data-scope')).toBe('user')
    expect(wrapper.find('[data-testid="settings-nav-pabrik"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="settings-nav-skills"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="settings-nav-memories"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="settings-scope-label"]').text()).toContain('User')
  })

  it('workspace scope shows Overview/Secrets/Skills/Memories for the route workspace', async () => {
    const router = await makeRouter('/app/ws_1/settings')
    wrapper = mountShell(router, { scope: 'workspace', workspaceId: 'ws_1' })
    await flushPromises()

    expect(wrapper.find('[data-testid="settings-shell"]').attributes('data-scope')).toBe(
      'workspace',
    )
    for (const id of ['overview', 'secrets', 'skills', 'memories']) {
      expect(wrapper.find(`[data-testid="settings-nav-${id}"]`).exists()).toBe(true)
    }
    expect(wrapper.find('[data-testid="settings-nav-overview"]').text()).toContain('Acme')
    const picker = wrapper.find<HTMLSelectElement>('[data-testid="settings-workspace-picker"]')
    expect(picker.exists()).toBe(true)
    expect(picker.element.value).toBe('ws_1')
  })

  it('restores the section from ?section= and strips the default on the way back', async () => {
    const router = await makeRouter('/app/ws_1/settings', { section: 'secrets', focus: 'x' })
    const replace = vi.spyOn(router, 'replace')
    wrapper = mountShell(router, { scope: 'workspace', workspaceId: 'ws_1' })
    await flushPromises()

    expect(wrapper.find('[data-testid="slot-section"]').text()).toBe('secrets')
    expect(wrapper.find('[data-tab-id="secrets"][data-active="true"]').exists()).toBe(true)
    expect(replace).not.toHaveBeenCalled()

    await wrapper.find('[data-tab-id="overview"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.section).toBeUndefined()
    expect(router.currentRoute.value.query.focus).toBe('x')
    expect(wrapper.find('[data-testid="slot-section"]').text()).toBe('overview')
  })

  it('scope switch navigates between /app/settings and /app/:id/settings', async () => {
    const router = await makeRouter('/app/settings')
    const push = vi.spyOn(router, 'push')
    wrapper = mountShell(router, { scope: 'user', workspaceId: '' })
    await flushPromises()

    await wrapper.find('[data-testid="settings-scope-workspace"]').trigger('click')
    await flushPromises()
    expect(push).toHaveBeenCalledWith({ path: '/app/ws_1/settings' })
  })

  it('workspace picker navigates to the picked workspace settings', async () => {
    const router = await makeRouter('/app/ws_1/settings')
    const push = vi.spyOn(router, 'push')
    wrapper = mountShell(router, { scope: 'workspace', workspaceId: 'ws_1' })
    await flushPromises()

    await wrapper.find('[data-testid="settings-workspace-picker"]').setValue('ws_2')
    await flushPromises()
    expect(push).toHaveBeenCalledWith({ path: '/app/ws_2/settings' })
  })

  it('back button goes back in history', async () => {
    const router = await makeRouter('/app/settings')
    const back = vi.spyOn(router, 'back')
    wrapper = mountShell(router, { scope: 'user', workspaceId: '' })
    await flushPromises()

    await wrapper.find('[data-testid="settings-back"]').trigger('click')
    expect(back).toHaveBeenCalled()
  })
})
