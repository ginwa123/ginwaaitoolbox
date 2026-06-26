/**
 * KanbanSse — Pinia store that owns ONE kanban SSE connection per
 * workspace the user is viewing. Ref-counts the subscribers per
 * workspace so multiple components (AppLayout, KanbanView) can
 * `subscribeKanbanSse(workspaceId)` without opening multiple
 * connections.
 *
 * On `kanban_column.*` and `kanban_task.*` events, dispatches to
 * the workspacesStore to refresh the affected item's columns.
 * (Re-fetching on every event is the simplest correct action;
 * kanban_column mutations always change column ordering or
 * membership, and kanban_task.moved renumbers sibling positions
 * in the target column. A future optimization could patch in-place
 * using the SSE payload's `new_column_id` + `new_position`.)
 *
 * Plan: docs/superpowers/plans/2026-06-26-fix-kanban-list-empty-add-sse.md
 *   Chunk 4 / Task 4.2
 */
import { defineStore } from 'pinia'
import { ref } from 'vue'
import {
  createKanbanSseConnection,
  type KanbanColumnEvent,
  type KanbanTaskEvent,
} from '../api'
import type { SseClient } from '../helpers/sseClient'
import { useWorkspacesStore } from './workspaces'

interface WorkspaceKanbanConnection {
  sse: SseClient
  refCount: number
}

export const useKanbanSseStore = defineStore('kanbanSse', () => {
  // Map<workspaceId, { sse, refCount }>. One SSE connection per
  // workspace; ref-counted so multiple components can subscribe
  // without stacking connections.
  const connections = ref<Map<string, WorkspaceKanbanConnection>>(new Map())

  /**
   * Increment the ref-count for `workspaceId`. If this is the first
   * subscriber, opens a new SSE connection to /api/kanban/events.
   * Idempotent — calling subscribeKanbanSse twice without an
   * intermediate unsubscribe is a no-op (ref-count grows to 2).
   */
  function subscribeKanbanSse(workspaceId: string): void {
    const existing = connections.value.get(workspaceId)
    if (existing) {
      existing.refCount += 1
      return
    }
    const sse = createKanbanSseConnection({
      onEvent: (raw, eventType) => {
        // 'connected' is consumed by the SseClient (transitions to
        // 'open' state). It's also passed here for symmetry with the
        // other factories, but KanbanColumnEvent / KanbanTaskEvent
        // have no 'connected' variant so we ignore it.
        if (eventType === 'connected' || eventType === 'message') {
          // Heartbeat ('message' with raw === 'ping') is filtered by
          // the SseClient's heartbeatData default; an unknown
          // default-event arriving here is treated as no-op.
          return
        }
        try {
          const data = JSON.parse(raw)
          if (eventType === 'kanban_column') {
            handleColumnEvent(data as KanbanColumnEvent)
          } else if (eventType === 'kanban_task') {
            handleTaskEvent(data as KanbanTaskEvent)
          }
        } catch (err) {
          // Malformed event payload — don't crash the connection.
          console.error('[kanbanSse] failed to parse event:', err, raw)
        }
      },
      onError: (err) => {
        console.error('[kanbanSse] connection failed permanently:', err)
      },
    })
    connections.value.set(workspaceId, { sse, refCount: 1 })
  }

  /**
   * Decrement the ref-count for `workspaceId`. When the count
   * reaches zero, close the SSE connection and remove the entry.
   * No-op if `workspaceId` was never subscribed (defensive against
   * stray unmounts during HMR or test teardown).
   */
  function unsubscribeKanbanSse(workspaceId: string): void {
    const existing = connections.value.get(workspaceId)
    if (!existing) return
    existing.refCount -= 1
    if (existing.refCount <= 0) {
      existing.sse.close()
      connections.value.delete(workspaceId)
    }
  }

  function handleColumnEvent(event: KanbanColumnEvent): void {
    const ws = useWorkspacesStore()
    // action: created/updated/deleted/reordered — all of them change
    // the column list shape, so just re-fetch.
    void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
  }

  function handleTaskEvent(event: KanbanTaskEvent): void {
    const ws = useWorkspacesStore()
    // kanban_task.moved renumbers sibling positions in the target
    // column (kanban_model.moveTask step 3). Re-fetching is the
    // simplest correct action; a future optimization could patch
    // the moved task in-place + renumber siblings client-side.
    void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
  }

  return { subscribeKanbanSse, unsubscribeKanbanSse }
})
