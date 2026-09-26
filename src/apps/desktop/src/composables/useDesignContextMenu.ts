import { useEventListener } from '@vueuse/core'
import { computed, ref } from 'vue'

export interface ContextMenuState {
  visible: boolean
  x: number
  y: number
  targetIds: string[]
}

/**
 * Drives a Teleport-based right-click menu (used by both the design
 * layers panel and the design canvas). Owns the open/close lifecycle
 * and the document-level listeners that dismiss the menu on
 * click-outside, Escape, window resize, or scroll.
 *
 * The caller mounts <DesignContextMenu> bound to `state.value` and
 * invokes `open(event, ids)` from a `@contextmenu.prevent` handler.
 *
 * Why per-component instance: each <DesignView> / <LayersPanel>
 * gets its own composable instance so two open menus (e.g. the
 * chat-open / chat-closed branches) don't share state.
 */
export function useDesignContextMenu() {
  const state = ref<ContextMenuState>({
    visible: false,
    x: 0,
    y: 0,
    targetIds: [],
  })

  function open(event: MouseEvent, targetIds: string[]): void {
    event.preventDefault()
    state.value = {
      visible: true,
      x: event.clientX,
      y: event.clientY,
      targetIds: [...targetIds],
    }
  }

  function close(): void {
    state.value = { visible: false, x: 0, y: 0, targetIds: [] }
  }

  function handleDocumentClick(): void {
    if (state.value.visible) close()
  }

  function handleDocumentKeydown(event: KeyboardEvent): void {
    if (state.value.visible && event.key === 'Escape') close()
  }

  function handleWindowResize(): void {
    if (state.value.visible) close()
  }

  function handleWindowScroll(): void {
    if (state.value.visible) close()
  }

  useEventListener(document, 'click', handleDocumentClick)
  useEventListener(document, 'keydown', handleDocumentKeydown)
  useEventListener(window, 'resize', handleWindowResize)
  // Capture phase so we catch scroll inside any overflow container
  // (e.g. the layers panel) before the scroll bubbles up.
  useEventListener(window, 'scroll', handleWindowScroll, true)

  return {
    open,
    close,
    state: computed(() => state.value),
  }
}
