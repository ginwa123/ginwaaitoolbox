# Frontend Error Logs Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture frontend (nalar-desktop webapp) errors into a backend `logs` table with `POST /api/logs` and `GET /api/logs` endpoints.

**Architecture:** Single new migration (063) creates the `logs` table. Two new HTTP handlers (POST for capture, GET for retrieval). Single new frontend module (`frontendLogClient.ts`) installs 4 listeners (`window.error`, `window.unhandledrejection`, monkey-patched `console.error`/`console.warn`) that queue events with a 250ms debounce, flush via `fetch()` normally and via `navigator.sendBeacon()` on page-unload.

**Tech Stack:** Zig 0.16 backend (SqliteBackend, GinwaServer router, http_handlers pattern), TypeScript frontend (EventSource-style custom transport, vitest).

**Spec:** `docs/plans/2026-07-17-frontend-error-logs-design.md`

---

## File map

| File | Action | Purpose |
|---|---|---|
| `src/migrations/migration.zig` | EDIT | Add `Migration063AddFrontendLogs` struct + register in `MigrationManager.all` |
| `src/migrations/migration_063_test.zig` | CREATE | Migration tests (CREATE TABLE + idempotent) |
| `src/ai_workflow/tui/http_handlers/frontend_log_post.zig` | CREATE | POST /api/logs handler |
| `src/ai_workflow/tui/http_handlers/frontend_log_post_test.zig` | CREATE | POST handler tests |
| `src/ai_workflow/tui/http_handlers/frontend_log_get.zig` | CREATE | GET /api/logs handler |
| `src/ai_workflow/tui/http_handlers/frontend_log_get_test.zig` | CREATE | GET handler tests |
| `src/ai_workflow/tui/http_handlers/mod.zig` | EDIT | Re-export the two new handlers |
| `src/main.zig` | EDIT | Register `POST /api/logs` and `GET /api/logs` routes |
| `src/apps/desktop/src/helpers/frontendLogClient.ts` | CREATE | Capture + transport module |
| `src/apps/desktop/src/__tests__/frontendLogClient.spec.ts` | CREATE | Frontend tests |
| `src/apps/desktop/src/main.ts` | EDIT | Install log client + expose `logCtx` on window |
| `src/apps/desktop/src/App.vue` | EDIT | Wire `route` + `activeChatId` to `logCtx` |

---

## Chunk 1: Backend — Migration063AddFrontendLogs

**Files:**
- Modify: `src/migrations/migration.zig` (add struct + register)
- Create: `src/migrations/migration_063_test.zig`

### Task 1.1: Add Migration063 struct

- [ ] **Step 1: Add the migration struct at the bottom of `migration.zig`**

Append immediately after `Migration062AddTaskDescription` (around line 2109, the closing `};` of that struct). Match the existing `Migration0XXName = struct { pub const version: u32; pub const name: []const u8; pub fn up(...) }` shape exactly. Use the helper `addColumnIfMissing` is NOT appropriate here — this is a CREATE TABLE. Use `db.exec(allocator, "CREATE TABLE IF NOT EXISTS logs (...);CREATE INDEX ...", &.{})` directly. Use a 64-byte stack buffer to assemble the SQL (multiple statements joined by `"; "`).

```zig
/// Add the `logs` table for frontend error capture. See
/// docs/plans/2026-07-17-frontend-error-logs-design.md for the full
/// rationale and column semantics.
///
/// Schema notes:
///   - `created_at` is microseconds (matches `llm_history` etc.)
///   - `kind` discriminator: 'window_error' | 'unhandled_rejection' |
///     'console_error' | 'console_warn'
///   - `count` lets a tight loop of console.error collapse to a single
///     row with `count=50` instead of 50 rows. Dedup key in the POST
///     handler is `(kind, message, stack)` within a 1-second window.
///   - `idx_logs_created_at DESC` is the primary read path (recent first).
///   - `idx_logs_level` supports `WHERE level = ?` filtering.
pub const Migration063AddFrontendLogs = struct {
    pub const version: u32 = 63;
    pub const name = "add_frontend_logs";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(
            allocator,
            \\CREATE TABLE IF NOT EXISTS logs (
            \\  id TEXT PRIMARY KEY,
            \\  created_at INTEGER NOT NULL,
            \\  level TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  message TEXT NOT NULL,
            \\  stack TEXT,
            \\  source TEXT,
            \\  line INTEGER,
            \\  route_path TEXT,
            \\  session_id TEXT,
            \\  count INTEGER NOT NULL DEFAULT 1
            \\)
        , &.{});
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC)",
            &.{},
        );
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level)",
            &.{},
        );
    }
};
```

- [ ] **Step 2: Register the migration in `MigrationManager.all`**

Find the existing `.all` array (around line 1768 in `migration.zig`). Add one entry:

```zig
.{ .version = Migration063AddFrontendLogs.version, .name = Migration063AddFrontendLogs.name, .up = Migration063AddFrontendLogs.up },
```

Right after the Migration062 entry.

- [ ] **Step 3: Verify it compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: build success, no test count changes (no test added yet).

- [ ] **Step 4: Commit**

```bash
git add src/migrations/migration.zig
git commit -m "feat(migrations): add Migration063AddFrontendLogs (logs table)"
```

### Task 1.2: Migration test (CREATE TABLE + idempotent)

- [ ] **Step 1: Create the test file**

File: `src/migrations/migration_063_test.zig`. Follow the `migration_0XX_test.zig` pattern (e.g. `migration_057_test.zig`):

