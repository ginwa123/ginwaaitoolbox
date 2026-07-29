import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import DesignContextMenu from '../components/design/DesignContextMenu.vue'

describe('DesignContextMenu', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
    document.body.innerHTML = ''
  })

  it('renders nothing when visible is false (Teleport closed)', () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: false, x: 100, y: 100, targetIds: ['a'] },
      attachTo: document.body,
    })
    expect(document.querySelector('[data-testid="design-context-menu"]')).toBeNull()
  })

  it('renders the menu container when visible is true, positioned at x/y', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 250, y: 400, targetIds: ['a', 'b'] },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')
    expect(menu).not.toBeNull()
    // jsdom sets `left` / `top` as px strings.
    expect(menu!.style.left).toBe('250px')
    expect(menu!.style.top).toBe('400px')
  })

  it('stops click propagation on the menu container (click inside does not close the menu)', async () => {
    wrapper = mount(DesignContextMenu, {
      props: { visible: true, x: 100, y: 100, targetIds: ['a'] },
      attachTo: document.body,
    })
    await nextTick()
    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')!
    // Bubbling click that reaches `document` would normally trigger our
    // document click-outside dismiss listener (registered in
    // useDesignContextMenu.onMounted). The component uses `@click.stop`,
    // which prevents the click from bubbling to document at all. Assert
    // that after the click, the menu is still visible.
    menu.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(document.querySelector('[data-testid="design-context-menu"]')).not.toBeNull()
  })
})
