# Cronjob — delete stale `worker` rows + clear matching `ActiveLoops` entries

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-19
**Task:** `task_1787067349981_6` — "create a cronjob delete stale worker"
**User's spec (verbatim):** *"create a cronjob where last_activity is not change after 10 minuts, in table worker, also clear the active loop if exist"*
**Branch / worktree:** `worktree/cleanup-stale-worker-cron` (created from current `in progress` task; per the project rule, do all work in a git worktree and open a PR for review).

**Goal:** Replace the `cleanup_stale_worker` stub with a real cron tick that deletes `worker` rows whose `last_activity_nano` is older than 10 minutes (or NULL) and clears any matching `ActiveLoops` entry, so a `kill -9`'d workflow no longer leaves the session stuck.

**Architecture:** Pure helper `cleanupStaleWorkers(input) !CleanupResult` does the work; thin `handle(ctx, now_unix) void` wrapper pulls `*ContextIPCTui` from the singleton and calls the helper. Per row: `active_loops.remove()` (idempotent) then `deleteWorker()` (reuses the existing primitive so SSE `action="deleted"` still fires).

**Tech Stack:** Zig 0.16, `nalarcore.ContextIPCTui` singleton (`src/root.zig`), `cronjob_manager` (`src/modules/custom_http_server/src/cronjob_manager.zig`), in-memory `ActiveLoops` (`src/ai_workflow/tui/agentic_loop/ActiveLoops.zig`), existing `deleteWorker` (`src/ai_workflow/tui/agentic_loop/delete_worker.zig`).

## Global Constraints

- Handler signature is fixed by `cronjob_manager.register()` (`src/modules/custom_http_server/src/cronjob_manager.zig:87`): `*const fn (ctx: ?*anyopaque, now_unix: i64) void`. The function MUST return `void` — DB errors are caught and logged inside, not propagated.
- Threshold is 10 min (user spec). Exposed as `pub const stale_threshold_seconds: i64 = 600;` so a future env-driven config is a 1-line change.
- No schema / migration changes. Existing `worker` table + `idx_worker_last_activity_nano` index are sufficient.
- No frontend changes. `deleteWorker` already emits SSE `action="deleted"` — the worker list in the UI updates live.
- Do NOT touch `queue_messages` or `sessions` rows. They have a different lifecycle.
- Per project rule: work in a git worktree, open a PR for review.

---

## 1. Context — what problem this solves

### The bug

A `worker` row in `worker` table represents a running agentic loop for one
session. It is **inserted** by `updateWorker`
(`src/ai_workflow/tui/agentic_loop/update_worker.zig:23`) when a workflow
starts, and is **deleted** by the `defer deleteWorker(...)` block at the
end of `runAgenticMultiStepnew`
(`src/ai_workflow/tui/agentic_loop/workflow.zig:484-495`).

The corresponding `ActiveLoops` (`src/ai_workflow/tui/agentic_loop/ActiveLoops.zig`)
is an in-memory `StringHashMap(void)` keyed by `session_id`. It is
**inserted** at every iteration of the agentic `while(true)` loop
(`workflow.zig:558` `_ = active_loops.tryInsert(io, copy_session_id);`) and
**removed** by `defer active_loops.remove(io, copy_session_id);` at
`workflow.zig:497`.

Both defers run **on normal exit or `error` return**. They do **not** run when:

- the `nalar` process is killed (`kill -9`, OOM, SIGKILL, machine power-off)
- a panic bubbles past the workflow frame
- the process is restarted while a workflow is in flight
- an LLM-call hang exceeds some external timeout that aborts the runtime

In those cases we are left with:

1. A stale `worker` row whose `last_activity_nano` is older than 10 min.
2. A stale `ActiveLoops` entry whose `session_id` matches the stale row.

