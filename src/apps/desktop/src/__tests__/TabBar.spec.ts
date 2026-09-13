import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'
import { nextTick } from 'vue'

import TabBar from '../components/shell/TabBar.vue'
import { __resetWindowIdForTests } from '../helpers/windowId'
import { useTabsStore } from '../stores/tabs'
import { makeLocalStorageStub } from './helpers'

/**
 * Task 3 of the tab-mode plan: the strip itself.
 *
 * The component owns the list (click / close / reorder / new tab) and
 * emits `navigate` so AppLayout can re-apply the URL — these tests assert
 * both halves: the store mutation AND the event, because a mutation
 * without the event would leave the URL pointing at the old tab.
 */

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  Object.defineProperty(globalThis, 'sessionStorage', {
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_tabbar' }),
    writable: true,
    configurable: true,
  })
}

describe('TabBar', () => {
  beforeEach(() => {
    installStorage()
    __resetWindowIdForTests()
    setActivePinia(createPinia())
  })

  it('renders one tab per open tab, marking only the active one', async () => {
    const store = useTabsStore()
    const home = store.tabs[0]
    const chat = store.open({ query: { view: 'chat', session: 'sa' }, title: 'Chat A' })

    const wrapper = mount(TabBar)
    const tabs = wrapper.findAll('[role="tab"]')
    expect(tabs).toHaveLength(2)
    expect(tabs[0]?.attributes('data-tab-key')).toBe('home')
    expect(tabs[1]?.attributes('data-tab-key')).toBe('chat:sa')
    expect(tabs[0]?.attributes('aria-selected')).toBe('false')
    expect(tabs[1]?.attributes('aria-selected')).toBe('true')
    expect(tabs[1]?.attributes('data-tab-active')).toBe('true')
    expect(tabs[0]?.attributes('data-tab-active')).toBe('false')
    expect(tabs[1]?.attributes('title')).toBe('Chat A')
    expect(wrapper.findAll('[data-testid="tab-active-underline"]')).toHaveLength(1)
    expect(tabs[1]?.find('[data-testid="tab-active-underline"]').exists()).toBe(true)
    expect(wrapper.find(`[data-testid="tab-item-${home?.id}"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="tab-item-${chat.id}"]`).exists()).toBe(true)
  })

  it('falls back to the kind title when a tab has no title yet', () => {
    const store = useTabsStore()
    store.open({ query: { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' } })
    const wrapper = mount(TabBar)
    const labels = wrapper.findAll('[role="tab"]').map((tab) => tab.text())
    expect(labels[1]).toContain('Workspace')
  })

  it('activates a tab on click and asks for a navigation', async () => {
    const store = useTabsStore()
    const home = store.tabs[0]
    store.open({ query: { view: 'chat', session: 'sa' } })

    const wrapper = mount(TabBar)
    await wrapper.find(`[data-testid="tab-item-${home?.id}"]`).trigger('click')
    expect(store.activeTabId).toBe(home?.id)
    expect(wrapper.emitted('navigate')).toHaveLength(1)
  })

  it('closes an inactive tab without activating it first', async () => {
    const store = useTabsStore()
    const home = store.tabs[0]
    const chat = store.open({ query: { view: 'chat', session: 'sa' } })

    const wrapper = mount(TabBar)
    await wrapper.find(`[data-testid="tab-close-${home?.id}"]`).trigger('click')

    expect(store.tabs.map((t) => t.id)).toEqual([chat.id])
    expect(store.activeTabId).toBe(chat.id)
    expect(wrapper.emitted('navigate')).toHaveLength(1)
  })

  it('never leaves the strip empty when the last tab is closed', async () => {
    const store = useTabsStore()
    const only = store.tabs[0]
    const wrapper = mount(TabBar)
    await wrapper.find(`[data-testid="tab-close-${only?.id}"]`).trigger('click')

    await nextTick()
    expect(store.tabCount).toBe(1)
    expect(wrapper.findAll('[role="tab"]')).toHaveLength(1)
    expect(wrapper.find('[role="tab"]').attributes('data-tab-key')).toBe('home')
  })

  it('closes on middle click', async () => {
    const store = useTabsStore()
    const home = store.tabs[0]
    store.open({ query: { view: 'chat', session: 'sa' } })

    const wrapper = mount(TabBar)
    await wrapper.find(`[data-testid="tab-item-${home?.id}"]`).trigger('auxclick', { button: 1 })
    expect(store.tabs.map((t) => t.key)).toEqual(['chat:sa'])
    expect(wrapper.emitted('navigate')).toHaveLength(1)

    // a left "auxclick" (some engines fire it for button 0) must not close
    await wrapper.find('[role="tab"]').trigger('auxclick', { button: 0 })
    expect(store.tabCount).toBe(1)
  })

  it('prevents autoscroll on middle mousedown', async () => {
    useTabsStore()
    const wrapper = mount(TabBar)
    const tab = wrapper.find('[role="tab"]')
    const prevented = new MouseEvent('mousedown', { button: 1, cancelable: true, bubbles: true })
    tab.element.dispatchEvent(prevented)
    expect(prevented.defaultPrevented).toBe(true)
  })

  it('opens a chats tab from the + button', async () => {
    const store = useTabsStore()
    store.open({ query: { view: 'chat', session: 'sa' } })
    const wrapper = mount(TabBar)
    await wrapper.find('[data-testid="tab-new"]').trigger('click')

    expect(store.activeTab?.key).toBe('home')
    expect(store.tabCount).toBe(2)
    expect(wrapper.emitted('navigate')).toHaveLength(1)
  })

  it('offers close / close-others / close-right in the context menu', async () => {
    const store = useTabsStore()
    const home = store.tabs[0]
    const a = store.open({ query: { view: 'chat', session: 'sa' } })
    const b = store.open({ query: { view: 'chat', session: 'sb' } })

    const wrapper = mount(TabBar)
    await wrapper.find(`[data-testid="tab-item-${a.id}"]`).trigger('contextmenu', { clientX: 10, clientY: 20 })
    expect(wrapper.find('[data-testid="tab-menu"]').exists()).toBe(true)

    await wrapper.find('[data-testid="tab-menu-close-others"]').trigger('click')
    expect(store.tabs.map((t) => t.id)).toEqual([a.id])
    expect(store.activeTabId).toBe(a.id)
    expect(wrapper.find('[data-testid="tab-menu"]').exists()).toBe(false)

    // close-to-the-right keeps everything up to the clicked tab
    const store2 = useTabsStore()
    store2.resetToHome()
    const home2 = store2.tabs[0]
    const c = store2.open({ query: { view: 'chat', session: 'sc' } })
    store2.open({ query: { view: 'chat', session: 'sd' } })
    await nextTick()
    await wrapper.find(`[data-testid="tab-item-${c.id}"]`).trigger('contextmenu', { clientX: 5, clientY: 5 })
    await wrapper.find('[data-testid="tab-menu-close-right"]').trigger('click')
    expect(store2.tabs.map((t) => t.id)).toEqual([home2?.id, c.id])

    // and the plain close item
    await wrapper.find(`[data-testid="tab-item-${c.id}"]`).trigger('contextmenu', { clientX: 5, clientY: 5 })
    await wrapper.find('[data-testid="tab-menu-close"]').trigger('click')
    expect(store2.tabs.map((t) => t.id)).toEqual([home2?.id])
    void b
  })

  it('closes the menu on Escape and on an outside click', async () => {
    useTabsStore()
    const wrapper = mount(TabBar)
    await wrapper.find('[role="tab"]').trigger('contextmenu', { clientX: 1, clientY: 1 })
    expect(wrapper.find('[data-testid="tab-menu"]').exists()).toBe(true)
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()
    expect(wrapper.find('[data-testid="tab-menu"]').exists()).toBe(false)

    await wrapper.find('[role="tab"]').trigger('contextmenu', { clientX: 1, clientY: 1 })
    window.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await nextTick()
    expect(wrapper.find('[data-testid="tab-menu"]').exists()).toBe(false)
  })

  it('reorders on drag and asks for a navigation', async () => {
    const store = useTabsStore()
    const a = store.open({ query: { view: 'chat', session: 'sa' } })
    const b = store.open({ query: { view: 'chat', session: 'sb' } })

    const wrapper = mount(TabBar)
    const tabs = wrapper.findAll('[role="tab"]')
    expect(tabs).toHaveLength(3)

    await tabs[1]?.trigger('dragstart', { dataTransfer: { setData: () => {}, effectAllowed: '' } })
    await tabs[2]?.trigger('drop')
    expect(store.tabs.map((t) => t.key)).toEqual(['home', 'chat:sb', 'chat:sa'])
    expect(wrapper.emitted('navigate')).toHaveLength(1)

    // dragging onto itself is a no-op
    await tabs[0]?.trigger('dragstart', { dataTransfer: { setData: () => {}, effectAllowed: '' } })
    await tabs[0]?.trigger('drop')
    expect(store.tabs.map((t) => t.key)).toEqual(['home', 'chat:sb', 'chat:sa'])
    expect(wrapper.emitted('navigate')).toHaveLength(1)
    void a
    void b
  })

  it('handles wheel events without throwing (the strip scrolls horizontally in a real browser)', async () => {
    useTabsStore()
    const wrapper = mount(TabBar)
    const bar = wrapper.find('[data-testid="tab-bar"]')
    // jsdom has no layout, so scrollLeft never changes there — the
    // assertion is that neither a vertical nor a horizontal wheel throws.
    await bar.trigger('wheel', { deltaY: 40, deltaX: 0 })
    await bar.trigger('wheel', { deltaY: 0, deltaX: 40 })
    expect(bar.exists()).toBe(true)
  })

  it('renders nothing at all when tab mode is off', () => {
    const store = useTabsStore()
    store.open({ query: { view: 'chat', session: 'sa' } })
    store.setEnabled(false)
    const wrapper = mount(TabBar)
    expect(wrapper.find('[data-testid="tab-bar"]').exists()).toBe(false)
    expect(wrapper.findAll('[role="tab"]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="tab-new"]').exists()).toBe(false)
  })
})
