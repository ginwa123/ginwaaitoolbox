import { useNotificationStore } from '../stores/notifications'
import { useWorkspacesStore } from '../stores/workspaces'

/**
 * AppLayout's design-mode handlers, extracted into a composable so
 * they're directly testable (SFC <script setup> functions aren't
 * importable as named exports). The composable owns NO state — it
 * reads the active workspace/item/page from the store and dispatches
 * to the store actions. Errors surface via the notification store.
 *
 * Page CRUD (add / delete) used to live here too — AppLayout would
 * call the API and trust that DesignView would re-fetch its pages
 * list. It didn't, leaving the user staring at stale tabs until they
 * reloaded the page. The fix moved the page CRUD into DesignView
 * itself (which owns the `pages` state), so this composable no
 * longer exposes page-level handlers. The store action
 * `workspacesStore.deleteDesignPage` still exists for direct callers
 * (and is covered by `workspacesStoreDeleteDesignPage.spec.ts`).
 */
export function useDesignHandlers() {
  const workspacesStore = useWorkspacesStore()
  const notificationStore = useNotificationStore()

  async function updateElement(
    workspaceId: string,
    itemId: string,
    elementId: string,
    patch: Record<string, unknown>,
  ): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      console.warn('[useDesignHandlers.updateElement] no activeDesignPageId; ignoring patch', { workspaceId, itemId, elementId, patch })
      return
    }
    const keys = Object.keys(patch)
    const isGeometryOnly = keys.length > 0 && keys.every((k) => k === 'x' || k === 'y' || k === 'width' || k === 'height' || k === 'rotation')
    try {
      if (isGeometryOnly) {
        await workspacesStore.updateDesignElementGeometry(
          workspaceId, itemId, pageId, elementId,
          patch as { x?: number; y?: number; width?: number; height?: number; rotation?: number },
        )
      } else {
        await workspacesStore.updateDesignElement(
          workspaceId, itemId, pageId, elementId, patch,
        )
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to update element', message)
    }
  }

  async function deleteElement(workspaceId: string, itemId: string, elementId: string): Promise<void> {
    const pageId = workspacesStore.activeDesignPageId
    if (!pageId) {
      console.warn('[useDesignHandlers.deleteElement] no activeDesignPageId; ignoring', { workspaceId, itemId, elementId })
      return
    }
    if (!confirm('Delete this element?')) return
    try {
      await workspacesStore.deleteDesignElement(workspaceId, itemId, pageId, elementId)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError('Failed to delete element', message)
    }
  }

  return { updateElement, deleteElement }
}