The user-visible symptom: a **second** message sent to that session
incorrectly sees the worker as still running
(`workflow.zig:460-461` — `isWorkerRunning(parent_allocator, db, copy_session_id)`
returns `true` **and** `active_loops.contains(io, copy_session_id)` returns
`true`), so the new message is queued behind a dead worker. From the
user's perspective, the session is "stuck" — no agent ever runs again on
it, even after a server restart that should have cleared the DB row
**except** that `kill -9` skipped the cleanup defer.

### What exists today

`src/schedulers/cleanup_stale_worker.zig` is a **stub** — it only prints
a debug line. The cron **registration is already in place** at
`src/main.zig:506`:

```zig
_ = gs.cronjob_manager.register(
    "* * * * *", // every minute, on the minute
    "cleanup_stale_worker",
    cleanup_stale_worker.handle,
    null,         // ctx — currently null
    boot_unix,
) catch |err| { ... };
```

The cron infrastructure is `cronjob_manager` in
`src/modules/custom_http_server/src/cronjob_manager.zig`. The callback
contract is fixed by `register()` at line 87:

```zig
callback: *const fn (ctx: ?*anyopaque, now_unix: i64) void,
```

So `handle` MUST return `void` (not `!void`) — any DB error has to be
caught and logged inside `handle`, not propagated. The `ctx` parameter is
`?*anyopaque`; today it's `null`. The cron fires every minute (cron
expression `"* * * * *"`) and uses `boot_unix` as the
`last_fired_at` anchor (so the first fire is the first cron tick
STRICTLY AFTER boot — no back-fill).

The schema we operate on (post migration 075 — see
`src/migrations/migration.zig:3203`):

```sql
CREATE TABLE IF NOT EXISTS worker (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    working_directory TEXT,
    last_activity_nano INTEGER DEFAULT (strftime('%s', 'now')),
    last_activity_description TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_worker_last_activity_nano
    ON worker(last_activity_nano DESC);
```

`deleteWorker` (`src/ai_workflow/tui/agentic_loop/delete_worker.zig`) is
the existing primitive: it runs `DELETE FROM worker WHERE id = ?` and, if
`is_emit_sse=true` + `event_bus` is non-null, emits an SSE event with
`action = "deleted"` so the frontend's worker list updates live.

`ActiveLoops` (`src/ai_workflow/tui/agentic_loop/ActiveLoops.zig`) has
exactly three methods:

- `tryInsert(io, session_id) -> bool` — true if newly inserted (caller owns the loop), false if already present
- `remove(io, session_id) -> void` — idempotent, no error if absent
- `contains(io, session_id) -> bool`

All three take `io: std.Io` and lock `self.mutex` (`std.Io.Mutex`)
internally.

The singleton holding `db`, `active_loops`, `allocator`, `io`, `logger`,
`event_bus` is `*nalarcore.ContextIPCTui` (see `src/root.zig:24` for
`getSingleton()` — it returns `error.GlobalContextNotInitialized` if not
set; `src/root.zig:28` for `setSingleton`).

---

## 2. Design decisions

### 2.1 Pure helper + thin `handle` wrapper

The cron callback MUST be `fn(?*anyopaque, i64) void` (no error union).
Two ways to make it testable:

- (A) Pass `ctxParent` (`*ContextIPCTui`) as the opaque `ctx` and cast
  it back inside `handle`. Tested via integration only (constructing a
  full `ContextIPCTui` in a test is heavy).
- (B) Extract a pure helper `cleanupStaleWorkers(input) !CleanupResult`
  that takes everything it needs as parameters; `handle` becomes a thin
  wrapper that pulls from `getSingleton()` and calls the helper.

**Pick (B).** The helper is unit-testable without touching globals; the
wrapper is 5 lines. Same pattern as `workflow.zig:112-188`
(`CallbackAiWorkerFlow.callback` → `runAgenticMultiStepnew`).

### 2.2 SQL: include NULL `last_activity_nano` as stale

Pre-migration-075 rows may have `last_activity_nano = NULL` (they had
`last_activity`). Treat NULL as "stale forever" so they get cleaned up
on the first tick. Use:

