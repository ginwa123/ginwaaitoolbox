/**
 * KanbanSse — owns ONE kanban SSE connection for the app's lifetime,
 * mirroring the workersSse pattern in App.vue:
 *   - Module-level `connection` (one global stream, not per-workspace)
 *   - `initKanbanSse(workspaceId)` tears down any existing connection
 *     before opening a new one
 *   - 3-callback API: `(onEvent, onError, onConnected)` — same shape as
 *     `createWorkersSseConnection`
 *   - `onConnected` re-runs `fetchInitialKanban()` so a server restart
 *     that lost in-memory state re-syncs on the next open
 *
 * The backend's kanban SSE routing keys (`kanban_column`,
 * `kanban_task`) are GLOBAL — every connected client receives every
 * event. We filter client-side by `event.workspace_id ==
 * activeWorkspaceId` before dispatching to workspacesStore. Workspace
 * switches don't reopen the connection; they just update the filter.
 *
 * Plan: docs/superpowers/plans/2026-06-26-fix-kanban-list-empty-add-sse.md
 *   Chunk 4 / Task 4.2 (original SSE wiring) → refactored to workers
 *   pattern (this version).
 */
import { defineStore } from 'pinia'
import { createKanbanSseConnection } from '../api'
import type { SseClient } from '../api'
import { useWorkspacesStore } from './workspaces'

interface KanbanConnection {
  sse: SseClient
  workspaceId: string
}

export const useKanbanSseStore = defineStore('kanbanSse', () => {
  // One global SSE connection. The kanban events are workspace-scoped,
  // so we filter by `connection.workspaceId` inside the onEvent handler.
  let connection: KanbanConnection | null = null

  /**
   * Open the kanban-event SSE stream for `workspaceId`. If a connection
   * is already open (e.g. user navigated back to the same workspace, or
   * we mounted twice), it is torn down first to avoid stacking
   * connections. Safe to call multiple times — the SseClient's
   * exponential backoff (1s → 30s, full jitter) keeps reconnects
   * bounded.
   */
  function initKanbanSse(workspaceId: string): void {
    // Tear down existing connection before opening a new one.
    // Mirrors the workersSse pattern in App.vue:46-71.
    if (connection) {
      connection.sse.close()
      connection = null
    }

    connection = {
      sse: createKanbanSseConnection(
        // onEvent — receives a typed KanbanColumnEvent | KanbanTaskEvent
        // (the factory parses JSON internally, see api/index.ts).
        (event) => {
          // Drop events for other workspaces — the backend fans out
          // kanban events globally, so any connected client receives
          // them all. Skipping the no-op fetch keeps the local store's
          // re-fetch rate at 1 per actual mutation.
          if (event.workspace_id !== workspaceId) return
          const ws = useWorkspacesStore()
          // action: created/updated/deleted/reordered/moved/assigned/unassigned
          // — all of them change the column/task list shape, so just
          // re-fetch. A future optimization could patch in-place using
          // the SSE payload's fields.
          void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
        },
        // onError — fires on TERMINAL failure only (state went to
        // 'failed'). Transient errors are retried internally and do
        // not fire this callback — the old behavior of logging every
        // retry attempt was misleading, since a reconnect is not an
        // error from the user's perspective.
        (error) => {
          console.error('[kanbanSse] connection failed permanently:', error)
        },
        // onConnected — re-runs on every successful (re)connect. A
        // server restart that loses in-memory state should be re-synced
        // on the next open, just like the workers SSE pattern.
        () => {
          console.log('[kanbanSse] connected')
          fetchInitialKanban(workspaceId)
        },
      ),
      workspaceId,
    }
  }

  /**
   * Tear down the kanban-event SSE connection. Called on
   * AppLayout unmount; no-op if the connection is already closed.
   */
  function closeKanbanSse(): void {
    if (connection) {
      connection.sse.close()
      connection = null
    }
  }

  /**
   * Update the workspace filter without reopening the SSE connection.
   * Called by AppLayout's `watch(activeWorkspaceId, ...)` — a
   * workspace switch is just a filter change because the backend's
   * routing key is global.
   */
  function setActiveWorkspaceId(workspaceId: string): void {
    if (!connection) return
    connection = { sse: connection.sse, workspaceId }
  }

  /**
   * Initial kanban-column sync on SSE (re)connect. Mirrors
   * `fetchInitialWorkers()` in App.vue — a server restart can lose
   * in-memory state, so the next open should re-fetch the active
   * kanban item's columns to make sure local state matches the DB.
   *
   * No-op if the active workspace item isn't a kanban (chat folders
   * don't have columns; the SSE events for other workspaces are
   * filtered out at the dispatch layer anyway).
   */
  async function fetchInitialKanban(workspaceId: string): Promise<void> {
    const ws = useWorkspacesStore()
    const item = ws.activeWorkspaceItem
    const parentWs = ws.activeWorkspace
    if (!item || item.item_type !== 'kanban') return
    // Only fetch columns if the active item actually belongs to the
    // workspace we just (re)connected for — otherwise we'd hit a
    // foreign item with stale state.
    if (!parentWs || parentWs.id !== workspaceId) return
    try {
      await ws.fetchKanbanColumns(workspaceId, item.id)
    } catch (err) {
      console.error('[kanbanSse] fetchInitialKanban failed:', err)
    }
  }

  return { initKanbanSse, closeKanbanSse, setActiveWorkspaceId }
})