# nalar — Real API surface for routines fire pipeline (Zig 0.16)

When implementing or extending `src/ai_workflow/tui/routines/fire.zig`
or any sibling that uses the same APIs, use the patterns below —
NOT what the planning docs describe (the planning docs were written
with an idealized or older API in mind).

## The real API in this codebase (Zig 0.16)

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
fn foo() sqlite.Error!void { ... }  // ✅ works
fn foo() sqlite.SqliteBackend.Error!void { ... }  // ❌ compile error
```

### `getSingleton()` returns an error union, NOT an optional

```zig
pub fn getSingleton() anyerror!*ContextIPCTui { ... }
```

The two idiomatic patterns:
- `if (nalarcore.getSingleton() catch null) |di| { ... }` (treat as nullable)
- `const di = nalarcore.getSingleton() catch return;` (propagate as `error.GlobalContextNotInitialized`)

The original `if (getSingleton()) |di| { ... }` form does NOT compile
in this codebase — the `|di|` is interpreted as optional-unwrapping,
which doesn't match the error union.

### `RunParamsNew` lives at `nalarcore.ai_mod.ai_workflow.RunParamsNew`

`src/ai_workflow/tui/workflow.zig` does not self-reexport. The path
to the `RunParamsNew` struct (used with `event_bus.emit(T, id, data)`)
is `nalarcore.ai_mod.ai_workflow.RunParamsNew` — TWO `ai_workflow`
segments. (See `session_create.zig:184` for the canonical example.)

### There is NO `std.process.getEnvVar(allocator, key)` in this Zig

Reading env vars goes through `std.process.Environ.Map`:

```zig
const environment: ?*const std.process.Environ.Map = ...;
if (environment) |env| {
    if (env.get("MY_VAR")) |value| {
        // value is []const u8 (or empty string)
    }
}
```

The singleton exposes it as `di.environment: ?*const std.process.Environ.Map`.
Functions that need to read env should TAKE it as a parameter
(compare with `handle_tool.zig:41`, `tool_registry.zig:66`) so the
test path can pass `null` and the production path passes the
singleton's env. NEVER call `std.process.getEnvVar` — it does not
exist.

## The `routines` test setup pattern (mirrors `model_test.zig`)

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

The `session_id` column is nullable. Always include it in the CREATE
TABLE for tests where the fire pipeline writes to `llm_history`
(which itself UPDATEs `sessions.cwd` for the session — so
`CREATE TABLE sessions (id TEXT PRIMARY KEY, ...)` must be present
when testing fire/llm_history integration).

## When to widen `fireRoutine`'s error set to `anyerror!void`

The `FireError` set is meant for controlled, caller-discriminable
failures. But `saveMessage` returns `error.WriteFailed` (from
`std.Io.Writer`), `db.exec`/`db.query` can return `error.QueryFailed`
/ `error.PrepareFailed`/etc. from `sqlite.Error`, and
`cron.nextFireTime` returns `error.InvalidCron`. Trying to
enumerate them all in the public signature leads to a brittle
surface (any internal change forces a signature change). Use
`anyerror!void` and let the sub-process log + exit non-zero on
any non-`FireError` failure. HTTP handlers (Chunk 4) can still
`switch` on `FireError` variants while treating everything else
as 500.

## What was actually committed in the fire.zig Task 2.1 work

Commit `cd4e653` (on `feature/routines` branch) added:
- `src/ai_workflow/tui/routines/fire.zig` — `fireRoutine(...)` with
  `FireError` set + `anyerror!void` return, env-var test short-circuit,
  event_bus.emit to `ai_worker_flow`
- `src/ai_workflow/tui/routines/fire_test.zig` — 4 tests using
  `setupDb` + `withSkipLlmEnv` (env map, NOT process env)
- `src/ai_workflow/tui/routines/mod.zig` — re-exports with a
  placeholder `Scheduler = struct {}` (Task 3.1 will replace)
- `src/ai_workflow/tui/test_runner.zig` — registered fire_test.zig

Test count: 427 → 431 (+4).