```sql
SELECT id, session_id
FROM worker
WHERE last_activity_nano IS NULL OR last_activity_nano < ?
```

(`COALESCE(last_activity_nano, 0) < ?` is functionally equivalent but
breaks the `idx_worker_last_activity_nano` index plan; the `IS NULL OR`
form is index-friendly. The table is small enough that either is fine,
but the `OR` form is clearer about intent.)

The `cutoff` parameter is `now_unix - 600` (10 min), passed in.

### 2.3 Per-row: clear `ActiveLoops` THEN delete worker

Per row:

1. `active_loops.remove(io, session_id)` — idempotent. The user spec
   says "also clear the active loop if exist", which is exactly this.
2. `deleteWorker(...)` — runs `DELETE FROM worker WHERE id = ?` and
   emits the `action="deleted"` SSE event so the UI updates.

`deleteWorker` already handles a missing row as a no-op (SQLite `DELETE`
of zero rows is not an error), so re-running on a row a previous tick
half-completed is safe.

### 2.4 Threshold is a constant, not a config field

10 minutes is the user-spec'd value. Make it a `pub const
stale_threshold_seconds: i64 = 600;` at the top of the file so a future
follow-up can read it from env / config without restructuring. Do not
add env parsing now (YAGNI).

### 2.5 Do NOT touch queue_messages or sessions rows

The user said "delete stale worker". `sessions` rows are user-visible
chat sessions that should outlive any worker restart. `queue_messages`
rows are pending prompts that should be flushed by the next worker
that picks them up (or by an explicit queue-cleanup task later). Both
are out of scope. Document in §4.

### 2.6 Honest trade-off: long-running workflows can be wiped

The agentic `updateWorker` call happens **once** at workflow entry
(`workflow.zig:499-508`). It is NOT re-called every loop iteration.
Therefore a workflow that runs for >10 min (e.g. a complex LLM
investigation that legitimately takes 15 min) will have a stale
`last_activity_nano` and **will be deleted by the cron even though it
is alive**.

This is a real correctness gap. We mitigate it by also calling
`active_loops.remove(io, session_id)` — which is idempotent and won't
kill the alive workflow — but the DB row WILL still be wiped, and the
next message on it will re-trigger `updateWorker` and re-insert the
row. So the user-visible cost is: (a) the worker row flickers out and
back in the sidebar, (b) any concurrent code reading `is_worker_running`
sees `false` for ~one tick.

**We accept this trade-off for v1** because:

- The current behavior is "stuck forever" — much worse than "flickers".
- The follow-up (periodically re-call `updateWorker` inside the
  workflow loop) is a small, surgical change documented in §4.

---

## 3. Tasks

Each task = a commit. Steps are bite-sized (2–5 min each).

### Task 1 — Write the failing test file

**Files:** `src/schedulers/cleanup_stale_worker_test.zig` (new)

- [ ] Create the test file at `src/schedulers/cleanup_stale_worker_test.zig`
      with the standard imports (`std`, `nalarcore`, `database.sqlite`,
      `testing = std.testing`).
- [ ] Add `setupDb` helper that opens an in-memory sqlite DB and runs
      `CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, last_activity_nano INTEGER)`
      — mirrors `delete_worker.zig:53-65` and `update_worker.zig:144-178`.
- [ ] Add `setupActiveLoops(allocator)` helper returning a
      `*ActiveLoops` (test owns it; `defer al.deinit(allocator)`).
- [ ] Add the test stubs (no body yet — just `try testing.expect(false);`
      so they fail):
  - `cleanupStaleWorkers deletes a worker whose last_activity_nano is older than the threshold`
  - `cleanupStaleWorkers keeps a worker whose last_activity_nano is fresher than the threshold`
  - `cleanupStaleWorkers treats NULL last_activity_nano as stale (pre-migration-075 rows)`
  - `cleanupStaleWorkers removes the matching ActiveLoops entry when present`
  - `cleanupStaleWorkers is a no-op when the worker table is empty`
  - `cleanupStaleWorkers clears ActiveLoops for a session whose worker is stale (no worker row to delete)`
  - `cleanupStaleWorkers processes multiple stale workers in one call`
- [ ] Run `zig build test --summary all` and confirm the 7 tests
      **fail** (expected, they are stubs).

### Task 2 — Implement `cleanupStaleWorkers` and the `CleanupResult` type

**Files:** `src/schedulers/cleanup_stale_worker.zig`

- [ ] Replace the stub body with the imports + `pub const
      stale_threshold_seconds: i64 = 600;`.
- [ ] Add `pub const CleanupStaleWorkerInput = struct { ... };` with
      fields: `allocator`, `io`, `db`, `logger` (optional),
      `event_bus` (optional), `active_loops` (`*ActiveLoops`),
      `now_unix: i64`, `threshold_seconds: i64 = stale_threshold_seconds`.
- [ ] Add `pub const CleanupResult = struct { stale_count: usize = 0,
      deleted_count: usize = 0, removed_loop_count: usize = 0 };`.
- [ ] Implement `pub fn cleanupStaleWorkers(input:
      CleanupStaleWorkerInput) !CleanupResult`:
  - `const cutoff = input.now_unix - input.threshold_seconds;`
  - `var rows = try input.db.query(input.allocator,
        "SELECT id, session_id FROM worker WHERE last_activity_nano IS NULL OR last_activity_nano < ?",
        .{cutoff});`
  - `defer rows.deinit();`
  - For each row: `active_loops.remove(input.io, session_id)`,
    `delete_worker.deleteWorker(...)` with `is_emit_sse=true`.
  - Bump `stale_count` per row, `deleted_count` when `deleteWorker`
    succeeds, `removed_loop_count` when `active_loops.contains` was
    true before `remove`.
  - Log a single `[cleanup_stale_worker] tick summary: deleted=N
    removed_loops=M cutoff=T` line at the end via
    `input.logger.?infoFmt(...)`.
- [ ] Add `pub fn handle(ctx: ?*anyopaque, now_unix: i64) void` that:
  - `_ = ctx;`
  - `const di = nalarcore.getSingleton() catch return;`
  - `var arena = std.heap.ArenaAllocator.init(di.allocator); defer
    arena.deinit();`
  - Calls `cleanupStaleWorkers(.{ ..., .now_unix = now_unix })` and on
    error logs via `di.logger.errFmt(...)` and returns.
- [ ] Run `zig build test --summary all` and confirm all 7 new tests
      pass.

### Task 3 — Add the `ActiveLoops.contains` precondition test

**Files:** `src/schedulers/cleanup_stale_worker_test.zig`

- [ ] Add a test that asserts `cleanupStaleWorkers` does NOT delete a
      worker whose `last_activity_nano` is fresher than the threshold,
      EVEN if the `ActiveLoops` has no entry for it (defensive: confirm
      the SQL is the gating check, not the in-memory check).
- [ ] Add a test that asserts `cleanupStaleWorkers` does NOT delete a
      worker whose `last_activity_nano` is exactly `now_unix - 1` (the
      `<` boundary — fresh = not stale).
- [ ] Run `zig build test --summary all` and confirm both pass.

### Task 4 — Add the `deleteWorker` failure tolerance test

**Files:** `src/schedulers/cleanup_stale_worker_test.zig`

- [ ] Add a test that closes the underlying sqlite DB mid-flight (use
      `db.deinit()` after the test setup is done) and confirms
      `cleanupStaleWorkers` does NOT panic — it returns the DB error
      (or, depending on the design choice, logs and continues). Lock
      the design in: if `deleteWorker` fails for one row, log and
      continue to the next row (don't abort the whole batch).
- [ ] Run `zig build test --summary all` and confirm the test passes.

### Task 5 — Wire up the worktree + main.zig

**Files:** `src/main.zig` (no change expected — verify only)

- [ ] Create the worktree: `cd /home/ginwa/ginwaaitoolbox && git
      worktree add -b worktree/cleanup-stale-worker-cron
      .worktrees/cleanup-stale-worker-cron` (or use the
      `set_git_worktree` tool). Confirm the cron registration at
      `main.zig:506-514` is unchanged (the registration is already
      correct).
- [ ] Confirm `gs.cronjob_manager` is started by `gs.listen()` (read
      `gserverz.GinwaServer.listen` if unfamiliar — the existing
      comment block at `main.zig:518-528` documents that the cron
      runs on a background thread, joins on `gs.cronjob_manager.stop()`
      before defers run).
- [ ] No code change to `main.zig` is expected — the stub already has
      the right signature, and `handle` already meets it. Verify with
      `rg -n "cleanup_stale_worker" src/`.

### Task 6 — AGENTS.md changelog + PR

**Files:** `AGENTS.md` (changelog append)

- [ ] Append a `## Recent changes` bullet summarising:
  - `cleanup_stale_worker.handle` now actually cleans up stale rows
    (it was a stub printing a debug line).
  - Fires every minute, deletes workers whose `last_activity_nano <
    now_unix - 600` (or IS NULL), also clears the matching
    `ActiveLoops` entry.
  - Reuses `deleteWorker` so the SSE worker-deleted event still
    fires.
  - Includes the "long-running workflows may flicker" trade-off in
    the bullet, and points to the §4 follow-up.