```zig
//! Migration 063 — `logs` table for frontend error capture.
//!
//! Plan: docs/plans/2026-07-17-frontend-error-logs-design.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration063AddFrontendLogs = migration.Migration063AddFrontendLogs;

/// Open a fresh in-memory sqlite DB and apply only Migration 063.
/// Mirrors `migration_routines_test.zig::setupDb`.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

test "Migration063 creates logs table with all 11 columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration063AddFrontendLogs.up(&s.db, alloc);

    var rows = try s.db.query(alloc,
        "SELECT name FROM pragma_table_info('logs') ORDER BY cid", &.{});
    defer rows.deinit();

    const expected = [_][]const u8{
        "id", "created_at", "level", "kind", "message",
        "stack", "source", "line", "route_path", "session_id", "count",
    };

    var idx: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

test "Migration063 creates the created_at and level indexes" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration063AddFrontendLogs.up(&s.db, alloc);

    // pragma_index_list is not in this version of sqlite.zig's helper set;
    // query sqlite_master directly.
    var rows = try s.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='logs' ORDER BY name", &.{});
    defer rows.deinit();

    var found_idx_created_at = false;
    var found_idx_logs_level = false;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_logs_created_at")) found_idx_created_at = true;
        if (std.mem.eql(u8, row.values[0], "idx_logs_level")) found_idx_level = true;
    }
    try testing.expect(found_idx_created_at);
    try testing.expect(found_idx_level);
}

test "Migration063 is idempotent (re-running up() is a no-op)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration063AddFrontendLogs.up(&s.db, alloc);
    // Second run must not error (CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS).
    try Migration063AddFrontendLogs.up(&s.db, alloc);
}
```

NOTE: there's a typo in the test (`found_idx_level` instead of `found_idx_logs_level`) — fix in your actual write. Use `inline for` only if you need to scan struct fields; here we use plain `while` since column names come from the DB.

- [ ] **Step 2: Register the test in the test runner**

Find the project's test runner. Check `src/ai_workflow/tui/test_runner.zig` and add:
```zig
_ = @import("../../../migrations/migration_063_test.zig");
```
(Adjust path if the test runner layout differs — match the precedent set by migration_057_test registration.)

- [ ] **Step 3: Run the new tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 3 new tests pass (the 3 in `migration_063_test.zig`), test count rises by 3 vs. previous baseline.

- [ ] **Step 4: Commit**

```bash
git add src/migrations/migration_063_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "test(migrations): add Migration063AddFrontendLogs tests"
```

---

