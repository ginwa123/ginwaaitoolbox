# SSE kanban move: agent-triggered moves produce visible duplicate tasks (2026-08-06)

## Symptom (user report, task_1785688388584)

*"see the dupliocate kanban , i think when agent move the task through sse event, the code in frontend didnt properly handle that, after i refresh the page it become normal"*

User's screenshot shows the `cli` task (task_1785674002603) visible in BOTH
`in_review_task` AND `in progress` columns simultaneously. The backend (a
fresh `GET /api/workspaces/.../tasks?limit=100` against the live server)
returns the task in `in_review_task` ONLY. After a page refresh, the
frontend matches the backend again — the `in progress` copy disappears.

User explicitly identified the cause: agent moves via `kanban_move_task`
trigger a `kanban_task` SSE event, and the frontend SSE handler doesn't
properly handle the move (it produces a duplicate).

## Root cause

The SSE handler in `src/apps/desktop/src/stores/kanbanSse.ts` (lines
115-167) handles `task_id` events by calling `fetchKanbanTasks` for the
destination column. The merge logic in
`src/apps/desktop/src/stores/workspaces.ts::fetchKanbanTasks` (lines
1231-1235) is:

```ts
if (!item.tasks) item.tasks = []
const otherTasks = item.tasks.filter(
  (t) => t.kanban_column_id !== columnId,
)
item.tasks = [...otherTasks, ...normalized]
```

This assumes that the local copy's `kanban_column_id` is authoritative
for what's in each column. When the agent (or any non-UI client) moves
a task from colA → colB, the SSE event arrives BEFORE the local task's
`kanban_column_id` is updated. So:

| Step | Local `task.kanban_column_id` | Backend says | otherTasks filter | normalized |
|------|-------------------------------|--------------|-------------------|------------|
| Pre-fix | `'colA'` | task in `'colB'` | keeps T (T.kanban_column_id !== 'colB') | adds T (server returned T in 'colB') → **DUPLICATE** |

After a refresh, the `init()` flow re-fetches the whole board and the
stale local copy is replaced — explaining why the bug "goes away" on
refresh.

User-initiated moves don't hit the bug because `moveTaskToColumn`
(workspaces.ts:1475) explicitly mutates `task.kanban_column_id =
columnId` locally BEFORE the SSE round-trip completes. Agent moves skip
that path entirely.

## Fix (surgical frontend change)

**Mirror the local task's `kanban_column_id` (and `kanban_position`) in
the SSE handler BEFORE triggering the refetch.** The mirror is a
synchronous property assignment on the local task — no HTTP, no race.
After the mirror, the `fetchKanbanTasks` merge logic correctly excludes
the stale source-column copy and includes the fresh destination-column
copy from the wire.

### Concrete changes

1. **`src/apps/desktop/src/stores/workspaces.ts`** — expose a new
   public action `mirrorKanbanTaskMove(wsId, itemId, taskId,
   newColumnId, newPosition)` that:
   - Locates the item via the existing private `findItem`.
   - Locates the task via `item.tasks.find(t => t.id === taskId)`.
   - If both exist, mutates `task.kanban_column_id = newColumnId ?? null`
     and `task.kanban_position = newPosition ?? task.kanban_position`.
   - Idempotent no-op if the task isn't in the local store (defensive
     against SSE events arriving before the initial board load).
   - Returns `void`.

2. **`src/apps/desktop/src/stores/kanbanSse.ts`** — in the
   `'task_id' in event` branch (lines 117-167), call
   `ws.mirrorKanbanTaskMove(...)` immediately after reading the
   `activeWorkspaceId` filter check and BEFORE the
   `fetchKanbanTasks` / `fetchKanbanTasksForAllColumns` calls. Apply to
   all four actions (`assigned` / `moved` / `unassigned` /
   `human_touched`) — the mirror is a no-op for `human_touched` if
   `new_column_id` is null (the existing wire shape).

3. **Tests** — new file `src/apps/desktop/src/__tests__/kanbanSseMirrorMove.spec.ts`
   with 6+ behavioural tests:
   - **`moved` event with stale local state**: local task in colA,
     dispatch `{action: 'moved', new_column_id: 'colB', new_position:
     0}`, assert local task's `kanban_column_id === 'colB'` and
     `kanban_position === 0` immediately after the dispatch (BEFORE
     the awaited fetch resolves).
   - **`moved` event with full integration**: local task in colA,
     `api.getTasks` mock returns the task in colB, dispatch the event,
     await microtasks, assert `item.tasks` has exactly 1 copy of the
     task in colB and 0 copies in colA.
   - **`unassigned` event with stale local state**: local task in
     colA, dispatch `{action: 'unassigned', new_column_id: null}`,
     assert local task's `kanban_column_id === null`.
   - **`assigned` event with no prior local state**: local task in
     colA, dispatch `{action: 'assigned'}` for a DIFFERENT task id
     (not in local), assert mirror no-ops silently (no throw,
     existing tasks untouched).
   - **`human_touched` event**: existing flow continues; local task's
     column id is unchanged.
   - **Idempotent mirror**: dispatch the same `moved` event twice,
     assert column id and position are both set to the same value
     (no double-update side effects).

## Why this approach (vs. alternatives)

**Alt A**: Mirror inside `fetchKanbanTasks` by passing the moved
task_id into the function. Rejected — the function is called from 4
other call sites (initial mount, search, sort, load-more) that don't
have a "moved task" context. Adding a parameter would require
nullable defaults everywhere.

**Alt B**: SSE handler does a full-board re-fetch on every move.
Rejected — defeats the per-column pagination plan (kanban-per-column-
pagination.md) and adds an extra roundtrip. The mirror is O(1) local
mutation; the existing per-column fetch is unchanged.

**Alt C**: Make the merge logic `diff` against the wire response
instead of filtering by column id. Rejected — would still need a
target column to merge into, and would be more complex than the
mirror.

## Files touched

- `src/apps/desktop/src/stores/workspaces.ts` — add
  `mirrorKanbanTaskMove` action + export.
- `src/apps/desktop/src/stores/kanbanSse.ts` — call the mirror
  before each `fetchKanbanTasks` / `fetchKanbanTasksForAllColumns`
  call in the `task_id` branch.
- `src/apps/desktop/src/__tests__/kanbanSseMirrorMove.spec.ts` (new).

No backend, DB, migration, or build.zig changes. No Zig changes at
all.

## Verification

- `bun run build` clean.
- `bunx vitest run` — all tests pass, no regressions to the
  pre-existing 1997 passing / 12 failing baseline.
- `zig build test --summary all` — unchanged (no Zig changes).
- `zig build-obj -target x86_64-windows-gnu` — unchanged.
- `zig build-obj -target aarch64-macos` — unchanged.

## Out of scope

- **Refactor of the SSE handler to call `fetchKanbanTasksForAllColumns`
  instead of single-column** — would over-fetch. Deferred unless the
  per-column approach proves too slow.
- **SSE event carrying `old_column_id`** — would let the mirror be
  even more direct. Deferred to a backend plan; the mirror from local
  state is sufficient.
- **A pre-flight check that the local task's column matches the SSE
  event's prior state** — would catch out-of-order events. Out of
  scope; the broker doesn't guarantee order, but the bug is
  idempotent (a re-dispatch sets the same column id).