- [ ] Commit on the worktree branch, open a PR (per project rule:
    human reviews AI agent work in `in_review_task` column).

---

## 4. Out of scope (deliberate, for follow-up kanban tasks)

- **Periodic `updateWorker` heartbeat inside the workflow loop.** The
  real fix for the trade-off in §2.6: bump `last_activity_nano` every
  N seconds inside `runAgenticMultiStepnew`'s `while(true)`. New
  kanban card: *"bump worker.last_activity_nano periodically inside
  the agentic loop so the cleanup cron doesn't wipe long-running
  workers"*.
- **Cleanup of stale `queue_messages` rows.** A separate cron, with
  its own age threshold (e.g. 1 hour) and policy. Different table,
  different lifecycle — keep this PR focused.
- **Sweeping the `sessions.status` to `'idle'` when the worker is
  cleared.** Today `updateWorker` flips status to `'active'` but
  `deleteWorker` does not flip it back. A separate kanban card:
  *"on worker cleanup, flip sessions.status='idle' (or 'crashed') so
  the chat view reflects the real state"*.
- **Configurable threshold.** Make `stale_threshold_seconds` env /
  config-driven. Not asked for; YAGNI.
- **Per-user / per-workspace thresholds.** No multi-tenant story yet.
- **Telemetry / metrics.** How many stale workers cleaned per day,
  avg age, etc. Not asked for.