## Chunk 2: Backend — POST /api/logs handler

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/frontend_log_post.zig`
- Create: `src/ai_workflow/tui/http_handlers/frontend_log_post_test.zig`

### Task 2.1: Implement the handler

- [ ] **Step 1: Write `frontend_log_post.zig`**

File: `src/ai_workflow/tui/http_handlers/frontend_log_post.zig`. Follow the `memories_create.zig` thin-wrapper pattern: use `parseFromSliceLeaky` for the body, validate fields, run a use-case function, return 204 / 400 / 500. Skip the `getSingleton`/environment check (not needed — DB is accessed via the singleton's SqliteBackend).

The handler signature: `pub fn frontendLogPostHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse`.

Body type (Zig struct with optional fields per the design):

```zig
const FrontendLogBody = struct {
    level: []const u8,
    kind: []const u8,
    message: []const u8,
    route_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    stack: ?[]const u8 = null,
    source: ?[]const u8 = null,
    line: ?i64 = null,
};
```

Valid `level` values: `"error" | "warn" | "info" | "debug"`. Valid `kind` values: `"window_error" | "unhandled_rejection" | "console_error" | "console_warn"`.

Insert logic:
1. Compute `id = std.fmt.allocPrint(allocator, "log_{d}", .{std.time.microTimestamp()}) catch ...` — fallback to `log_unknown` if microTimestamp fails.
2. Dedup check: `SELECT id FROM logs WHERE kind=? AND message=? AND IFNULL(stack,'')=IFNULL(?,'') AND created_at >= ? LIMIT 1`. Bind `now_us - 1_000_000` (1 second in microseconds). If a row matches, run `UPDATE logs SET count = count + 1 WHERE id = ?` and return 204.
3. Otherwise `INSERT INTO logs (id, created_at, level, kind, message, stack, source, line, route_path, session_id, count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`.

Return: `204 No Content` (use `res.jsonResponse(.{ .status_code = 204, .data = "" })` — check the GinwaServer API for how to return an empty body; if there's a dedicated `.noContentResponse`, use that. If not, return an empty string with status 204).

Validation errors:
- Missing `level` / `kind` / `message` → `400` with `{ "error": "missing required field: <field>" }`
- Invalid `level` value → `400` with `{ "error": "level must be one of: error, warn, info, debug" }`
- Invalid `kind` value → `400` with `{ "error": "kind must be one of: window_error, unhandled_rejection, console_error, console_warn" }`

DB write failure → `500` with `{ "error": "Failed to persist log" }`. Log via `std.log.warn(...)` (NOT `std.log.err` — see project memory `zig-0.16-test-log-err-count` — `.err` triggers `log_err_count > 0` in `zig build test`).

- [ ] **Step 2: Verify it compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: build success, no test count change.

- [ ] **Step 3: Commit (handler only, no test yet — TDD is broken here intentionally because there's no behavioral GinwaServer harness)**

```bash
git add src/ai_workflow/tui/http_handlers/frontend_log_post.zig
git commit -m "feat(handlers): add frontend_log_post handler (logs table insert)"
```

### Task 2.2: Static-contract tests for the handler

This codebase doesn't have a behavioral GinwaServer test harness for handlers (see project memory `nalar-http-handler-thin-wrapper-pattern`). The established pattern is static-contract tests that grep the handler source. Follow `memories_crud_test.zig` exactly.

- [ ] **Step 1: Write `frontend_log_post_test.zig`**

File: `src/ai_workflow/tui/http_handlers/frontend_log_post_test.zig`. Tests:

1. `handler uses parseFromSliceLeaky` — assert `"parseFromSliceLeaky"` substring in source.
2. `handler validates level field` — assert error message `"missing required field: level"` substring.
3. `handler validates kind field` — assert error message `"missing required field: kind"` substring.
4. `handler validates message field` — assert error message `"missing required field: message"` substring.
5. `handler validates level value` — assert substring `"level must be one of"`.
6. `handler validates kind value` — assert substring `"kind must be one of"`.
7. `handler uses std.json.Stringify for error responses` — but the error path uses `http_response.makeErrorResponse`, which IS valueAlloc. Assert `"makeErrorResponse"` substring.
8. `handler returns 204 on success` — assert `"status_code = 204"` substring (or the actual return literal — match the project's variable style).
9. `handler returns 400 on missing field` — assert `"status_code = 400"` substring for the missing-field case.
10. `handler returns 500 on db error` — assert `"status_code = 500"` substring for the db-error case.

Use `readSource(allocator, HANDLER_PATH)` helper exactly like `memories_crud_test.zig` does. Use `HANDLER_PATH = "src/ai_workflow/tui/http_handlers/frontend_log_post.zig"`.

- [ ] **Step 2: Register the test in the test runner**

Find `src/ai_workflow/tui/http_handlers/test_runner.zig` (or wherever handler tests are registered — match the precedent of `memories_crud_test.zig` registration) and add:
```zig
_ = @import("frontend_log_post_test.zig");
```

- [ ] **Step 3: Run the tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 10 new tests pass (all in `frontend_log_post_test.zig`).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/frontend_log_post_test.zig src/ai_workflow/tui/http_handlers/test_runner.zig
git commit -m "test(handlers): static-contract tests for frontend_log_post"
```

### Task 2.3: Behavioral SQL tests (dedup logic)

The dedup logic is the most subtle part — we want behavioral coverage, not just static. Use the in-memory SqliteBackend pattern from `routines/scheduler_test.zig::setupDb`.

- [ ] **Step 1: Add behavioral tests to `frontend_log_post_test.zig`**

Append a new `test "..."` block. Since the handler takes `(ctx, req, res)` and we don't have a GinwaServer harness, test the **dedup SQL query** directly:

```zig
test "dedup SQL: same kind+message+stack within 1s increments count" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try Migration063AddFrontendLogs.up(&db, alloc);

    const now = std.time.microTimestamp();

    // Insert row #1
    try db.exec(alloc,
        "INSERT INTO logs (id, created_at, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_1", now, "error", "console_error", "boom", "stack1" });

    // Insert row #2 with same key (same kind, message, stack) but newer
    // created_at (within 1s)
    try db.exec(alloc,
        "INSERT INTO logs (id, created_at, level, kind, message, stack, count) VALUES (?, ?, ?, ?, ?, ?, 1)",
        &.{ "log_2", now + 500_000, "error", "console_error", "boom", "stack1" });

    // Dedup check: query the older row
    var rows = try db.query(alloc,
        "SELECT id, count FROM logs WHERE kind=? AND message=? AND IFNULL(stack,'')=IFNULL(?,'') AND created_at >= ? LIMIT 1",
        &.{ "console_error", "boom", "stack1", now });
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.NoDedupMatch;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("log_1", row.values[0]);
    try testing.expectEqualStrings("1", row.values[1]);

    // Increment count on the matched row
    try db.exec(alloc, "UPDATE logs SET count = count + 1 WHERE id = ?", &.{"log_1"});

    // Verify count is now 2
    var rows2 = try db.query(alloc, "SELECT count FROM logs WHERE id = ?", &.{"log_1"});
    defer rows2.deinit();
    const row2 = (try rows2.next()) orelse return error.RowMissing;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("2", row2.values[0]);
}

test "dedup SQL: different kind+message+stack within 1s does NOT match" {
    // ... similar setup ...
    // Insert "boom" with stack1, then query for "boom" with stack2
    // Expect: 0 rows returned
}

test "dedup SQL: same key but >1s apart does NOT match (no dedup)" {
    // ... similar setup ...
    // Insert at now, then at now + 1_500_000 (1.5s later)
    // Expect dedup query returns 0 rows
}
```

- [ ] **Step 2: Run the tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 13 new tests pass (10 static + 3 behavioral).

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/frontend_log_post_test.zig
git commit -m "test(handlers): behavioral SQL dedup tests for frontend_log_post"
```

---

## Chunk 3: Backend — GET /api/logs handler

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/frontend_log_get.zig`
- Create: `src/ai_workflow/tui/http_handlers/frontend_log_get_test.zig`

### Task 3.1: Implement the handler

- [ ] **Step 1: Write `frontend_log_get.zig`**

File: `src/ai_workflow/tui/http_handlers/frontend_log_get.zig`. Mirror the `session_messages_get.zig` pattern for query parameter parsing. The handler:

1. Reads query params: `level`, `kind`, `session_id`, `since` (microseconds), `limit`.
2. Validates: `limit` defaults to 100, capped at 1000.
3. Builds a parameterized SQL: `SELECT id, created_at, level, kind, message, stack, source, line, route_path, session_id, count FROM logs WHERE 1=1 [AND level=?] [AND kind=?] [AND session_id=?] [AND created_at >= ?] ORDER BY created_at DESC LIMIT ?`.
4. Executes the query via `db.query(...)`.
5. Maps each row into a `FrontendLogRow` response struct.
6. Serializes via `std.json.Stringify.valueAlloc(allocator, FrontendLogListResponse{ .logs = rows, .count = rows.len }, .{})`.

Response type (add to `http_response.zig` at the bottom):
```zig
pub const FrontendLogRow = struct {
    id: []const u8,
    created_at: i64,
    level: []const u8,
    kind: []const u8,
    message: []const u8,
    stack: ?[]const u8 = null,
    source: ?[]const u8 = null,
    line: ?i64 = null,
    route_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    count: i64,
};

pub const FrontendLogListResponse = struct {
    logs: []const FrontendLogRow,
    count: u32,
};

pub fn makeFrontendLogListResponse(allocator: std.mem.Allocator, logs: []const FrontendLogRow) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        FrontendLogListResponse{ .logs = logs, .count = @intCast(logs.len) },
        .{},
    );
}
```

Per-request arena owns the row allocations (per project memory `custom-http-server-per-request-arena`) — no `defer` cleanup needed in the handler.

- [ ] **Step 2: Verify it compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/frontend_log_get.zig src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "feat(handlers): add frontend_log_get handler (logs table query)"
```

### Task 3.2: Tests for the GET handler

- [ ] **Step 1: Write static-contract tests**

File: `src/ai_workflow/tui/http_handlers/frontend_log_get_test.zig`. Tests:

1. `handler reads query params` — assert `req.query()` substring.
2. `handler uses valueAlloc for response` — assert `"valueAlloc"` substring (it's in the helper `makeFrontendLogListResponse`).
3. `handler ORDER BY created_at DESC` — assert `"ORDER BY created_at DESC"` substring.
4. `handler defaults limit to 100` — assert substring near `limit` default.
5. `handler caps limit at 1000` — assert `"1000"` substring.

- [ ] **Step 2: Write behavioral SQL tests**

Append to the same file. Use the `setupDb` pattern from `routines/scheduler_test.zig`:

```zig
test "GET query: recent-first ordering" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    try Migration063AddFrontendLogs.up(&db, alloc);

    // Insert 3 rows with increasing timestamps
    try db.exec(alloc, "INSERT INTO logs (id, created_at, level, kind, message, count) VALUES (?,?,?,?,?,1)", &.{ "a", 100, "error", "console_error", "oldest" });
    try db.exec(alloc, "INSERT INTO logs (id, created_at, level, kind, message, count) VALUES (?,?,?,?,?,1)", &.{ "b", 200, "error", "console_error", "middle" });
    try db.exec(alloc, "INSERT INTO logs (id, created_at, level, kind, message, count) VALUES (?,?,?,?,?,1)", &.{ "c", 300, "error", "console_error", "newest" });

    var rows = try db.query(alloc, "SELECT id FROM logs ORDER BY created_at DESC", &.{});
    defer rows.deinit();
    var order: [3][]const u8 = undefined;
    var i: usize = 0;
    while (try rows.next()) |row| : (i += 1) {
        defer row.deinit(alloc);
        order[i] = try alloc.dupe(u8, row.values[0]);
    }
    defer for (order) |s| alloc.free(s);
    try testing.expectEqualStrings("c", order[0]);
    try testing.expectEqualStrings("b", order[1]);
    try testing.expectEqualStrings("a", order[2]);
}

