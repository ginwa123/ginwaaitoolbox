import { onBeforeUnmount, ref, watch } from 'vue'

/**
 * Position state + dismiss wiring for the "Open in new tab" context
 * menu (OpenInNewTabMenu.vue). Hosts keep their own payload (chat,
 * item, task ids); this only owns the nullable screen position.
 * Dismisses on Escape and on any mousedown outside the menu.
 */
export function useContextMenu() {
  const menuPos = ref<{ x: number; y: number } | null>(null)

  const openAt = (event: MouseEvent) => {
    event.preventDefault()
    menuPos.value = { x: event.clientX, y: event.clientY }
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
    if (target && typeof target.closest === 'function' && target.closest('[data-testid="open-new-tab-menu"]')) return
    close()
  }

  watch(menuPos, (opened) => {
    if (opened) {
      window.addEventListener('keydown', onKeydown)
      window.addEventListener('mousedown', onPointerDown)
      return
    }
    window.removeEventListener('keydown', onKeydown)
    window.removeEventListener('mousedown', onPointerDown)
  })

  onBeforeUnmount(() => {
    window.removeEventListener('keydown', onKeydown)
    window.removeEventListener('mousedown', onPointerDown)
  })

  return { menuPos, openAt, close }
}
