import { onBeforeUnmount, ref, watch } from 'vue'

/**
 * Position state + dismiss wiring for the right-click context menus
 * (KanbanTaskContextMenu.vue, OpenInNewTabMenu.vue, GitBranchMenu.vue).
 * Hosts keep their own payload (chat, item, task ids); this only owns
 * the nullable screen position and the listeners that dismiss it.
 *
 * Dismissal triggers:
 *   - Escape
 *   - mousedown outside the menu
 *   - wheel / scroll  ← the card's menu lives inside the card's subtree,
 *     and the kanban columns render through a VirtualScroller. Scrolling a
 *     card out of the viewport unmounts the card, and with it the menu,
 *     killing it mid-interaction. Closing on scroll removes that whole
 *     class of bug. Both are capture-phase so a menu that stops propagation
 *     can't survive a scroll either.
 *
 * Edge clamping: menus are placed at the raw clientX/clientY. A card in a
 * 280px-wide column can be right-clicked near the viewport's right edge,
 * which would push the menu (and its "Move to column" submenu) off-screen.
 * `clampToViewport` pulls the coordinates back inside.
 */
export function useContextMenu(options: { width?: number; height?: number } = {}) {
  // Estimated menu footprint, used before the menu is measured. Over-
  // estimating slightly is fine — it only pulls the menu a few px further
  // from the edge than strictly necessary, whereas under-estimating
  // clips it.
  const MENU_W = options.width ?? 220
  const MENU_H = options.height ?? 320

  const menuPos = ref<{ x: number; y: number } | null>(null)

  const openAt = (event: MouseEvent) => {
    event.preventDefault()
    menuPos.value = clampToViewport(event.clientX, event.clientY)
  }

  /**
   * Pull a (x, y) inside the viewport, keeping the menu's estimated
   * footprint visible. Exported as a pure function so a host that
   * computes its own position (e.g. the ContextMenu-key path, which
   * anchors at a card's bounding-rect centre) can reuse the same rule.
   */
  function clampToViewport(x: number, y: number): { x: number; y: number } {
    const maxX = Math.max(8, window.innerWidth - MENU_W - 8)
    const maxY = Math.max(8, window.innerHeight - MENU_H - 8)
    return {
      x: Math.min(Math.max(8, x), maxX),
      y: Math.min(Math.max(8, y), maxY),
    }
  }

  const close = () => {
    menuPos.value = null
  }

  const onKeydown = (event: KeyboardEvent) => {
    if (event.key === 'Escape') close()
  }

  const onPointerDown = (event: MouseEvent) => {
    if (!menuPos.value) return
    const target = event.target as HTMLElement | null
    if (target && typeof target.closest === 'function') {
      // Our own menus opt out of the outside-click dismiss.
      if (target.closest('[data-context-menu]')) return
      if (target.closest('[data-testid="open-new-tab-menu"]')) return
    }
    close()
  }

  const onScroll = () => close()

  watch(menuPos, (opened) => {
    if (opened) {
      window.addEventListener('keydown', onKeydown)
      window.addEventListener('mousedown', onPointerDown)
      window.addEventListener('wheel', onScroll, { capture: true, passive: true })
      window.addEventListener('scroll', onScroll, true)
      return
    }
    window.removeEventListener('keydown', onKeydown)
    window.removeEventListener('mousedown', onPointerDown)
    window.removeEventListener('wheel', onScroll, true)
    window.removeEventListener('scroll', onScroll, true)
  })

  onBeforeUnmount(() => {
    window.removeEventListener('keydown', onKeydown)
    window.removeEventListener('mousedown', onPointerDown)
    window.removeEventListener('wheel', onScroll, true)
    window.removeEventListener('scroll', onScroll, true)
  })

  return { menuPos, openAt, close, clampToViewport }
}