test "GET query: WHERE level = ? filter" {
    // ... insert 1 error + 1 warn + 1 info ...
    // SELECT WHERE level = 'error' → 1 row
}

test "GET query: WHERE created_at >= ? filter (since)" {
    // ... insert 3 rows at t=100, t=200, t=300 ...
    // SELECT WHERE created_at >= 200 → 2 rows
}

test "GET query: LIMIT clause respected" {
    // ... insert 5 rows ...
    // SELECT ... LIMIT 2 → 2 rows
}
```

- [ ] **Step 3: Register and run**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 9 new tests pass (5 static + 4 behavioral).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/frontend_log_get_test.zig src/ai_workflow/tui/http_handlers/test_runner.zig
git commit -m "test(handlers): tests for frontend_log_get (static + behavioral SQL)"
```

---

## Chunk 4: Backend — Router wiring

**Files:**
- Edit: `src/ai_workflow/tui/http_handlers/mod.zig`
- Edit: `src/main.zig`

### Task 4.1: Re-export handlers in `mod.zig`

- [ ] **Step 1: Add two re-export lines**

Find an empty line in `src/ai_workflow/tui/http_handlers/mod.zig` near the other handler re-exports (around line 169-170 where `notifyTestHandler` is). Add:

```zig
// Frontend error log endpoints (POST /api/logs for capture, GET /api/logs
// for retrieval). See docs/plans/2026-07-17-frontend-error-logs-design.md.
pub const frontendLogPostHandler = @import("frontend_log_post.zig").frontendLogPostHandler;
pub const frontendLogGetHandler = @import("frontend_log_get.zig").frontendLogGetHandler;
```

