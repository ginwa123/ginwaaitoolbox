import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import DesignContextMenu from '../components/design/DesignContextMenu.vue'

describe('DesignContextMenu', () => {
  let wrapper: VueWrapper | null = null

  // Helper: a page-element list containing one of each interesting
  // type. Tests pick the id(s) they need from this constant.
  const elements = [
    { id: 'a', type: 'rectangle' },
    { id: 'b', type: 'rectangle' },
    { id: 'g', type: 'group' },
    { id: 'f', type: 'frame' },
  ]

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(navigator, 'platform', { value: 'Linux x86_64', configurable: true })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
    document.body.innerHTML = ''
  })

  it('renders nothing when visible is false (Teleport closed)', () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: false, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    expect(document.querySelector('[data-testid="design-context-menu"]')).toBeNull()
  })

  it('renders the menu container when visible is true, positioned at x/y', async () => {
    wrapper = mount(DesignContextMenu, {
      // Use small x/y so viewport edge-clamping (40px × 10 rows = 400px
      // tall, 220px wide) doesn't shift the menu. Chunk 9 added 1 more
      // menu row (Ungroup), so we keep y small to test the un-clamped
      // positioning contract.
      props: { visible: true, x: 50, y: 50, targetIds: ['a', 'b'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')
    expect(menu).not.toBeNull()
    expect(menu!.style.left).toBe('50px')
    expect(menu!.style.top).toBe('50px')
  })

  it('stops click propagation on the menu container (click inside does not close the menu)', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')!
    menu.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(document.querySelector('[data-testid="design-context-menu"]')).not.toBeNull()
  })

  it('renders all 8 menu items in the spec order with correct testids (Chunk 9 added Ungroup)', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a', 'b'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const expected = [
      'design-context-menu-group',
      'design-context-menu-ungroup',
      'design-context-menu-select-all',
      'design-context-menu-separator-1',
      'design-context-menu-bring-to-front',
      'design-context-menu-bring-forward',
      'design-context-menu-send-backward',
      'design-context-menu-send-to-back',
      'design-context-menu-separator-2',
      'design-context-menu-delete',
    ]
    for (const testid of expected) {
      const el = document.querySelector(`[data-testid="${testid}"]`)
      expect(el, `expected ${testid} in DOM`).not.toBeNull()
    }
  })

  it('clicking Bring to front emits bringToFront with the targetIds', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a', 'b'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-bring-to-front"]',
    )!
    btn.click()
    await nextTick()
    const emits = wrapper.emitted('bringToFront')
    expect(emits).toBeTruthy()
    expect(emits?.[0]).toEqual([['a', 'b']])
  })

  it('Group is disabled when fewer than 2 ids are targetIds', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-group"]',
    )!
    expect(btn.disabled).toBe(true)
    btn.click()
    await nextTick()
    // Group emit should NOT fire because the button is disabled.
    expect(wrapper.emitted('group')).toBeUndefined()
  })

  // ─── Chunk 9 — Ungroup ────────────────────────────────────────────────

  it('Ungroup is enabled when exactly one group is selected', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(false)
  })

  it('Ungroup is enabled when exactly one frame is selected', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['f'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(false)
  })

  it('Ungroup is disabled when the single selection is a rectangle', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(true)
  })

  it('Ungroup is disabled when more than one element is selected', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['g', 'a'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    expect(btn.disabled).toBe(true)
  })

  it('clicking Ungroup emits ungroup with the single selected id', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['g'], elements },
      attachTo: document.body,
    })
    await nextTick()
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-ungroup"]',
    )!
    btn.click()
    await nextTick()
    expect(wrapper.emitted('ungroup')).toEqual([['g']])
  })
})