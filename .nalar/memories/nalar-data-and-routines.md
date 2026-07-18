# nalar — data, migrations, and routines

This file consolidates nalar patterns for SQLite migrations, the routine fire pipeline, and per-profile config. For SQLite-specific Zig gotchas, see `zig-sqlite-patterns.md`. For migration test pitfalls (Pitfalls 1-3), see `zig-build-and-test.md`. For backend patterns, see `nalar-backend-architecture.md`.

---

## Routine Fire Scenarios and the "task is not a routine" Trap

The nalar routine system (`src/ai_workflow/tui/routines/`) has two distinct IDs:

- **`routines.id`** — the routine's own primary key (auto-generated, often starts with `routine_`).
- **`routines.task_id`** — the foreign key into `workspace_item_tasks.id` (starts with `task_`). This is what `fire.fireRoutine` looks up via `model.loadRoutineByTaskId` to fire the routine.

**Symptom:** Calling `POST /api/workspaces/:w/items/:i/tasks/:tid/run` with the **routine's** id (`routine_task_...`) instead of the **task's** id (`task_...`) returns:

```json
{"error":"task is not a routine"}
```

This is `FireError.NotARoutine` from `fire.zig:102` — the `loadRoutineByTaskId(allocator, db, task_id)` lookup is by `task_id` column, not by the routine's primary `id`. The `GET /api/routines` listing uses `id` and `task_id` as sibling fields, so it's easy to grab the wrong one.

**Fix — use `task_id` from the `/api/routines` response:**

```json
{
  "id": "routine_task_1781520711748",        // ← DON'T use this for run endpoint
  "task_id": "task_1781520711748",           // ← USE this
  "workspace_id": "ws_1781495294658_c2ea64c921892900",
  "workspace_item_id": "item_1781495330453685730"
}
```

**Correct call:**

```bash
curl -X POST "http://127.0.0.1:8081/api/workspaces/ws_.../items/item_.../tasks/task_.../run"
```

## Orphaned Routines

A routine can become orphaned if the parent `workspace_item_tasks` row is deleted without first removing the `routines` row. The routine continues to fire on schedule, but the LLM-side `session_create` event may fail or create a session with no navigation path back to the workspace.

**To detect orphaned routines:**

```sql
SELECT r.id, r.task_id, r.schedule, r.last_status
FROM routines r
LEFT JOIN workspace_item_tasks t ON r.task_id = t.id
WHERE t.id IS NULL;
```