- [ ] **Step 2: Verify it compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`

### Task 4.2: Register routes in `main.zig`

- [ ] **Step 1: Add two route lines**

Find the `notify_test` route registration in `main.zig` (line ~345, where `try gs.router.post("/api/notify/test", ai_mod.http_handlers.notifyTestHandler);` is). Add immediately below:

```zig
// Frontend error log endpoints — capture unhandled JS exceptions,
// unhandled promise rejections, and existing console.error / console.warn
// calls from the nalar-desktop webapp. See
// docs/plans/2026-07-17-frontend-error-logs-design.md.
try gs.router.post("/api/logs", ai_mod.http_handlers.frontendLogPostHandler);
try gs.router.get("/api/logs", ai_mod.http_handlers.frontendLogGetHandler);
```

- [ ] **Step 2: Verify the build (test target + install target — see project memory `zig-build-catches-lazy-analysis-errors-test-misses`)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 10
```

All three must succeed (test, install:linux:system, full build). Per project memory `verification-before-completion`.

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/mod.zig src/main.zig
git commit -m "feat(http): register POST /api/logs and GET /api/logs routes"
```

### Task 4.3: Manual E2E smoke test (against `./zig-out/bin/nalar --port 8080`)

Per project memory's MANDATORY rule: use port 8080 for new work, NEVER port 8081.

- [ ] **Step 1: Build and start nalar on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs
timeout 180 zig build install:linux:system 2>&1 | tail -n 3
# (cp-to-/usr/local/bin will fail harmlessly)
./zig-out/bin/nalar --port 8080 &
SERVER_PID=$!
sleep 3
```

- [ ] **Step 2: POST a synthetic log entry**

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"level":"error","kind":"console_error","message":"smoke test","route_path":"/app"}' \
  http://127.0.0.1:8080/api/logs
echo " (expect: empty 204 response, exit 0)"
```

- [ ] **Step 3: GET it back**

```bash
curl -sS 'http://127.0.0.1:8080/api/logs?level=error&limit=5'
echo ""
# Expect: JSON with at least 1 row, message="smoke test"
```

- [ ] **Step 4: Verify validation errors**

```bash
curl -sS -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8080/api/logs
echo " (expect: 400 with 'missing required field: level' or similar)"
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"level":"BOGUS","kind":"console_error","message":"x"}' \
  http://127.0.0.1:8080/api/logs
echo " (expect: 400 with 'level must be one of: ...')"
```

- [ ] **Step 5: Stop the server**

```bash
kill $SERVER_PID
# NEVER pkill -f "nalar --port 8081" — that pattern catches the long-running prod nalar on 8081.
```

- [ ] **Step 6: Commit (no code changes — but document the smoke test in commit message of next commit)**

If anything needs adjustment from the smoke test, fix and amend. Otherwise continue.

---

## Chunk 5: Frontend — frontendLogClient.ts module

**Files:**
- Create: `src/apps/desktop/src/helpers/frontendLogClient.ts`

### Task 5.1: Module skeleton + types

- [ ] **Step 1: Write the file with types only (no implementations yet)**

File: `src/apps/desktop/src/helpers/frontendLogClient.ts`. Start with the type definitions and the `installFrontendLogClient` function signature. The body is a stub that does nothing for now.

```ts
// src/apps/desktop/src/helpers/frontendLogClient.ts
/**
 * frontendLogClient — capture unhandled JS exceptions, unhandled promise
 * rejections, and existing console.error / console.warn calls from the
 * nalar-desktop webapp. Forwards events to `POST /api/logs` so dev can
 * query them after a page reload via `curl` / `sqlite3`.
 *
 * Plan: docs/plans/2026-07-17-frontend-error-logs-design.md
 */

export type LogLevel = 'error' | 'warn' | 'info' | 'debug'
export type LogKind =
  | 'window_error'
  | 'unhandled_rejection'
  | 'console_error'
  | 'console_warn'

export interface LogEvent {
  level: LogLevel
  kind: LogKind
  message: string
  /** Present iff `kind === 'window_error'` and the event has a stack. */
  stack?: string
  /** Present iff `kind === 'window_error'` (file URL). */
  source?: string
  /** Present iff `kind === 'window_error'` (line number). */
  line?: number
  /** Vue Router path + query string. Set by App.vue via getContext(). */
  route_path?: string
  /** Active chat session_id. Set by App.vue via getContext(). */
  session_id?: string
}

export interface FrontendLogContext {
  /** Returns the current Vue route path (e.g. "/app?view=task"), or null at startup. */
  getRoutePath: () => string | null
  /** Returns the active chat session_id, or null. */
  getSessionId: () => string | null
}

export interface FrontendLogClientOptions {
  /** Full URL of the POST endpoint, e.g. "/api/logs". */
  endpoint: string
  /** Read at flush time to enrich events with current route/session. */
  getContext: () => FrontendLogContext
  /** Override for tests; defaults to window. */
  target?: Window
  /** Override fetch for tests; defaults to globalThis.fetch. */
  fetchFn?: typeof fetch
  /** Override sendBeacon for tests; defaults to navigator.sendBeacon. */
  sendBeaconFn?: (url: string, data: BodyInit) => boolean
}

export interface FrontendLogClientHandle {
  /** Detach all listeners + restore the original console.error/warn. */
  close(): void
}

const MAX_QUEUE_SIZE = 50
const MAX_QUEUE_DROP = 25
const DEBOUNCE_MS = 250