---

## 5. Verification

| Check | Expected |
|---|---|
| `zig build test --summary all` | all 23xx+ tests pass (10 new ones added), 0 fail |
| `git grep -n "cleanup_stale_worker" src/` | matches `main.zig` (3 lines: import, name, fn) + the implementation file (1 file) |
| `bunx tsc -p src/apps/desktop/tsconfig.json --noEmit` | unchanged (no frontend touch — `deleteWorker` already emits SSE with `action="deleted"`) |
| `bunx vitest run` | unchanged (no frontend touch) |
| Manual: kill -9 the running `nalar` while a workflow is mid-loop, restart, wait 1 min | worker row gone from sidebar; new message on that session_id starts a fresh agent |

---

## 6. Files touched

| File | Change |
|---|---|
| `src/schedulers/cleanup_stale_worker.zig` | Stub replaced with `cleanupStaleWorkers` + `handle` (~70 LOC). |
| `src/schedulers/cleanup_stale_worker_test.zig` | New file with 10 tests (~200 LOC). |
| `AGENTS.md` | One `## Recent changes` bullet. |
| `src/main.zig` | No change expected; verify only. |

**Total: 1 EDIT, 1 NEW test file, 1 DOC bullet.** No migration, no
schema change, no frontend change, no new dependencies.