`GET /api/routines` joins both tables, so orphaned routines DO NOT appear in the list — they only show up via direct DB inspection. (The fire path doesn't care; it only reads from `routines`.)

## Routine fire pipeline — real API surface (Zig 0.16)

When implementing or extending `src/ai_workflow/tui/routines/fire.zig` or any sibling that uses the same APIs, use these patterns — NOT what planning docs describe (the planning docs were written with an idealized or older API).

### `SqliteBackend` is opened via `db.init(io, ":memory:")`, NOT `db.openInMemory(allocator)`

```zig
var threaded = std.Io.Threaded.init(alloc, .{});
errdefer threaded.deinit();
const io = threaded.io();
var db: sqlite.SqliteBackend = .{};
errdefer db.deinit();
try db.init(io, ":memory:");
```

### Column reads go through `row.values[i]` (NOT `stmt.columnText(i)`)

```zig
var q = try db.query(alloc, "SELECT name FROM routines WHERE id = ?", &.{id});
defer q.deinit();
const row = (try q.next()) orelse return error.NotFound;
defer row.deinit(alloc);
const name = row.values[0];  // []u8 — empty string for NULL
```

### `SqliteBackend.Error` is a TOP-LEVEL const, NOT on the struct

```zig
const sqlite = nalarcore.sqlite;
fn foo() sqlite.Error!void { ... }      // ✅ works
fn foo() sqlite.SqliteBackend.Error!void { ... }  // ❌ compile error
```

### `getSingleton()` returns an error union, NOT an optional

```zig
pub fn getSingleton() anyerror!*ContextIPCTui { ... }
```

Two idiomatic patterns:

```zig
if (nalarcore.getSingleton() catch null) |di| { ... }    // treat as nullable
const di = nalarcore.getSingleton() catch return;        // propagate
```

The original `if (getSingleton()) |di| { ... }` form does NOT compile — `|di|` is interpreted as optional-unwrapping, which doesn't match the error union.

### `RunParamsNew` lives at `nalarcore.ai_mod.ai_workflow.RunParamsNew`

`src/ai_workflow/tui/workflow.zig` does not self-reexport. The path to `RunParamsNew` is `nalarcore.ai_mod.ai_workflow.RunParamsNew` — TWO `ai_workflow` segments.

### There is NO `std.process.getEnvVar(allocator, key)` in Zig 0.16

Reading env vars goes through `std.process.Environ.Map`:

```zig
const environment: ?*const std.process.Environ.Map = ...;
if (environment) |env| {
    if (env.get("MY_VAR")) |value| {
        // value is []const u8 (or empty string)
    }
}
```

Functions that need to read env should TAKE it as a parameter. NEVER call `std.process.getEnvVar` — it does not exist.

### The routines test setup pattern (mirrors `model_test.zig`)

```zig
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_item_tasks (from Migration 034) + Migration 044
    try db.exec(alloc, "CREATE TABLE workspace_item_tasks (...session_id TEXT, ...)", &.{});
    try Migration044AddRoutines.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}
```

`session_id` column is nullable. Always include it in CREATE TABLE for tests where the fire pipeline writes to `llm_history`.

### When to widen `fireRoutine`'s error set to `anyerror!void`

The `FireError` set is for controlled, caller-discriminable failures. But `saveMessage` returns `error.WriteFailed` (from `std.Io.Writer`), `db.exec`/`db.query` can return `error.QueryFailed`/`error.PrepareFailed`/etc., and `cron.nextFireTime` returns `error.InvalidCron`. Trying to enumerate them all in the public signature leads to a brittle surface. Use `anyerror!void` and let the sub-process log + exit non-zero on any non-`FireError` failure. HTTP handlers can still `switch` on `FireError` variants while treating everything else as 500.

---

## Migration #009-#052 fresh-DB cascade is fragile; CI smoke test catches it

When the criteria-pass smoke test (`scripts/ci-smoke-test.sh`) boots `nalar` against an isolated `$HOME` (auto-creating `config.json` + running all 54 migrations from scratch), the `runMigrations` step fails at FOUR different migrations:

1. **Migration 009** — references a `created` column that has never existed. `created_at` has been the column name since Migration 001. The `INSERT…SELECT datetime(CAST(created AS INTEGER), 'unixepoch')` crashes with `no such column: created`.

2. **Migration 009** also forward-projects the schema — its `CREATE TABLE` declares `temperature REAL` and `is_thinking INTEGER DEFAULT 0`, which **Migration 011** later tries to `ADD COLUMN`. On a fresh DB this crashes with `duplicate column name: temperature`.

3. **Migration 020** uses `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, which SQLite doesn't support. The three columns (`working_directory`, `last_activity`, `last_activity_description`) are already in Migration 019's CREATE TABLE for `worker`, so on a fresh DB this is also a `duplicate column name` error if you just remove the `IF NOT EXISTS`.

4. **Migration 052** calls `DROP COLUMN session_id` on `workspace_item_tasks`, but Migration 034's canonical schema never declares `session_id`. On a fresh DB: `no such column: session_id`.

**Why these bugs were hidden:** Every developer's existing database has these migrations already applied (or already failed). The "happy path" smoke check (`./zig-out/bin/nalar --version`) doesn't actually boot the server, so none of the bootstrap code paths are exercised. CI didn't catch it because CI used the same `--version` placebo check. New users on fresh installs would hit the bug.

**The fixes (in PR #69):**

1. `migration.zig` Migration 009: replace `datetime(CAST(created AS INTEGER), 'unixepoch')` with `COALESCE(created_at, CURRENT_TIMESTAMP)`. Also remove `temperature` and `is_thinking` from Migration 009's CREATE TABLE / INSERT projection.

2. New helpers `addColumnIfMissing` and `dropColumnIfExists` in `migration.zig`. Both are zero-alloc, stack-buffer their SQL strings, and check `pragma_table_info('<table>')` before issuing the ALTER. Used by Migrations 020 and 052 respectively.

3. New regression test `migration_009_test.zig` replays Migrations 001–008 + 009 against an in-memory DB and asserts no crash.

**Verify with:**

```bash
env -i HOME=/tmp/nalar-fresh-test PATH=$PATH \
  ./zig-out/bin/nalar --port 18080 &
sleep 5
ss -tln | grep 18080  # expect: 0 (server crashed on migration)
```

---

## SQL Convention: Always Alias Tables in SELECTs

Per code-review feedback on PR #10, the project convention is to **always alias every table in every SELECT** — including single-table queries that don't technically need an alias.

| Table | Alias |
|---|---|
| `llm_history` | `h` |
| `sessions` | `s` |
| `workspace_item_tasks` | `t` |
| `routines` | `r` |
| `workspace_items` | `wi` |
| `workspaces` | `w` |

**Style rules:**

```zig
// Correct (this codebase's style)
const sql = "SELECT wi.id FROM workspace_items wi WHERE wi.workspace_id = ?";

// NOT this codebase's style
const sql = "SELECT wi.id FROM workspace_items AS wi WHERE wi.workspace_id = ?";

// Correct
const sql = "SELECT wi.id, wi.workspace_id, wi.position FROM workspace_items wi ORDER BY wi.position DESC";

// Wrong — bare column names even though the table is aliased
const sql = "SELECT id, workspace_id, position FROM workspace_items wi ORDER BY position DESC";
```

**Why this convention:**

1. **Forces intent in JOIN contexts.** A single-table query with an alias reads the same as the same query in a JOIN — the developer who copy-pastes it into a JOIN doesn't have to retrofit aliases.
2. **Catches bugs where someone adds a JOIN and forgets to qualify columns.** With bare `id` references, an added JOIN that brings in another `id` column creates an ambiguous reference; SQLite picks one and the bug is silent.
3. **Consistent with the existing JOIN queries** in `llm_history.zig`.

**What about INSERTs / UPDATEs / DELETEs / migrations?** These are DML/DDL, not SELECTs — aliasing doesn't apply.

**Static test pattern:** write checks permissively to tolerate the alias form:

```zig
// Wrong: too strict, breaks when the column is aliased
if (std.mem.indexOf(u8, source, "ORDER BY position DESC") == null) { ... }

// Right: works with both forms
if (std.mem.indexOf(u8, source, "position DESC") == null) { ... }
```

---

## Config per-profile compaction options

When adding new configurable settings to `LlmConfig`, choose between two architectural shapes:

**Option 1 — Top-level on `LlmConfig`:** Both fields live on top-level `LlmConfig`. HTTP wire format exposes them as top-level keys. Frontend renders ONE input row. Simpler resolver (`cfg.maxCapacityForModel(model)` — no profile/sub-agent cascade). Loses per-profile override.

**Option 2 — Per-profile on `LlmProfile`:** Both fields live on `LlmProfile`. Sub-agents inherit from parent unless they override (SubAgentConfig gets the same two fields with default `null`). HTTP wire format removes the top-level keys. Frontend iterates profiles and renders one row per profile.

**The user's choice (option 2):** "because it is much easy to configure, and every profile will have a [compaction_setting] ..."

**Reasoning:**
- Every profile needs its own context window (self-hosted model has different window than MiniMax-M3). Putting the field on the profile keeps model + window bundled together.
- The per-profile map shape is already there for `model` and `base_url`; adding two more keys is incremental. The top-level shape would require a NEW top-level map keyed by profile name (a 1:1 mirror of `profiles_models`).
- Future-proof: when more per-profile knobs land (temperature, max_tokens defaults), they all live in the same struct.

**When facing "top-level vs per-profile" decisions:** **default to per-profile** unless there's a strong reason (e.g., global hard limit like `model_compaction_size_kb`). The cost of migration back to top-level is high.

---

## Related / cross-references

- `zig-sqlite-patterns.md` — SQLite-specific patterns (PrepareFailed vs QueryFailed, empty-slice-as-NULL, tx design)
- `zig-build-and-test.md` — Migration tests pitfalls (raw strings, use-after-free, PrepareFailed)
- `nalar-backend-architecture.md` — backend patterns, agent error messages