export function installFrontendLogClient(
  opts: FrontendLogClientOptions,
): FrontendLogClientHandle {
  // Stub for now — implementation lands in Task 5.2+.
  const close = (): void => {}
  return { close }
}
```

- [ ] **Step 2: Verify it type-checks**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 5`
Expected: build success (no errors, no warnings about unused params).

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/helpers/frontendLogClient.ts
git commit -m "feat(frontend): frontendLogClient types + install stub"
```

### Task 5.2: Implement window.error + unhandledrejection capture

- [ ] **Step 1: Replace the stub body with the two window listeners + the queue + flush + debounce**

Inside `installFrontendLogClient`, replace the stub with the real implementation. Use the existing `console.warn` for diagnostics (one warn per dropped batch on POST failure). The full implementation should be ~150 lines.

Key implementation points:
- `const queue: LogEvent[] = []`
- `let debounceTimer: ReturnType<typeof setTimeout> | null = null`
- `function enqueue(event: LogEvent): void { if (queue.length >= MAX_QUEUE_SIZE) { queue.splice(0, MAX_QUEUE_DROP); enqueue({ level: 'warn', kind: 'console_warn', message: '[frontendLog] queue overflow, dropped events' }); } queue.push(event); scheduleFlush(); }`
- `function scheduleFlush(): void { if (debounceTimer !== null) clearTimeout(debounceTimer); debounceTimer = setTimeout(() => { debounceTimer = null; void flush(); }, DEBOUNCE_MS); }`
- `async function flush(): Promise<void> { if (queue.length === 0) return; const batch = queue.splice(0, queue.length); const ctx = opts.getContext(); for (const event of batch) { if (ctx.getRoutePath() && !event.route_path) event.route_path = ctx.getRoutePath() ?? undefined; if (ctx.getSessionId() && !event.session_id) event.session_id = ctx.getSessionId() ?? undefined; } try { await opts.fetchFn?.(opts.endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ events: batch }) }); } catch (err) { console.warn('[frontendLog] POST failed, dropping batch', err); } }`
- `window.addEventListener('error', (e: ErrorEvent) => { const event: LogEvent = { level: 'error', kind: 'window_error', message: e.message || String(e.error) }; if (e.error instanceof Error) event.stack = e.error.stack; if (e.filename) event.source = e.filename; if (e.lineno) event.line = e.lineno; enqueue(event); })`
- `window.addEventListener('unhandledrejection', (e: PromiseRejectionEvent) => { const reason = e.reason; const event: LogEvent = { level: 'error', kind: 'unhandled_rejection', message: reason instanceof Error ? reason.message : String(reason) }; if (reason instanceof Error) event.stack = reason.stack; enqueue(event); })`

- [ ] **Step 2: Build to verify**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 10`
Expected: build success.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/helpers/frontendLogClient.ts
git commit -m "feat(frontend): window.error + unhandledrejection capture"
```

### Task 5.3: Implement console.error / console.warn monkey-patch + pagehide sendBeacon

- [ ] **Step 1: Add the monkey-patching inside `installFrontendLogClient` (before returning the handle)**

```ts
const originalError = target.console.error.bind(target.console)
const originalWarn = target.console.warn.bind(target.console)
target.console.error = (...args: unknown[]): void => {
  enqueue({ level: 'error', kind: 'console_error', message: formatArgs(args) })
  originalError(...args)
}
target.console.warn = (...args: unknown[]): void => {
  enqueue({ level: 'warn', kind: 'console_warn', message: formatArgs(args) })
  originalWarn(...args)
}
function formatArgs(args: unknown[]): string {
  return args.map(a => typeof a === 'string' ? a : (() => { try { return JSON.stringify(a) } catch { return String(a) } })()).join(' ')
}
```

- [ ] **Step 2: Add the pagehide handler**

```ts
function beaconFlush(): void {
  if (queue.length === 0) return
  const batch = queue.splice(0, queue.length)
  const ctx = opts.getContext()
  for (const event of batch) {
    if (ctx.getRoutePath() && !event.route_path) event.route_path = ctx.getRoutePath() ?? undefined
    if (ctx.getSessionId() && !event.session_id) event.session_id = ctx.getSessionId() ?? undefined
  }
  const blob = new Blob([JSON.stringify({ events: batch })], { type: 'application/json' })
  opts.sendBeaconFn?.(opts.endpoint, blob)
}
target.addEventListener('pagehide', beaconFlush)
target.addEventListener('beforeunload', beaconFlush)
```

Note: sendBeacon limits body to ~64KB. Our batch is bounded by MAX_QUEUE_SIZE = 50, so worst-case is ~50 × 1KB = 50KB. Safe.

- [ ] **Step 3: Implement the `close()` method properly**

```ts
const close = (): void => {
  target.removeEventListener('error', onError)
  target.removeEventListener('unhandledrejection', onUnhandledRejection)
  target.removeEventListener('pagehide', beaconFlush)
  target.removeEventListener('beforeunload', beaconFlush)
  target.console.error = originalError
  target.console.warn = originalWarn
  if (debounceTimer !== null) {
    clearTimeout(debounceTimer)
    debounceTimer = null
  }
  queue.length = 0
}
```

You need to hoist `onError` and `onUnhandledRejection` to named consts (not inline) so `close()` can remove them.

- [ ] **Step 4: Build + verify**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 10`
Expected: build success.

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/helpers/frontendLogClient.ts
git commit -m "feat(frontend): console monkey-patch + pagehide sendBeacon"
```

---

## Chunk 6: Frontend — Tests

**Files:**
- Create: `src/apps/desktop/src/__tests__/frontendLogClient.spec.ts`

### Task 6.1: Setup helpers + spy infrastructure

- [ ] **Step 1: Write the test file with a fakeWindow + fakeNavigator + fakeFetch helper**

```ts
// src/apps/desktop/src/__tests__/frontendLogClient.spec.ts
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest'
import { installFrontendLogClient, type FrontendLogClientHandle } from '../helpers/frontendLogClient'

