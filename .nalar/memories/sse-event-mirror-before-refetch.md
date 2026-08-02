# SSE event handler: mirror local state BEFORE refetch to avoid stale-state residue

## Symptom (real instance, task_1785688388584)

User runs `kanban_move_task` agent tool to move a task from column A to B.
The frontend shows the task in BOTH columns until refresh. After refresh, the duplicate disappears.

## Root cause

The SSE handler (`kanbanSse.ts`) calls `fetchKanbanTasks(destCol, 100, ...)`
on a `kanban_task` event with `action: 'moved'`. The merge logic in
`workspaces.ts::fetchKanbanTasks`:

```ts
const otherTasks = item.tasks.filter((t) => t.kanban_column_id !== destCol)
item.tasks = [...otherTasks, ...normalized]
```

…assumes the local task's `kanban_column_id` is authoritative for what's in
each column. When an agent moves a task, the SSE event arrives BEFORE the
local state is updated. So:

- `otherTasks` filter keeps the stale source-column copy (T.kanban_column_id !== 'colB')
- `normalized` adds the fresh dest-column copy from the wire
- **Result: duplicate in `item.tasks`**

User-initiated moves don't hit this because `moveTaskToColumn` mutates the
local id before the SSE round-trip. Agent moves (and any other non-UI source)
bypass that path entirely.

## Fix (frontend-only)

The SSE handler must MIRROR the local state to match the event payload
BEFORE triggering the refetch. After the mirror, the merge logic correctly
excludes the stale source-column copy.

```ts
// In kanbanSse.ts:
if (event.action !== 'human_touched') {
  ws.mirrorKanbanTaskMove(
    event.workspace_id, event.item_id, event.task_id,
    event.new_column_id ?? null, event.new_position ?? undefined,
  )
}
// ... then call fetchKanbanTasks / fetchKanbanTasksForAllColumns
```

The `human_touched` action is special — its payload carries null and is
NOT a move. Skip the mirror for it.

## The general pattern

**SSE events that signal a state mutation should be mirrored into the local
store BEFORE any refetch.** The refetch confirms the wire state, but the
mirror is what makes the merge logic produce a consistent result instead of
a state-residue duplicate.

This pattern applies to ANY resource that:
1. Has a "moved" / "reassigned" / "mutated" SSE event
2. Has a merge logic that uses a local field as the filter key (e.g.
   `kanban_column_id`, `parent_id`, `workspace_id`)
3. Can be mutated by a non-UI client (agent tool, another tab, another user)

## Where else to look

- `src/apps/desktop/src/stores/designSse.ts` — design-element SSE events
  (move, delete, update) may have the same risk. Fix already in place via
  `registerRecentLocalMutations` (1.5s TTL on local mutations) + the
  `fetchDesignElements` merge pattern. Verify the same pattern if you add
  a new "moved" event for design elements.
- Any new store action that filters by a local field that an SSE event
  might invalidate.

## Anti-pattern

```ts
// BAD: trust the wire response alone
onSseEvent(event) {
  fetchResource(event.id)  // returns fresh data, but local in-memory
                            // still has a copy with the OLD field value
}
```

```ts
// GOOD: mirror first, then refetch
onSseEvent(event) {
  if (event.moved) {
    localCopy.state_field = event.new_state  // ← mirror
  }
  fetchResource(event.id)  // now the merge is consistent
}
```

## Files

- `src/apps/desktop/src/stores/workspaces.ts` — `mirrorKanbanTaskMove` action
- `src/apps/desktop/src/stores/kanbanSse.ts` — call site in the `task_id` branch
- `src/apps/desktop/src/api/index.ts` — `KanbanTaskEvent` action union (added `human_touched`)
- `src/apps/desktop/src/__tests__/kanbanSseMirrorMove.spec.ts` — 8 tests
- `docs/superpowers/plans/2026-08-06-sse-kanban-move-duplicate-task.md` — plan
- `AGENTS.md` — changelog entry

## Branch / PR

`worktree/sse-kanban-move-duplicate` @ `88c80575`
PR #175
