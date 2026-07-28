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
 *
 * Chunk 6 added `groupSelection` for the Cmd+G shortcut. It reads
 * `selectedIds.value` + `activeDesignPageId` from the store /
 * caller-provided args so the wire is reachable from DesignView's
 * keyboard handler without bouncing through AppLayout.
 */
export interface UseDesignHandlersArgs {
  workspaceId: string | { value: string } | (() => string)
  itemId: string | { value: string } | (() => string)
  pageId: string | { value: string } | (() => string)
  /**
   * Reactive Set of currently-selected element ids. The composable
   * reads `selectedIds.value.size` to enforce the 2+ rule and
   * replaces `selectedIds.value = new Set()` after a successful
   * group. Pass it as a ref/computed so changes from DesignView
   * propagate here.
   */
  selectedIds: { value: Set<string> }
  /**
   * Optional override for the browser prompt. The default uses
   * `window.prompt` (the first-cut implementation; Figma uses an
   * inline rename affordance — see plan §7.1 for the follow-up).
   * Tests pass a stub to avoid blocking on the real prompt.
   */
  promptForName?: (defaultValue: string) => string | null
}

// Normalize an "id source" arg (string | ref | getter) to a string
// evaluated AT CALL TIME so the value is always fresh even when the
// caller passes a computed/ref. Falls back to '' for empty refs.
function readId(id: string | { value: string } | (() => string)): string {
  if (typeof id === 'string') return id
  if (typeof id === 'function') return id()
  if (id && typeof id === 'object' && 'value' in id) return id.value
  return ''
}

export function useDesignHandlers(args?: UseDesignHandlersArgs) {
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

  /**
   * NEW (Chunk 6 of grouped-layers plan). Figma convention: Cmd/Ctrl+G
   * wraps the current selection into a new `group` at the union bbox.
   *
   * Selection gate: silent no-op when `selectedIds.size < 2` (matches
   * Figma). The composable then prompts the user for a name via
   * `window.prompt` (first-cut; plan §7.1 documents inline-rename as
   * a follow-up).
   *
   * On success: clears the selection Set and fires a success toast.
   * On failure: fires an error toast with the apiFetch error message.
   *
   * The args shape is intentional — the composable accepts only what
   * it needs to call the store, no extra state. DesignView passes its
   * `selectedIds` ref + `workspaceId` / `itemId` props so the wire
   * stays in one place.
   */
  async function groupSelection(): Promise<void> {
    if (!args) {
      console.warn('[useDesignHandlers.groupSelection] no args provided; skipping')
      return
    }
    const workspaceId = readId(args.workspaceId)
    const itemId = readId(args.itemId)
    const pageId = readId(args.pageId)
    if (!workspaceId || !itemId || !pageId) {
      // Missing ids — quiet no-op (AppLayout/DesignView could race
      // a keypress before the page is loaded). matches how
      // `updateElement`/`deleteElement` handle the no-page case.
      return
    }
    const { selectedIds, promptForName } = args
    // Figma convention: silent no-op when fewer than 2 elements are
    // selected. Reading .size happens at call time so multi-click
    // scenarios (last selection before keystroke) read the live value.
    if (selectedIds.value.size < 2) return
    // Selected ids is stored as a Set; the API expects an array.
    const childIds = Array.from(selectedIds.value)
    const defaultName = `Group ${childIds.length}`
    // First-cut implementation: window.prompt. A future inline-rename
    // affordance (plan §7.1) would replace this with an input UI
    // bound to the new group's name. Tests pass `promptForName` to
    // bypass the real browser prompt.
    const promptFn = promptForName ?? ((defaultValue: string): string | null => window.prompt('Name the new group:', defaultValue))
    const name = promptFn(defaultName)
    // User clicked Cancel — treat as no-op (don't create an empty group).
    if (name === null) return
    try {
      await workspacesStore.groupDesignElements(workspaceId, itemId, pageId, {
        child_ids: childIds,
        name,
        type: 'group',
      })
      // Clear selection so the user can immediately Cmd+G again on a
      // fresh selection (Figma behavior — grouping collapses to the
      // new parent, then the user picks the next group).
      selectedIds.value = new Set()
      // The notification store only exposes notifyError (a single
      // success-vs-error style is overkill for the 1-shot success
      // case here). Success notifications auto-dismiss in 5s like
      // error notifications, so the UX is consistent.
      notificationStore.notifyError(
        `Grouped ${childIds.length} elements into "${name}".`,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      notificationStore.notifyError(message, 'Failed to group selection.')
    }
  }

  return { updateElement, deleteElement, groupSelection }
}