interface FakeWindow {
  addEventListener: (type: string, cb: EventListenerOrEventListenerObject) => void
  removeEventListener: (type: string, cb: EventListenerOrEventListenerObject) => void
  console: { error: typeof console.error; warn: typeof console.warn; log: typeof console.log; info: typeof console.info; debug: typeof console.debug }
  dispatchEvent: (event: Event) => boolean
}

function makeFakeWindow(): { window: FakeWindow; errorListeners: Set<(e: Event) => void>; rejectionListeners: Set<(e: Event) => void>; unloadListeners: Set<(e: Event) => void> } {
  const errorListeners = new Set<(e: Event) => void>()
  const rejectionListeners = new Set<(e: Event) => void>()
  const unloadListeners = new Set<(e: Event) => void>()
  const console = { error: vi.fn(), warn: vi.fn(), log: vi.fn(), info: vi.fn(), debug: vi.fn() }
  const window: FakeWindow = {
    addEventListener: (type, cb) => {
      if (type === 'error') errorListeners.add(cb as (e: Event) => void)
      else if (type === 'unhandledrejection') rejectionListeners.add(cb as (e: Event) => void)
      else if (type === 'pagehide' || type === 'beforeunload') unloadListeners.add(cb as (e: Event) => void)
    },
    removeEventListener: (type, cb) => {
      if (type === 'error') errorListeners.delete(cb as (e: Event) => void)
      else if (type === 'unhandledrejection') rejectionListeners.delete(cb as (e: Event) => void)
      else if (type === 'pagehide' || type === 'beforeunload') unloadListeners.delete(cb as (e: Event) => void)
    },
    console,
    dispatchEvent: () => true,
  }
  return { window, errorListeners, rejectionListeners, unloadListeners }
}

describe('frontendLogClient', () => {
  let fetchMock: ReturnType<typeof vi.fn>
  let beaconMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.useFakeTimers()
    fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 204 })
    beaconMock = vi.fn().mockReturnValue(true)
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  function makeHandle(window: FakeWindow) {
    return installFrontendLogClient({
      endpoint: '/api/logs',
      getContext: () => ({ getRoutePath: () => '/app', getSessionId: () => 'session_xyz' }),
      target: window as unknown as Window,
      fetchFn: fetchMock as unknown as typeof fetch,
      sendBeaconFn: beaconMock,
    })
  }

  test('window.error → POST with kind=window_error, stack/source/line populated', async () => {
    const { window, errorListeners } = makeFakeWindow()
    const handle = makeHandle(window)
    try {
      const err = new Error('boom')
      const event = new ErrorEvent('error', { message: 'boom', error: err, filename: 'app.js', lineno: 42 })
      for (const cb of errorListeners) cb(event)
      await vi.runAllTimersAsync()
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const [, init] = fetchMock.mock.calls[0]
      const body = JSON.parse(init.body)
      expect(body.events).toHaveLength(1)
      expect(body.events[0].kind).toBe('window_error')
      expect(body.events[0].message).toBe('boom')
      expect(body.events[0].stack).toContain('boom')
      expect(body.events[0].source).toBe('app.js')
      expect(body.events[0].line).toBe(42)
    } finally {
      handle.close()
    }
  })

  // ... 9 more tests ...
})
```

The full test file will be ~250 lines. Tests 2-10 follow the same shape as Test 1, varying the assertion. Outline:

- Test 2: `unhandledrejection` → POST `kind: 'unhandled_rejection'`, message = `String(reason)`
- Test 3: `console.error` after monkey-patch → POST `kind: 'console_error'`; original `console.error` was still called (spy assertion)
- Test 4: `console.warn` → POST `kind: 'console_warn'`
- Test 5: `console.log/info/debug` → NOT POSTed (zero calls to `fetchMock`)
- Test 6: 100 fast `console.error` → exactly 1 POST (debounce coalesces them)
- Test 7: `pagehide` → `sendBeacon` called, NOT `fetch`
- Test 8: Failed POST (mock `fetch` rejects) → batch is dropped, no retry
- Test 9: Queue overflow → drops oldest 25, emits one overflow warn
- Test 10: `getContext()` callback is called for each flush → fresh route/session

- [ ] **Step 2: Run the tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop && timeout 120 bunx vitest run frontendLogClient 2>&1 | tail -n 20`
Expected: 10 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/__tests__/frontendLogClient.spec.ts
git commit -m "test(frontend): frontendLogClient capture + transport tests"
```

---

## Chunk 7: Frontend — Wire into main.ts + App.vue + E2E smoke

**Files:**
- Edit: `src/apps/desktop/src/main.ts`
- Edit: `src/apps/desktop/src/App.vue`

### Task 7.1: Install in main.ts + expose `logCtx` on window

- [ ] **Step 1: Edit `main.ts` to install the client before `app.mount('#app')`**

Add to `src/apps/desktop/src/main.ts`:

```ts
import { installFrontendLogClient, type FrontendLogContext } from './helpers/frontendLogClient'

