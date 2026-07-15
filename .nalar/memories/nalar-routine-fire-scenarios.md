# nalar — Routine Fire Scenarios and the "task is not a routine" Trap

The nalar routine system (`src/ai_workflow/tui/routines/`) has two distinct IDs that look similar but are used in different APIs:

- **`routines.id`** — the routine's own primary key (auto-generated, often starts with `routine_`).
- **`routines.task_id`** — the foreign key into `workspace_item_tasks.id` (starts with `task_`). This is what `fire.fireRoutine` looks up via `model.loadRoutineByTaskId` to fire the routine.

## Symptom

Calling `POST /api/workspaces/:w/items/:i/tasks/:tid/run` with the **routine's** id (`routine_task_...`) instead of the **task's** id (`task_...`) returns:

```json
{"error":"task is not a routine"}
```

This is `FireError.NotARoutine` from `fire.zig:102` — the `loadRoutineByTaskId(allocator, db, task_id)` lookup is by `task_id` column, not by the routine's primary `id`. The `GET /api/routines` listing uses `id` and `task_id` as sibling fields, so it's easy to grab the wrong one.

## Fix

The `task_id` field in the `/api/routines` response is the correct path parameter. For example, from the live system:

```json
{
  "id": "routine_task_1781520711748",        // ← DON'T use this for the run endpoint
  "task_id": "task_1781520711748",           // ← USE this
  "workspace_id": "ws_1781495294658_c2ea64c921892900",
  "workspace_item_id": "item_1781495330453685730"
}
```

The correct call is:
```bash
curl -X POST "http://127.0.0.1:8081/api/workspaces/ws_.../items/item_.../tasks/task_.../run"
```

## Related: Orphaned Routines

A routine can become orphaned if the parent `workspace_item_tasks` row is deleted (manually or via cascade) without first removing the `routines` row. The routine continues to fire on schedule (its `enabled=1` and `next_run_at` is still tracked), but the LLM-side `session_create` event may fail or create a session with no navigation path back to the workspace.

To detect orphaned routines:
```sql
SELECT r.id, r.task_id, r.schedule, r.last_status
FROM routines r
LEFT JOIN workspace_item_tasks t ON r.task_id = t.id
WHERE t.id IS NULL;
```

The `GET /api/routines` endpoint joins both tables, so orphaned routines DO NOT appear in the list — they only show up via direct DB inspection. (The fire path doesn't care; it only reads from `routines`.)

## Free FX API for IDR (and other currencies)

For automated routine fires that need a live IDR rate, the free tier of `exchangerate-api.com` works reliably (verified `2026-06-16`):

```bash
curl -sS "https://open.er-api.com/v6/latest/USD" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('1 USD =', d['rates']['IDR'], 'IDR'); print('Last update:', d['time_last_update_utc'])"
```

Output:
```
1 USD = 17831.638218 IDR
Last update: Mon, 15 Jun 2026 00:02:31 +0000
```

The `api.frankfurter.app` endpoint returned a 301 redirect (Cloudflare in front) on `2026-06-16`, so prefer the open.er-api.com endpoint. Browser-based fetches (cloak_browser snapshot) miss the dynamic value because the page hydrates client-side — see `cloak-browser-snapshot-misses-js-data.md`.

## How to verify

- The routine `enabled=1` row with `next_run_at <= now` AND `last_status != 'running'` is picked up by the scheduler within 5 s.
- `claimForRun` flips `last_status` to `running`, then `markSuccess` flips it to `success` and advances `next_run_at` to the next cron tick.
- A successful fire creates a session row with `id = task_id` (per the project's `task.id == session.id` invariant for routine tasks), so `SELECT * FROM sessions WHERE id = '<task_id>'` should return a row right after the fire.