// Install the frontend error-log client BEFORE app.mount so the global
// `window.error` / `unhandledrejection` / console.error / console.warn
// listeners are wired up before any component can throw. App.vue
// re-wires the context callbacks (route + session) once Vue router is
// alive. See docs/plans/2026-07-17-frontend-error-logs-design.md.
const logCtx: FrontendLogContext = {
  getRoutePath: () => null,
  getSessionId: () => null,
}
;(window as unknown as { __nalarLogCtx: FrontendLogContext }).__nalarLogCtx = logCtx
installFrontendLogClient({
  endpoint: `${API_BASE}/logs`,
  getContext: () => logCtx,
})
```

Add the import BEFORE `import App from './App.vue'`. Note: `API_BASE` is the constant already imported at the top of `main.ts` — use whatever alias the existing code uses (check `api/index.ts` for the export).

- [ ] **Step 2: Build to verify**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 10`
Expected: build success.

### Task 7.2: Wire context in App.vue

- [ ] **Step 1: Edit `App.vue` to refresh `logCtx.getRoutePath` and `logCtx.getSessionId` after mount**

Add to `src/apps/desktop/src/App.vue`'s `<script setup lang="ts">` block, after `import { installSseBus, useSseBus } from './helpers/sseBus'`:

```ts
import { useRoute } from 'vue-router'
import { useNavigationStore } from './stores/navigation'
```

Then, inside `onMounted` (after `installSseBus()`):

```ts
const route = useRoute()
const navigationStore = useNavigationStore()
const logCtx = (window as unknown as { __nalarLogCtx: { getRoutePath: () => string | null; getSessionId: () => string | null } }).__nalarLogCtx
if (logCtx) {
  logCtx.getRoutePath = () => `${route.path}${route.fullPath}`
  logCtx.getSessionId = () => navigationStore.activeChatId ?? null
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop && timeout 60 bun run build 2>&1 | tail -n 10`
Expected: build success.

- [ ] **Step 3: Run all frontend tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20`
Expected: all frontend tests pass (no regressions).

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/main.ts src/apps/desktop/src/App.vue
git commit -m "feat(frontend): install log client in main.ts, wire context in App.vue"
```

### Task 7.3: E2E smoke test in the running nalar-desktop

Per project memory `nalar-cross-platform-build-verification`: run a build, then a runtime smoke test on port 8080.

- [ ] **Step 1: Build the full nalar + nalar-desktop**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
# The cp at the end will fail (permission); the binary IS in zig-out/bin
ls -la zig-out/bin/nalar
```

- [ ] **Step 2: Start nalar on port 8080 + open the desktop app**

```bash
./zig-out/bin/nalar --port 8080 &
SERVER_PID=$!
sleep 3
# (Open the desktop webapp in a browser, OR open nalar-desktop pointing at port 8080)
```

If you have access to the desktop app: launch `./zig-out/bin/nalar-desktop --port 8080` (or set `--devtools` to see the network panel). Otherwise, open `http://127.0.0.1:8080/app?view=task&task=task_1784214389207` in a browser — the dev server reloads the built bundle from `$XDG_RUNTIME_DIR/nalar-desktop-webapp-<pid>/`.

- [ ] **Step 3: Trigger a real error in the desktop app**

Open the network panel. Trigger any `console.error` (e.g. navigate to a chat whose session_id is stale — the existing `[connectSse]` warns fire). Then trigger a `window.error` (e.g. via DevTools console: `throw new Error('smoke test from devtools')`).

- [ ] **Step 4: Verify the rows landed in the DB**

```bash
# Wait ~1s for the 250ms debounce to flush
sleep 1
curl -sS 'http://127.0.0.1:8080/api/logs?limit=5' | python3 -m json.tool
```

Expected: at least 1 row, with `kind: 'console_error'` or `kind: 'window_error'`, `route_path` populated by App.vue.

- [ ] **Step 5: Stop everything**

```bash
kill $SERVER_PID
```

- [ ] **Step 6: Commit (no code changes — document the E2E result in the next commit message)**

### Task 7.4: Final verification (test + install + full build)

Per project memory `verification-before-completion`:

- [ ] **Step 1: Run all three**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 10
```

All three must succeed. Test count must be baseline + 25 (3 migration + 13 POST + 9 GET) = baseline + 25.

- [ ] **Step 2: Run frontend test + build**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/frontend-error-logs/src/apps/desktop
timeout 60 bun run build 2>&1 | tail -n 5
timeout 120 bunx vitest run 2>&1 | tail -n 5
```

Both must succeed; frontend test count = baseline + 10.

- [ ] **Step 3: Final commit + tag (no code changes expected)**

If any adjustments surfaced from the smoke test, fix and commit. Otherwise, this is the final state — ready to merge.

---

## Notes

- **Avoid `std.log.err`** in handler error paths — use `std.log.warn` (per project memory `zig-0.16-test-log-err-count`).
- **DO use `parseFromSliceLeaky`** in the POST handler (per project memory `nalar-http-handler-thin-wrapper-pattern`).
- **Per-request arena** owns request-scoped allocations — no manual `defer ... .deinit()` for parsed body or rows (per project memory `custom-http-server-per-request-arena`).
- **DO NOT use `std.os.linux.*`** for anything cross-platform — use `std.c.*` (per project memory `zig-cross-platform-blockers-and-fixes`).
- **DO NOT add the new endpoint path as `/api/frontend-logs`** — keep it as `/api/logs` (matches the table name and is shorter; the `frontend_` prefix is in the table name only because SQLite needs uniqueness).
- **The plan reviewer subagent (see writing-plans skill "Plan Review Loop")** should be dispatched per chunk — if the human says "review this chunk" before moving on, dispatch the plan-document-reviewer subagent with the current chunk content.
- **Execute via `subagent-driven-development`** after this plan is approved (see writing-plans skill "Execution Handoff").
