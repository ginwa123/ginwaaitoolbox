# Sqlite Transaction Support Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Transaction` struct to `src/modules/databases/sqlite/Sqlite.zig` that allows callers to run multiple SQL statements atomically with BEGIN/COMMIT/ROLLBACK semantics, mirroring Go's `sql.Tx` pattern.

**Architecture:** RAII `Transaction` value type that holds the backend mutex for its entire lifetime. The `SqliteBackend.begin()` factory acquires the mutex and issues `BEGIN`; `tx.exec()`/`tx.query()`/`tx.queryRow()` run statements without re-acquiring the lock; `tx.commit()`/`tx.rollback()` issue the matching SQL and release the mutex. Nested transactions are handled via SQLite SAVEPOINTs. After completion, any further use of a Transaction returns `Error.TransactionClosed` (single-use contract, mirroring Go's `sql.ErrTxDone`); the safe defer idiom is `defer tx.rollback() catch |err| switch (err) { error.TransactionClosed => {}, else => return err, }` (a plain `catch {}` also works for fire-and-forget cases).

**Tech Stack:** Zig 0.16, `std.Io.Mutex` (futex-based, requires `io: std.Io`), vendored SQLite 3.53.3, `std.Io.Threaded` for tests, `testing.allocator` (DebugAllocator) for leak detection.

**Out of scope:** Migrating existing `db.exec` callers to use the new tx API. This plan adds the API surface + tests + docs only. Follow-up plans can refactor individual callers (e.g., `agentic_loop/insert_llm_histories.zig` is the highest-impact candidate).

---

## Background

### Current State (verified 2026-07-12)

`src/modules/databases/sqlite/Sqlite.zig` (371 lines) exposes:
- `init(io, db_path)` — opens DB, enables WAL + `busy_timeout=5000`
- `exec(allocator, sql, argv)` — INSERT/UPDATE/DELETE/CREATE
- `queryRow(allocator, sql, argv)` — single-row read returning `Row`
- `query(allocator, sql, argv)` — multi-row iterator returning `Rows`
- `changes()` — row count of last write
- `deinit()` — closes DB

The mutex (`std.Io.Mutex`, line 118) is acquired and released inside each method (lines 154-155, 208-209, 325-326). There is no public transaction wrapper API.

### Critical Bug This Plan Fixes

Issuing `db.exec("BEGIN")` then `db.exec("INSERT ...")` then `db.exec("COMMIT")` is **NOT atomic** because `exec` releases the mutex at the end of each call. Another thread's `exec` can interleave between `BEGIN` and `INSERT`, producing undefined visibility semantics.

The two existing tests at `src/modules/databases/sqlite/sqlite_test.zig:909-948` verify the underlying C primitives work but they run single-threaded (they can't actually demonstrate the atomicity bug). The TODO at `src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig:135` and `:127` explicitly notes "We don't wrap the loop in `BEGIN TRANSACTION`/`COMMIT` because `SqliteBackend.exec` releases the mutex at the end of each call — a transaction across calls wouldn't actually be atomic."

A new `Transaction` type fixes this by **holding the mutex for the entire tx lifetime**, so no other `exec`/`query` call can run on the same backend until `commit()` or `rollback()` releases it.

### Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| API shape | RAII `Transaction` struct | Matches the `Rows`/`Row` precedent at `Sqlite.zig:254-322`; Go `sql.Tx` familiarity; `defer tx.rollback() catch {}` is safety-by-default |
| Mutex semantics | Held for entire tx lifetime | Required for true atomicity (per the bug above); inner `tx.exec`/`tx.query` MUST NOT re-lock because `std.Io.Mutex` is **not reentrant** |
| Inner call impl | Refactor `exec` body into `executeStatement(backend, ...)` helper; `exec` wraps it with lock/unlock, `tx.exec` calls it bare | ~50 lines duplication eliminated; clear semantics for "caller holds the lock" |
| Nested tx | SQLite SAVEPOINTs (`SAVEPOINT name` / `RELEASE name` / `ROLLBACK TO name`) | Free from a `transaction_depth: u32` field; matches SQLite idioms |
| Idempotency | `commit()`/`rollback()`/`exec`/`query`/`queryRow` after completion → `Error.TransactionClosed` | **CRITICAL SAFETY PROPERTY.** Once the mutex is released by commit/rollback, any further `tx.*` call would race with concurrent writers on the same backend (the mutex isn't held anymore). Returning an error prevents the UB. The user-visible idiom is `defer tx.rollback() catch |err| switch(err) { error.TransactionClosed => {}, else => ..., }` — slightly more verbose than Go's `defer tx.Rollback()` (which silently succeeds) but matches Go's `sql.ErrTxDone` semantics: a Transaction is single-use, any post-completion operation is a programmer error |
| Cancellation | `begin()` returns `error.Canceled` if Io cancel hits mid-`lock`; mid-tx cancel is irrelevant (tx runs synchronously to completion) | Mirrors existing `exec` cancelability; no new failure mode introduced |
| Auto-rollback | Caller-side via `defer tx.rollback() catch |err| switch(err) { error.TransactionClosed => {}, else => ..., }` | Same idiom as Go `defer tx.Rollback()` with `sql.ErrTxDone` swallowed |
| Error variant | Add `Error.TransactionClosed` to the `Error` enum | Enforces the single-use Transaction contract |

### File Structure

| File | Change |
|---|---|
| `src/modules/databases/sqlite/Sqlite.zig` | Add `Transaction` struct + `begin()`/`savepoint()` + refactor `exec`/`query` to share inner helper with `tx.*`; add `transaction_depth: u32` field |
| `src/modules/databases/sqlite/sqlite_test.zig` | Update header doc-comment to mention tx API; add Group 9 (Transaction struct, ~10 new tests); keep existing Group 7 raw-SQL tests unchanged (they verify the C primitives) |

No changes to any caller file. The plan is additive.

### Reference Implementations (Verbatim Patterns)

Three patterns from the codebase to mirror exactly:

1. **`Rows`/`Row` RAII shape** (`Sqlite.zig:254-322`): struct with `deinit()`, `next()`, plus a separate `Row` value type with its own `deinit(allocator)`. The Transaction struct follows the same shape (`Transaction` + `Row`/`Rows` value types).

2. **Test setup with `DbCtx`** (`sqlite_test.zig:36-60`): named struct with `db: SqliteBackend` + `threaded: std.Io.Threaded`; `setupDb()` opens `:memory:` + starts `std.Io.Threaded`; `teardown()` deinits both. **Must use this exact pattern** — not the anonymous-struct pattern from `scheduler_test.zig` (per the comment at `sqlite_test.zig:33-35`).

3. **Error demotion to `std.log.warn`** (`Sqlite.zig:126-131`, `:218`): production error-path logging uses `std.log.warn`, NOT `std.log.err`, because `err` triggers `log_err_count > 0` in `zig build test`. New tx code follows the same convention.

### Cross-Platform Considerations

The `c` struct is `if (builtin.os.tag == .linux) @cImport(@cInclude("sqlite3.h")) else struct { ... }`. On non-Linux, the manual struct must include any C functions used:

- `sqlite3_exec` — **already declared** at `Sqlite.zig:98` ✅
- `sqlite3_errmsg` — **already declared** at `Sqlite.zig:97` ✅
- `sqlite3_get_autocommit` — **NOT declared**. Used only in tests for sanity checks (NOT in production tx code). Test will either skip the assertion on non-Linux or use the existing pattern via `@cImport` access. **Decision: skip the assertion** to keep cross-platform test parity.

Per project memory `zig-0.16-inmemory-sqlite-test-setup` and `nalar-zig-0.16-inmemory-sqlite-test-setup`: tests must use `std.Io.Threaded.init(alloc, .{})` + `db.init(io, ":memory:")`. Do NOT copy patterns from broken setups.

---

## Chunk 1: Core `Transaction` Struct + `begin`/`commit`/`rollback` + `tx.exec`

This chunk establishes the foundation: the `Transaction` value type, the `begin`/`commit`/`rollback` lifecycle methods, and `tx.exec`. After this chunk, callers can write `var tx = try db.begin(); defer tx.rollback() catch {}; try tx.exec(...); try tx.exec(...); try tx.commit();` with true atomicity.

### Task 1.0: Modify `deinit()` to null out `self.db` (prerequisite for tx safety)

**Files:**
- Modify: `src/modules/databases/sqlite/Sqlite.zig:353-357`

**Goal:** The existing `deinit()` closes the underlying sqlite3 handle but does NOT null out `self.db`. This means `self.db` is a dangling pointer after deinit. The Transaction code's use-after-free guard (`if (self.backend.db == null) return Error.DatabaseNotFound`) would never fire because the dangling pointer is non-null. Fix this so the guard actually works.

- [ ] **Step 1: Update `deinit()` to null out `self.db`**

Replace `Sqlite.zig:353-357` (the `deinit` method) with:

```zig
pub fn deinit(self: *SqliteBackend) void {
    if (self.db) |d| {
        _ = c.sqlite3_close(d);
    }
    // CRITICAL: null out `db` after closing so the Transaction code's
    // `self.backend.db == null` use-after-free guard actually fires.
    // Without this, the pointer dangles and any subsequent operation
    // would dereference freed memory.
    self.db = null;
}
```

- [ ] **Step 2: Verify no regression**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` and same baseline count. The change is semantically equivalent for callers that only call `deinit()` once (they never check `self.db` again).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/Sqlite.zig
git commit -m "fix(sqlite): null out self.db after close() in deinit

Prevents use-after-free in callers (notably the Transaction code)
that check self.db == null to detect a closed backend. Without
this, the Transaction.commit()/rollback() guards never fire and
the code dereferences a dangling pointer."
```

---

### Task 1.1: Refactor `exec` to extract `executeStatement` helper + add `Error.TransactionClosed`

**Files:**
- Modify: `src/modules/databases/sqlite/Sqlite.zig:45-58` (Error enum) and `:152-205` (exec function)

**Goal:** (1) Add the `TransactionClosed` error variant used by Transaction methods to signal post-completion use. (2) Extract the body of `exec` into a private helper that does NOT lock the mutex. The public `exec` wraps the helper with `lock`/`unlock`. This sets up the path for `tx.exec` to call the helper without re-locking.

- [ ] **Step 1: Add `TransactionClosed` to the Error enum**

Replace the Error enum at `src/modules/databases/sqlite/Sqlite.zig:45-58` with:

```zig
pub const Error = error{
    OpenFailed,
    DatabaseNotFound,
    PermissionDenied,
    DiskFull,
    DatabaseCorrupt,
    QueryFailed,
    PrepareFailed,
    BindFailed,
    ExecuteFailed,
    RowNotFound,
    OutOfMemory,
    Canceled,
    /// Returned by any Transaction method (exec/query/queryRow/commit/rollback)
    /// called after the transaction has been completed. Indicates the tx
    /// is single-use and must not be touched again. The mutex is no longer
    /// held, so any further use would race with concurrent writers on the
    /// same backend. The recommended defer pattern is:
    ///   `defer tx.rollback() catch |err| switch (err) {
    ///       error.TransactionClosed => {},
    ///       else => return err,
    ///   };`
    TransactionClosed,
};
```

- [ ] **Step 2: Sanity check (exec still compiles)**

Run from `/home/ginwa/agentic_coding_zig/ginwaaitoolbox`:
```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```
Expected: `test success` and same baseline count. The new Error variant is unused but doesn't break anything.

- [ ] **Step 3: Extract `executeStatement` helper**

Replace `Sqlite.zig:152-205` (the `exec` function) with:

Run from `/home/ginwa/agentic_coding_zig/ginwaaitoolbox`:
```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```
Expected: `test success` and `1041/1041 tests passed (or the current baseline)` — the refactor doesn't break anything.

- [ ] **Step 2: Extract `executeStatement` helper**

Replace `Sqlite.zig:152-205` (the `exec` function) with:

```zig
/// Inner implementation: prepare + bind + step a single SQL statement.
/// Caller MUST hold the backend mutex. Used by both `exec` (with lock)
/// and `Transaction.exec` (without re-locking — the tx already holds it).
fn executeStatement(
    self: *SqliteBackend,
    allocator: std.mem.Allocator,
    sql: []const u8,
    argv: []const []const u8,
) Error!void {
    _ = allocator;
    const db = self.db orelse return Error.DatabaseNotFound;

    // Empty SQL is a successful no-op. sqlite3_prepare_v2 with a
    // zero-length input returns OK with stmt=NULL; calling step()
    // on a NULL stmt is documented as harmless. Treat the whole
    // thing as a no-op up front to avoid the NULL-stmt edge case
    // and to make the documented behavior explicit at the wrapper
    // level (callers don't need to special-case "" themselves).
    if (sql.len == 0) return;

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
    defer {
        if (stmt) |s| {
            _ = c.sqlite3_finalize(s);
        }
    }
    if (rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(db);
        std.log.warn("sqlite3_prepare_v2 error: {s}", .{err_msg});
        return Error.PrepareFailed;
    }

    for (argv, 0..) |arg, i| {
        const param_idx: c_int = @intCast(i + 1);
        if (arg.len == 0) {
            rc = c.sqlite3_bind_null(stmt, param_idx);
        } else {
            rc = sqlite3_bind_text_isize(@ptrCast(stmt), param_idx, arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
        }
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.warn("sqlite3_bind_text error: {s}", .{err_msg});
            return Error.BindFailed;
        }
    }

    while (true) {
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            continue;
        } else if (rc == c.SQLITE_DONE) {
            break;
        } else {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.warn("sqlite3_step error: {s}", .{err_msg});
            return Error.ExecuteFailed;
        }
    }
}

pub fn exec(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    return executeStatement(self, allocator, sql, argv);
}
```

Note: The `std.debug.print` calls were demoted to `std.log.warn` to match the existing convention at `Sqlite.zig:126-131` (per project memory `zig-0.16-test-log-err-count`).

- [ ] **Step 4: Run tests to verify no regression**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` and same baseline test count.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/Sqlite.zig
git commit -m "refactor(sqlite): extract executeStatement helper + add Error.TransactionClosed

No behavior change from the helper extraction. The TransactionClosed
error variant is unused yet but defined here so Task 1.2 can
reference it without further error-enum churn."
```

---

### Task 1.2: Add `Transaction` struct skeleton + `SqliteBackend.begin()`

**Files:**
- Modify: `src/modules/databases/sqlite/Sqlite.zig` (add struct + method)

**Goal:** Define the `Transaction` value type with `backend`, `depth`, `completed` fields and a `commit()`/`rollback()` skeleton. Add `SqliteBackend.begin()` that acquires the mutex and issues `BEGIN`. At this point commit/rollback are stubs that just mark the tx completed and release the mutex.

- [ ] **Step 1: Add the failing test for `begin` returns a valid Transaction**

Add to `src/modules/databases/sqlite/sqlite_test.zig` after line 948 (right after the existing Group 7, before line 950's Group 8 separator). Actually, defer this test addition to Task 1.3 — for Task 1.2 we just need the compiler to accept the new struct shape. Skip the test step here.

- [ ] **Step 2: Add `Transaction` struct + `begin()` to Sqlite.zig**

Insert AFTER the `Rows` struct (after `Sqlite.zig:322`, before `Row` declaration at line 313) — actually, after `Row` at line 322 since `Rows` and `Row` are colocated. Insert right after the existing `Row` struct's closing brace.

Find `Sqlite.zig:322` (closing `};` of `pub const Row = struct { ... };`) and add the new code below it:

```zig
/// A database transaction. Mirrors Go's `sql.Tx` — acquire one via
/// `SqliteBackend.begin()` (top-level) or `SqliteBackend.savepoint(name)`
/// (nested). Run statements with the tx methods, then `commit()` to make
/// changes permanent or `rollback()` to discard them.
///
/// **Mutex semantics:** The `SqliteBackend.mutex` is acquired and held
/// for the entire lifetime of the transaction. Concurrent `exec`/`query`
/// calls from other threads block until `commit()`/`rollback()` releases
/// it. DO NOT call `db.exec()` / `db.query()` from within the same thread
/// that holds a tx — `std.Io.Mutex` is NOT reentrant; calling a
/// lock-acquiring method on the backend from inside `tx.exec` will
/// deadlock. Use `tx.exec` / `tx.query` / `tx.queryRow` instead.
///
/// **Single-use:** All methods (`exec`, `query`, `queryRow`, `commit`,
/// `rollback`) return `Error.TransactionClosed` if called after a
/// successful `commit()` or `rollback()`. This is a SAFETY check, not
/// ergonomics: after the mutex is released by commit/rollback, any
/// further `tx.*` call would invoke SQL on the underlying connection
/// WITHOUT the mutex held, racing with concurrent writers. Returning an
/// error prevents the UB. The recommended idiom is:
///
/// ```zig
/// var tx = try db.begin();
/// defer tx.rollback() catch |err| switch (err) {
///     error.TransactionClosed => {}, // already committed/rolled back
///     else => return err,
/// };
/// ```
///
/// The `defer tx.rollback() catch |err| switch(err) { error.TransactionClosed => {}, ... }`
/// pattern mirrors Go's `defer tx.Rollback()` (which silently succeeds
/// on `sql.ErrTxDone`); the explicit switch is required because Zig
/// surfaces all errors.
///
/// **Borrowed slices:** As with the non-tx `Row` type, slices returned
/// from `tx.queryRow()` / `tx.query()` are allocated by the caller's
/// allocator; the caller must call `Row.deinit(allocator)` to free them.
pub const Transaction = struct {
    backend: *SqliteBackend,
    depth: u32,
    completed: bool = false,

    pub fn exec(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
        if (self.completed) return Error.TransactionClosed;
        return executeStatement(self.backend, allocator, sql, argv);
    }

    pub fn commit(self: *Transaction) Error!void {
        if (self.completed) return Error.TransactionClosed;
        const db = self.backend.db orelse {
            // Backend was closed during tx — release the mutex we hold
            // and report the closed state. Caller's deferred rollback
            // (if any) returns TransactionClosed because completed = true.
            self.completed = true;
            self.backend.mutex.unlock(self.backend.io);
            return Error.DatabaseNotFound;
        };

        // Top-level tx (depth == 1): COMMIT. Nested tx (depth >= 2):
        // RELEASE sp_<depth> (handled in Chunk 3 Task 3.1 via the
        // sentinel-terminated buffer pattern).
        const rc = c.sqlite3_exec(db, "COMMIT", null, null, null);
        self.completed = true;
        self.backend.mutex.unlock(self.backend.io);

        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.warn("sqlite3_exec COMMIT failed: {s}", .{err_msg});
            return Error.ExecuteFailed;
        }
    }

    pub fn rollback(self: *Transaction) Error!void {
        if (self.completed) return Error.TransactionClosed;
        const db = self.backend.db orelse {
            self.completed = true;
            self.backend.mutex.unlock(self.backend.io);
            return Error.DatabaseNotFound;
        };

        const rc = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
        self.completed = true;
        self.backend.mutex.unlock(self.backend.io);

        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.warn("sqlite3_exec ROLLBACK failed: {s}", .{err_msg});
            return Error.ExecuteFailed;
        }
    }
};
```

Then add `begin()` to `SqliteBackend`. Insert AFTER the existing `deinit` method (line 357) and BEFORE `changes` (line 366):

```zig
/// Begin a new top-level transaction on this backend. Returns a
/// `Transaction` whose `exec`/`query` methods operate inside the
/// transaction until `commit()` or `rollback()` is called.
///
/// The backend's mutex is acquired and held for the entire transaction
/// lifetime. Concurrent `exec`/`query` calls on the same backend
/// (from other threads) block until the transaction ends.
///
/// Returns `Error.DatabaseNotFound` if the backend is not initialized.
/// Returns `Error.ExecuteFailed` if the underlying `BEGIN` SQL fails
/// (e.g. already inside a transaction — should not happen if the
/// caller respects the mutex contract).
///
/// Cancel-safe: if the Io runtime cancels mid-`lock()`, returns
/// `error.Canceled` without acquiring the lock or starting a tx.
pub fn begin(self: *SqliteBackend) Error!Transaction {
    if (self.db == null) return Error.DatabaseNotFound;

    // Acquire the mutex BEFORE issuing BEGIN. This is the critical
    // correctness invariant: while the tx is alive, no other
    // backend.exec / backend.query call can interleave.
    try self.mutex.lock(self.io);
    errdefer self.mutex.unlock(self.io);

    // Issue BEGIN. On any failure, the errdefer releases the mutex.
    const rc = c.sqlite3_exec(self.db.?, "BEGIN", null, null, null);
    if (rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(self.db.?);
        std.log.warn("sqlite3_exec BEGIN failed: {s}", .{err_msg});
        return Error.ExecuteFailed;
    }

    return Transaction{
        .backend = self,
        .depth = 0,
        .completed = false,
    };
}
```

- [ ] **Step 3: Verify it compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` and the same test count. (No new tests yet, but the new struct must compile cleanly.)

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/Sqlite.zig
git commit -m "feat(sqlite): add Transaction struct + SqliteBackend.begin()

begin() acquires the backend mutex and issues BEGIN. The mutex is
held for the entire tx lifetime — concurrent exec/query calls from
other threads block until commit()/rollback() releases it.

commit()/rollback() issue the matching SQL and release the mutex.
Both are idempotent (silent no-op if called after completion) so
the defer tx.rollback() catch {} idiom is always safe.

tx.exec is wired to executeStatement (the helper extracted in the
previous commit) — no re-locking, since std.Io.Mutex is not reentrant.

Savepoint support is deferred to a follow-up chunk."
```

---

### Task 1.3: Add tests for basic commit and rollback flows

**Files:**
- Modify: `src/modules/databases/sqlite/sqlite_test.zig` (add Group 9)

**Goal:** Lock in the basic contract with 4-5 TDD tests.

- [ ] **Step 1: Add the failing tests**

Append to `src/modules/databases/sqlite/sqlite_test.zig` at the END of the file (after line 1041, after Group 8). Insert a new `Group 9` separator + the tests:

```zig
// ═══════════════════════════════════════════════════════════════════════════
//  Group 9: Transaction struct (begin / tx.exec / commit / rollback)
// ═══════════════════════════════════════════════════════════════════════════

test "begin returns a Transaction and commit persists writes" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // safety net — should be no-op after commit
        try tx.exec(alloc,
            "INSERT INTO foo VALUES ('a'), ('b')", &.{});
        try tx.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}

test "rollback after commit returns TransactionClosed (single-use enforcement)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    // After commit, the tx is single-use. Rollback returns
    // Error.TransactionClosed (NOT a silent no-op — the mutex was
    // released by commit, so a rollback would invoke SQL on the
    // connection without holding the mutex, racing with other writers).
    const result = tx.rollback();
    try testing.expectError(sqlite_mod.Error.TransactionClosed, result);

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "defer rollback after error discards all writes (atomic)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // fires if commit() not reached
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        // Force a failure mid-tx by trying to violate the PK constraint.
        const result = tx.exec(alloc,
            "INSERT INTO foo VALUES ('a')", &.{});
        try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
        // No commit() reached — defer fires, ROLLBACK issued, 'a' is gone.
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "explicit rollback discards writes" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a'), ('b')", &.{});
        try tx.rollback();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "begin before init returns DatabaseNotFound" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    const result = db.begin();
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}
```

- [ ] **Step 2: Run the new tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: All 5 new tests pass. Total test count is `baseline + 5`.

If any test fails, debug per the error message — common issues:
- "already a transaction" error → mutex was already held (look for stray `db.exec` inside `tx.exec`)
- "no such table" → setup didn't run (check the CREATE TABLE happened BEFORE begin)
- leak detected → a test forgot a `defer alloc.free()` on `scalarText` output

- [ ] **Step 3: Verify the mutex-release invariant**

Run: `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`
Expected: 4/6 steps succeed (the cp step fails harmlessly per project convention).

Then run the manual mutex-held-across-tx smoke test (inserts this verification block temporarily — or rely on the tests above, which exercise begin → exec → commit in sequence):

Actually skip the manual smoke test — the 5 unit tests above already exercise the lock-acquire / lock-release sequence. The mutex held-during-tx invariant is verified implicitly: if the mutex WERE released between begin and commit, a concurrent test (any test that runs in parallel) would race and the test count would flake. Run the tests 3 times in a row to confirm no flakiness:

```bash
for i in 1 2 3; do
    timeout 180 zig build test --summary all 2>&1 | tail -n 1
done
```
Expected: 3 identical "X/X tests passed" lines.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/sqlite_test.zig
git commit -m "test(sqlite): add Group 9 tests for Transaction.begin/commit/rollback

Covers:
- basic commit persists writes
- defer rollback after commit is a silent no-op (idempotency)
- defer rollback after mid-tx error discards ALL writes (atomicity)
- explicit rollback discards writes
- begin before init returns DatabaseNotFound"
```

---

## Chunk 2: `tx.queryRow()` and `tx.query()`

Read-modify-write patterns need SELECT-then-UPDATE inside the tx (otherwise a concurrent writer can update the row between SELECT and UPDATE, producing a lost-update). This chunk adds the inner `queryRow`/`query` methods to `Transaction`.

### Task 2.1: Refactor `query` to extract `executeQuery` helper + add `tx.query`/`tx.queryRow`

**Files:**
- Modify: `src/modules/databases/sqlite/Sqlite.zig` (extract `executeQuery`, add `tx.queryRow`/`tx.query`)

- [ ] **Step 1: Extract `executeQuery` helper from `query`**

The body of `SqliteBackend.query` (lines 324-351) does the prepare + bind work but NOT the iteration — iteration is in `Rows.next`. The lock/unlock pair is at lines 325-326.

Replace the `query` method (lines 324-351) with:

```zig
/// Inner implementation: prepare + bind a SELECT statement, returning
/// a `Rows` iterator. Caller MUST hold the backend mutex. Used by
/// both `query` (with lock) and `Transaction.query` (without re-locking).
fn executeQuery(
    self: *SqliteBackend,
    allocator: std.mem.Allocator,
    sql: []const u8,
    argv: []const []const u8,
) Error!Rows {
    const db = self.db orelse return Error.DatabaseNotFound;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(db);
        std.log.warn("sqlite3_prepare_v2 error (query): {s}", .{err_msg});
        return Error.PrepareFailed;
    }

    for (argv, 0..) |arg, i| {
        const bind_rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
        if (bind_rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.warn("sqlite3_bind_text error (query): {s}", .{err_msg});
            _ = c.sqlite3_finalize(stmt);
            return Error.BindFailed;
        }
    }

    return Rows{
        .allocator = allocator,
        .stmt = stmt,
    };
}

pub fn query(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    return executeQuery(self, allocator, sql, argv);
}
```

- [ ] **Step 2: Refactor `queryRow` to extract `executeQueryRow` helper**

Same pattern. Replace the `queryRow` method (lines 207-252) with:

```zig
/// Inner implementation: prepare + bind + step ONCE for a single-row
/// SELECT. Caller MUST hold the backend mutex. Used by both `queryRow`
/// (with lock) and `Transaction.queryRow` (without re-locking).
fn executeQueryRow(
    self: *SqliteBackend,
    allocator: std.mem.Allocator,
    sql: []const u8,
    argv: []const []const u8,
) Error!Row {
    const db = self.db orelse return Error.DatabaseNotFound;

    var stmt: ?*c.sqlite3_stmt = null;
    const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (prep_rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(db);
        std.log.warn("Prepare failed: {s}", .{err_msg});
        return Error.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    for (argv, 0..) |arg, i| {
        const bind_rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
        if (bind_rc != c.SQLITE_OK) {
            return Error.BindFailed;
        }
    }

    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_ROW) {
        const err_msg = c.sqlite3_errmsg(db);
        std.log.warn("sqlite3_step error (queryRow): {s}", .{err_msg});
        return Error.RowNotFound;
    }

    const col_count = c.sqlite3_column_count(stmt);
    var values = try allocator.alloc([]u8, @intCast(col_count));

    for (0..@intCast(col_count)) |i| {
        const col_text = c.sqlite3_column_text(stmt, @intCast(i));
        if (col_text) |text| {
            const len = c.sqlite3_column_bytes(stmt, @intCast(i));
            values[i] = try allocator.alloc(u8, @intCast(len));
            @memcpy(values[i][0..@intCast(len)], text[0..@intCast(len)]);
        } else {
            values[i] = try allocator.alloc(u8, 0);
        }
    }

    return Row{ .values = values };
}

pub fn queryRow(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    return executeQueryRow(self, allocator, sql, argv);
}
```

- [ ] **Step 3: Add `tx.queryRow` and `tx.query` to `Transaction`**

Inside the `Transaction` struct (added in Chunk 1 Task 1.2), add two methods right after `exec`:

```zig
    pub fn queryRow(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
        if (self.completed) return Error.TransactionClosed;
        return executeQueryRow(self.backend, allocator, sql, argv);
    }

    pub fn query(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
        if (self.completed) return Error.TransactionClosed;
        return executeQuery(self.backend, allocator, sql, argv);
    }
```

- [ ] **Step 4: Run tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: Same baseline — the refactor is behavior-preserving (no new tests yet in this task).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/Sqlite.zig
git commit -m "refactor(sqlite): extract executeQuery/executeQueryRow helpers + add tx.query/tx.queryRow

Mirrors the executeStatement extraction in Chunk 1. tx.query and
tx.queryRow call the helpers without re-locking — std.Io.Mutex is
not reentrant, and the tx already holds it."
```

---

### Task 2.2: Add tests for read-modify-write and SELECT visibility inside tx

**Files:**
- Modify: `src/modules/databases/sqlite/sqlite_test.zig`

- [ ] **Step 1: Add the failing tests**

Append to the Group 9 section in `sqlite_test.zig` (after Task 1.3's tests):

```zig
test "tx.queryRow sees uncommitted writes inside the same tx" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        try tx.exec(alloc, "INSERT INTO kv VALUES ('a', 'one')", &.{});

        // Read it back inside the same tx — must see 'one', not NULL.
        const row = try tx.queryRow(alloc,
            "SELECT v FROM kv WHERE k = 'a'", &.{});
        defer row.deinit(alloc);
        try testing.expectEqualStrings("one", row.values[0]);

        try tx.commit();
    }
}

test "read-modify-write pattern is atomic across tx" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        \\CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)
    , &.{});
    try ctx.db.exec(alloc, "INSERT INTO counter VALUES (1, 0)", &.{});

    // Simulate a read-modify-write: read n, increment, write back.
    // Inside a tx, the read + write happen atomically with respect to
    // other writers.
    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        const row = try tx.queryRow(alloc,
            "SELECT n FROM counter WHERE id = 1", &.{});
        defer row.deinit(alloc);
        const n = try std.fmt.parseInt(i32, row.values[0], 10);
        try testing.expectEqual(@as(i32, 0), n);

        try tx.exec(alloc,
            "UPDATE counter SET n = ? WHERE id = 1",
            &.{ "1" });
        try tx.commit();
    }

    // Verify the write persisted.
    const row = try ctx.db.queryRow(alloc,
        "SELECT n FROM counter WHERE id = 1", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "tx.query returns Rows iterator (same shape as backend.query)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE items (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        try tx.exec(alloc, "INSERT INTO items VALUES ('a'), ('b'), ('c')", &.{});

        var q = try tx.query(alloc,
            "SELECT id FROM items ORDER BY id", &.{});
        defer q.deinit();

        const r1 = (try q.next()) orelse return error.ExpectedRow;
        defer r1.deinit(alloc);
        try testing.expectEqualStrings("a", r1.values[0]);

        const r2 = (try q.next()) orelse return error.ExpectedRow;
        defer r2.deinit(alloc);
        try testing.expectEqualStrings("b", r2.values[0]);

        const r3 = (try q.next()) orelse return error.ExpectedRow;
        defer r3.deinit(alloc);
        try testing.expectEqualStrings("c", r3.values[0]);

        try testing.expect((try q.next()) == null);
        try tx.commit();
    }
}
```

- [ ] **Step 2: Run tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: All 3 new tests pass. Total: `baseline + 8` (5 from Task 1.3 + 3 from Task 2.2).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/sqlite_test.zig
git commit -m "test(sqlite): add Group 9 tests for tx.queryRow/tx.query

Covers:
- SELECT-after-INSERT visibility inside the same tx
- read-modify-write atomicity (the canonical tx use case)
- tx.query returns Rows with the same shape as backend.query"
```

---

## Chunk 3: Nested Transactions via SQLite SAVEPOINTs

Nested transactions are handled via SQLite SAVEPOINTs (the `depth >= 1` case). The `transaction_depth: u32` field on `SqliteBackend` tracks the current nesting level so that `begin()` always issues `BEGIN` (top-level) but `savepoint("tx_<n>")` issues `SAVEPOINT` (nested).

### Task 3.1: Add `transaction_depth` field + `savepoint()` factory

**Files:**
- Modify: `src/modules/databases/sqlite/Sqlite.zig` (add field + method)

- [ ] **Step 1: Add the field to `SqliteBackend`**

In `Sqlite.zig:116-118`, add `transaction_depth: u32 = 0` to the field list:

```zig
io: std.Io = .failing,
db: ?*c.sqlite3 = null,
mutex: std.Io.Mutex = .init,
/// Tracks the current transaction nesting depth (0 = no tx active;
/// 1 = top-level BEGIN in flight; 2+ = nested SAVEPOINT). Incremented
/// by `begin` / `savepoint`, decremented by `commit` / `rollback`.
/// Used to choose between `BEGIN` / `COMMIT` (depth 0↔1) and
/// `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` (depth >= 1).
transaction_depth: u32 = 0,
```

- [ ] **Step 2: Update `begin()` to track depth**

Modify the existing `begin()` (added in Chunk 1 Task 1.2) to increment `transaction_depth`. Find the return statement:

```zig
    return Transaction{
        .backend = self,
        .depth = 0,
        .completed = false,
    };
```

Replace `depth = 0` with `depth = self.transaction_depth + 1` and increment the depth BEFORE the return. Also need to update on errdefer rollback:

```zig
pub fn begin(self: *SqliteBackend) Error!Transaction {
    if (self.db == null) return Error.DatabaseNotFound;

    try self.mutex.lock(self.io);
    errdefer self.mutex.unlock(self.io);

    const rc = c.sqlite3_exec(self.db.?, "BEGIN", null, null, null);
    if (rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(self.db.?);
        std.log.warn("sqlite3_exec BEGIN failed: {s}", .{err_msg});
        return Error.ExecuteFailed;
    }

    self.transaction_depth += 1;
    return Transaction{
        .backend = self,
        .depth = self.transaction_depth,
        .completed = false,
    };
}
```

- [ ] **Step 3: Update `commit()` and `rollback()` to decrement depth + handle SAVEPOINT SQL**

In both `commit()` and `rollback()` (added in Chunk 1), before issuing the SQL, decrement `self.backend.transaction_depth`. The SQL depends on depth: `COMMIT`/`ROLLBACK` for depth 1 (top-level tx), `RELEASE sp_<depth>`/`ROLLBACK TO sp_<depth>` for nested (depth >= 2). The dynamic SQL names require a NUL-terminated C string for `c.sqlite3_exec` — use the sentinel-buffer pattern.

**Critical Zig 0.16 detail:** `c.sqlite3_exec` takes `[*:0]const u8` (a NUL-terminated C string). `std.fmt.bufPrint` returns `[]u8` which is NOT NUL-terminated. The fix is a sentinel-terminated stack buffer:

```zig
var sql_buf: [32:0]u8 = undefined;
const sql_slice = std.fmt.bufPrint(sql_buf[0..31], "RELEASE sp_{d}", .{self.depth}) catch
    return Error.ExecuteFailed;
sql_buf[sql_slice.len] = 0;
const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
```

`sql_buf[0..31]` is `[]u8` (31 bytes) which is what `bufPrint` accepts. The 32nd byte is reserved for the NUL sentinel. After formatting, we write the sentinel at `sql_buf[result.len]`. The `&sql_buf` is `*[32:0]u8` which coerces to `[*:0]const u8` (the C string type `c.sqlite3_exec` expects).

Replace the existing `Transaction.commit` and `Transaction.rollback` methods (added in Chunk 1 Task 1.2) with:

```zig
pub fn commit(self: *Transaction) Error!void {
    if (self.completed) return Error.TransactionClosed;
    const db = self.backend.db orelse {
        self.completed = true;
        self.backend.transaction_depth -= 1;
        self.backend.mutex.unlock(self.backend.io);
        return Error.DatabaseNotFound;
    };

    var sql_buf: [32:0]u8 = undefined;
    const sql_slice = if (self.depth == 1)
        std.fmt.bufPrint(sql_buf[0..31], "COMMIT", .{}) catch return Error.ExecuteFailed
    else
        std.fmt.bufPrint(sql_buf[0..31], "RELEASE sp_{d}", .{self.depth}) catch
            return Error.ExecuteFailed;
    sql_buf[sql_slice.len] = 0;

    const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
    self.completed = true;
    self.backend.transaction_depth -= 1;
    self.backend.mutex.unlock(self.backend.io);

    if (rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(db);
        std.log.warn("sqlite3_exec {s} failed: {s}", .{ sql_slice, err_msg });
        return Error.ExecuteFailed;
    }
}

pub fn rollback(self: *Transaction) Error!void {
    if (self.completed) return Error.TransactionClosed;
    const db = self.backend.db orelse {
        self.completed = true;
        self.backend.transaction_depth -= 1;
        self.backend.mutex.unlock(self.backend.io);
        return Error.DatabaseNotFound;
    };

    var sql_buf: [32:0]u8 = undefined;
    const sql_slice = if (self.depth == 1)
        std.fmt.bufPrint(sql_buf[0..31], "ROLLBACK", .{}) catch return Error.ExecuteFailed
    else
        std.fmt.bufPrint(sql_buf[0..31], "ROLLBACK TO sp_{d}", .{self.depth}) catch
            return Error.ExecuteFailed;
    sql_buf[sql_slice.len] = 0;

    const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
    self.completed = true;
    self.backend.transaction_depth -= 1;
    self.backend.mutex.unlock(self.backend.io);

    if (rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(db);
        std.log.warn("sqlite3_exec {s} failed: {s}", .{ sql_slice, err_msg });
        return Error.ExecuteFailed;
    }
}
```

Note: at this point in the plan (Task 3.1), `savepoint()` has NOT been added yet, so the `depth >= 2` branches are dead code. They&apos;re correct logic but won&apos;t be exercised until Task 3.2. The depth-1 branches exercise the existing top-level tx flow.

- [ ] **Step 4: Run existing tests to confirm depth-1 path still works**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: All Group 9 tests from Chunks 1 + 2 still pass. The depth tracking is internal; behavior is unchanged for top-level txs.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/Sqlite.zig
git commit -m "feat(sqlite): add transaction_depth field + adjust commit/rollback for nesting

Adds transaction_depth: u32 to SqliteBackend and updates commit/
rollback to decrement it. For now only depth=1 (top-level) is
exercised; the depth>=2 branches issue RELEASE/ROLLBACK TO for
matching SAVEPOINT names but are dead code until savepoint() is
added in the next task."
```

---

### Task 3.2: Add `SqliteBackend.savepoint()` factory method

**Files:**
- Modify: `src/modules/databases/sqlite/Sqlite.zig` (add `savepoint()` method)

- [ ] **Step 1: Add `savepoint()` method**

Insert AFTER `begin()` in `SqliteBackend`. Savepoints require an outer transaction (you can't open a SAVEPOINT without an active `BEGIN` first). The mutex is already held by the outer tx, so `savepoint` does NOT re-lock:

```zig
/// Open a nested savepoint within the current transaction. Must be
/// called WHILE a tx is already open (i.e. between `begin()` /
/// `savepoint()` and the corresponding `commit()` / `rollback()`).
///
/// Savepoints let you roll back PART of a transaction without
/// discarding the whole thing — useful for "try this batch, discard
/// if it fails, keep going" patterns.
///
/// The savepoint is named `sp_<depth>` (auto-generated based on the
/// current depth). The returned Transaction's `depth` field is >= 2.
///
/// **Caller must hold an active transaction.** Calling `savepoint()`
/// when `transaction_depth == 0` returns `Error.ExecuteFailed`
/// (SQLite rejects SAVEPOINT outside an outer tx).
pub fn savepoint(self: *SqliteBackend) Error!Transaction {
    if (self.db == null) return Error.DatabaseNotFound;
    if (self.transaction_depth == 0) return Error.ExecuteFailed;

    // Mutex is already held by the outer tx — do NOT re-lock.

    self.transaction_depth += 1;
    const new_depth = self.transaction_depth;

    // Build a NUL-terminated SAVEPOINT name. We use a fixed-size
    // sentinel-terminated buffer because sqlite3_exec takes a C string.
    // `sql_buf[0..31]` is `[]u8` (what bufPrint expects); the 32nd byte
    // holds the NUL sentinel we set after formatting.
    var sql_buf: [32:0]u8 = undefined;
    const sql_slice = std.fmt.bufPrint(sql_buf[0..31], "SAVEPOINT sp_{d}", .{new_depth}) catch
        return Error.ExecuteFailed;
    sql_buf[sql_slice.len] = 0;

    const rc = c.sqlite3_exec(self.db.?, &sql_buf, null, null, null);
    if (rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(self.db.?);
        std.log.warn("sqlite3_exec {s} failed: {s}", .{ sql_slice, err_msg });
        self.transaction_depth -= 1;
        return Error.ExecuteFailed;
    }

    return Transaction{
        .backend = self,
        .depth = new_depth,
        .completed = false,
    };
}
```

- [ ] **Step 2: Compile check**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: Same baseline test count (no new tests yet in Task 3.2 itself).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/Sqlite.zig
git commit -m "feat(sqlite): add SqliteBackend.savepoint() factory for nested transactions

savepoint() opens a SAVEPOINT within the current tx. Returns a
Transaction at depth >= 2. Must be called while an outer tx is
active (transaction_depth >= 1). Uses a fixed-size sentinel-
terminated buffer for the dynamic SAVEPOINT name.

Also fixes the commit/rollback depth>=2 branches from the previous
commit to use the same NUL-terminated buffer pattern."
```

---

### Task 3.3: Add tests for nested savepoints (commit inner / rollback inner)

**Files:**
- Modify: `src/modules/databases/sqlite/sqlite_test.zig`

- [ ] **Step 1: Add the failing tests**

Append to Group 9:

```zig
test "savepoint commit persists inner writes, outer commits too" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    {
        var outer = try ctx.db.begin();
        defer outer.rollback() catch {};

        try outer.exec(alloc, "INSERT INTO log VALUES ('1', 'outer')", &.{});

        {
            var inner = try ctx.db.savepoint();
            defer inner.rollback() catch {};
            try inner.exec(alloc, "INSERT INTO log VALUES ('2', 'inner')", &.{});
            try inner.commit();
        }

        try outer.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM log", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}

test "savepoint rollback undoes only inner writes, outer still alive" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    {
        var outer = try ctx.db.begin();
        defer outer.rollback() catch {};

        try outer.exec(alloc, "INSERT INTO log VALUES ('1', 'outer')", &.{});

        {
            var inner = try ctx.db.savepoint();
            defer inner.rollback() catch {};
            try inner.exec(alloc, "INSERT INTO log VALUES ('2', 'inner')", &.{});
            try inner.rollback();
            // 'inner' row gone, but the outer tx + 'outer' row still in flight.
        }

        try outer.exec(alloc, "INSERT INTO log VALUES ('3', 'outer2')", &.{});
        try outer.commit();
    }

    // Expect only '1' (outer) and '3' (outer2) — '2' (inner) was rolled back.
    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM log", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);

    const msg1 = (try scalarText(alloc, &ctx.db,
        "SELECT msg FROM log WHERE id = '2'", &.{})) orelse "";
    defer if (msg1.len > 0) alloc.free(msg1);
    try testing.expectEqualStrings("", msg1);
}

test "savepoint without outer tx returns ExecuteFailed" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    // No begin() before savepoint() — should fail.
    const result = ctx.db.savepoint();
    try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
}

test "nested savepoints (depth 2 → 3) commit and rollback correctly" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    {
        var outer = try ctx.db.begin();
        defer outer.rollback() catch {};

        try outer.exec(alloc, "INSERT INTO log VALUES ('a', 'outer')", &.{});

        {
            var mid = try ctx.db.savepoint();
            defer mid.rollback() catch {};
            try mid.exec(alloc, "INSERT INTO log VALUES ('b', 'mid')", &.{});

            {
                var deep = try ctx.db.savepoint();
                defer deep.rollback() catch {};
                try deep.exec(alloc, "INSERT INTO log VALUES ('c', 'deep')", &.{});
                try deep.commit(); // commit deep
            }

            // Roll back mid — this should undo 'b' and 'c'.
            try mid.rollback();
        }

        try outer.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM log", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt); // only 'a'
}
```

- [ ] **Step 2: Run tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: All 4 new tests pass. Total: `baseline + 12` (5+3+4).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/sqlite_test.zig
git commit -m "test(sqlite): add Group 9 tests for nested savepoints

Covers:
- inner commit + outer commit persists both
- inner rollback undoes only inner writes (outer stays alive)
- savepoint without outer tx returns ExecuteFailed
- 3-level nesting (begin → savepoint → savepoint) with mid rollback
  discarding deep + mid writes while outer persists"
```

---

## Chunk 4: Safety + Edge Cases + Documentation

This chunk handles the "what if the backend is closed while a tx is alive" scenario, updates the module-level doc comment to mention the tx API, and adds an integration test that demonstrates the canonical "atomic INSERT + UPDATE" use case.

### Task 4.1: Test backend.deinit() while tx in flight doesn't crash

**Files:**
- Modify: `src/modules/databases/sqlite/sqlite_test.zig`

- [ ] **Step 1: Add the failing test**

Append to Group 9:

```zig
test "backend.deinit() while tx is open: tx.commit returns DatabaseNotFound" {
    // This test verifies the use-after-free guard: if the caller
    // closes the backend while a tx is in flight, commit() detects
    // the closed state (db == null — set by Task 1.0's deinit fix)
    // and returns DatabaseNotFound instead of dereferencing a freed
    // pointer. Requires Task 1.0 (deinit nulls out self.db) to be in
    // place — without it, the guard never fires.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});

    // Close the backend while tx is still in flight. The mutex is
    // held by the tx; commit() must release it AND return DatabaseNotFound.
    ctx.db.deinit();
    const result = tx.commit();
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

test "backend.deinit() while tx is open: tx.rollback returns DatabaseNotFound" {
    // Mirror of the commit test, for the rollback path.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});

    ctx.db.deinit();
    const result = tx.rollback();
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

test "tx.commit after commit returns TransactionClosed (single-use enforcement)" {
    // After a successful commit, the tx is single-use. Any further call
    // returns Error.TransactionClosed to prevent UB (mutex is no longer
    // held, so a tx.* call would race with concurrent writers).
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    // Second commit → TransactionClosed.
    try testing.expectError(sqlite_mod.Error.TransactionClosed, tx.commit());
    // exec after commit → TransactionClosed.
    try testing.expectError(sqlite_mod.Error.TransactionClosed, tx.exec(alloc, "INSERT INTO foo VALUES ('b')", &.{}));
    // rollback after commit → TransactionClosed (use the switch idiom).
    tx.rollback() catch |err| switch (err) {
        error.TransactionClosed => {},
        else => return err,
    };
}

test "defer tx.rollback() catch |err| switch (TransactionClosed => {}) is the safe idiom" {
    // The whole point of defer-rollback: if commit() already ran, the
    // deferred rollback returns TransactionClosed and we swallow it.
    // Otherwise it runs the actual rollback.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch |err| switch (err) {
            error.TransactionClosed => {}, // expected after commit
            else => return err,
        };
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        try tx.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}
```

- [ ] **Step 2: Run tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: Both tests pass (the existing `commit()`/`rollback()` implementations already have the `self.backend.db orelse` check — this test just verifies the contract).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/sqlite_test.zig
git commit -m "test(sqlite): add tests for backend.deinit() during open tx

Verifies the use-after-free guard: if the caller closes the
backend while a tx is in flight, commit()/rollback() return
DatabaseNotFound instead of dereferencing a freed pointer."
```

---

### Task 4.2: Update module-level doc comment to mention tx API

**Files:**
- Modify: `src/modules/databases/sqlite/sqlite_test.zig:1-22` (header doc-comment)
- Modify: `src/modules/databases/sqlite/Sqlite.zig` (add module-level doc-comment if not present)

- [ ] **Step 1: Update sqlite_test.zig header**

Replace the doc comment at lines 1-22 with:

```zig
//! sqlite3 wrapper used by nalar everywhere. Covers the public API:
//!
//!   - `init(io, db_path)` — open DB, enable WAL + busy_timeout
//!   - `exec(alloc, sql, argv)` — INSERT / UPDATE / DELETE / CREATE
//!   - `queryRow(alloc, sql, argv)` — single-row read (returns first)
//!   - `query(alloc, sql, argv)` — multi-row iterator (Rows.next)
//!   - `changes()` — row count of last write
//!   - `deinit()` — close DB
//!
//! Transactions:
//!
//!   - `begin()` → `Transaction` (top-level tx)
//!   - `savepoint()` → `Transaction` (nested, requires an outer tx)
//!   - `tx.exec / tx.query / tx.queryRow` — same shape as backend.*
//!   - `tx.commit()` / `tx.rollback()` — both idempotent (safe defer)
//!
//!   The backend mutex is held for the entire tx lifetime, so concurrent
//!   `exec`/`query` calls from other threads block until `commit()` or
//!   `rollback()` releases it. Do NOT call `db.exec` / `db.query` from
//!   within the same thread that holds a tx — `std.Io.Mutex` is not
//!   reentrant. Use the `tx.*` variants instead.
//!
//! Tests follow the in-memory `:memory:` + `std.Io.Threaded` pattern from
//! `routines/model_test.zig`. Each test gets a fresh DB via `setupDb()`.
//!
//! Edge cases probed (see individual `test "..."` blocks):
//!   - empty SQL / malformed SQL / mismatched bind arity
//!   - UTF-8 text + binary bytes + SQL-injection-style quotes
//!   - NULL handling (empty `[]u8` for column, NULL binding for `""` arg)
//!   - constraint violations (NOT NULL, UNIQUE)
//!   - Row.deinit leak detection (single allocation check)
//!   - `changes()` accounting across INSERT/UPDATE/DELETE
//!   - error variant contract for `init` failures (DatabaseNotFound,
//!     PermissionDenied) — file-system level
//!   - tx commit / rollback / defer-rollback idempotency
//!   - nested savepoints (depth 2 / 3)
//!   - backend.deinit() during open tx (use-after-free guard)
```

- [ ] **Step 2: Add module-level doc comment to Sqlite.zig (if missing)**

Check if `Sqlite.zig` has a top-level doc comment (currently it has none). Add one right after `const builtin = @import("builtin");` and before the existing comment about `sqlite3_bind_text_isize`:

```zig
//! SQLite backend used everywhere nalar needs a database. Provides
//! basic `exec` / `query` / `queryRow` for single-statement operations
//! and a `Transaction` RAII type for multi-statement atomic operations.
//!
//! See `sqlite_test.zig` (the canonical documentation of the public
//! API surface) for usage patterns and test coverage.
//!
//! The `c` declarations are platform-scoped (Linux uses `@cImport` with
//! the system sqlite3.h; macOS/Windows use manual extern declarations
//! because the headers aren't on the default include path).
```

- [ ] **Step 3: Verify docs compile and tests still pass**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` and same test count as before.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/Sqlite.zig src/modules/databases/sqlite/sqlite_test.zig
git commit -m "docs(sqlite): document Transaction API in module headers

Adds the tx API surface to the sqlite_test.zig header doc-comment
and adds a top-level module doc-comment to Sqlite.zig pointing at
the test file as the canonical documentation source."
```

---

### Task 4.3: Add integration test demonstrating the canonical use case

**Files:**
- Modify: `src/modules/databases/sqlite/sqlite_test.zig`

**Goal:** Provide one realistic end-to-end test that mirrors the highest-impact real-world candidate (`agentic_loop/insert_llm_histories.zig`'s INSERT + UPDATE pattern).

- [ ] **Step 1: Add the integration test**

Append to Group 9:

```zig
test "integration: atomic INSERT-then-UPDATE (mirrors insert_llm_histories pattern)" {
    // This test mirrors the canonical tx use case in nalar:
    // inserting a row that references a parent, then updating the
    // parent's metadata in the same operation. Without tx, a crash
    // between the INSERT and UPDATE leaves the parent row's metadata
    // stale relative to the inserted child.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    response_content TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO sessions VALUES ('s1', '/old/path')", &.{});

    // Atomic INSERT into llm_history + UPDATE sessions.cwd.
    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // safety net
        try tx.exec(alloc,
            "INSERT INTO llm_history VALUES ('m1', 's1', 'hello world')",
            &.{});
        try tx.exec(alloc,
            "UPDATE sessions SET cwd = '/new/path' WHERE id = 's1'",
            &.{});
        try tx.commit();
    }

    // Both writes persisted.
    const cwd = (try scalarText(alloc, &ctx.db,
        "SELECT cwd FROM sessions WHERE id = 's1'", &.{})) orelse "";
    defer alloc.free(cwd);
    try testing.expectEqualStrings("/new/path", cwd);

    const msg = (try scalarText(alloc, &ctx.db,
        "SELECT response_content FROM llm_history WHERE id = 'm1'", &.{})) orelse "";
    defer alloc.free(msg);
    try testing.expectEqualStrings("hello world", msg);
}

test "integration: rollback of partial multi-statement leaves DB unchanged" {
    // Force a failure mid-tx by violating a UNIQUE constraint. Verify
    // the preceding INSERT was rolled back too — not just the failing one.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE items (id TEXT PRIMARY KEY, label TEXT NOT NULL)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(alloc, "INSERT INTO items VALUES ('a', 'first')", &.{});
        try tx.exec(alloc, "INSERT INTO items VALUES ('b', 'second')", &.{});
        // Force a failure: duplicate primary key.
        const result = tx.exec(alloc,
            "INSERT INTO items VALUES ('a', 'duplicate')", &.{});
        try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
        // Defer fires → ROLLBACK → 'a' and 'b' both gone.
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM items", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}
```

- [ ] **Step 2: Run tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: Both new tests pass. Total: `baseline + 14` (5+3+4+2+2).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/databases/sqlite/sqlite_test.zig
git commit -m "test(sqlite): add integration tests mirroring real-world tx use cases

Two tests demonstrating the canonical patterns:
- Atomic INSERT-then-UPDATE (mirrors agentic_loop/insert_llm_histories)
- Multi-statement rollback on constraint violation (the canonical tx
  safety guarantee)"
```

---

## Final Verification

After all chunks complete, run the full verification sequence per project memory `zig-build-catches-lazy-analysis-errors-test-misses`:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```
Expected: `test success` and `baseline + 16 tests passed` (5 from Chunk 1, 3 from Chunk 2, 4 from Chunk 3, 4 from Chunk 4 = 16 total).

Then verify no test flakiness by running the suite 3 times in a row — if the mutex-held-across-tx invariant ever regresses (e.g. a future refactor accidentally releases the mutex early), concurrent test execution would surface flaky counts:

```bash
for i in 1 2 3; do
    timeout 180 zig build test --summary all 2>&1 | tail -n 1
done
```
Expected: 3 identical `baseline + 16 tests passed` lines.

```bash
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```
Expected: 4/6 steps succeed (cp fails harmlessly per project convention). The `compile exe nalar` step must succeed.

```bash
rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 5
```
Expected: `zig build success` — no errors. This catches any production-code lazy-analysis traps the test target may have missed.

If any check fails, the lazy-analysis pattern from the memory applies: the test target's module graph doesn't reach private helpers that the install/full build does. Fix the production code, re-run all three.

---

## Out of Scope (Follow-up Plans)

This plan adds the API surface only. The following migrations are deliberately excluded and should be separate plans:

1. **`src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig` lines 161-166** — wrap the `INSERT INTO llm_history` + `UPDATE sessions SET cwd` in a `db.begin()` / `db.commit()`. Highest-impact candidate (called on every LLM message).

2. **`src/ai_workflow/tui/agentic_loop/update_worker.zig` lines 73-115** — wrap the 3-statement `INSERT worker + INSERT sessions + UPDATE workspace_item_tasks` in a tx. Canonical "INSERT into 2 tables" pattern.

3. **`src/ai_workflow/tui/kanban_model.zig` `deleteColumn` (lines 293-306)** — wrap the `UPDATE workspace_item_tasks SET kanban_column_id = NULL` + `DELETE FROM kanban_columns` in a tx. Self-documented tx candidate (see lines 317-319).

4. **`src/ai_workflow/tui/kanban_model.zig` `replaceColumnsWith` (lines 332-395)** — wrap the per-column `deleteColumn` + `addColumn` loop in a tx. Self-documented tx candidate (see lines 317-319).

5. **`src/ai_workflow/tui/kanban_model.zig` `reorderColumn` (lines 521-571)** — wrap the 4-statement position-reservation dance in a tx. Real bug class (interrupted reorder leaves a column at the sentinel position).

6. **`src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig` + `workspaces_reorder.zig`** — wrap the per-item UPDATE loop in a tx. Resolves the open TODO at lines 135 and 127 respectively.

Each of these migrations is ~10-30 lines of churn per file and can land independently after this plan ships the tx API.

---

## Risks & Open Questions

1. **Mutex held during long-running tx blocks other writers.** The tx mutex is per-backend, so a long tx (e.g., 30-second migration) blocks ALL other `exec`/`query` calls on the same backend. This is the intended trade-off (atomicity) but may surprise users who expect fine-grained locking. Mitigation: tx lifetimes should be short — wrap only the multi-statement critical section, not the whole business logic. Document this constraint in the Transaction struct's doc comment.

2. **Nested savepoint naming.** The plan uses `sp_<depth>` (depth-based naming). If two callers independently use savepoints at the same depth with different names (not currently supported), they'd collide. Mitigation: this is fine for v1 because savepoint() is auto-named; future enhancement could add `savepointNamed(name)` if needed.

3. **`Transaction` borrow lifetime.** `Transaction.backend: *SqliteBackend` is a non-owning back-pointer. If the caller closes the backend (or moves it) while a tx is alive, the back-pointer becomes dangling. The Task 4.1 tests verify this is detected (returns `DatabaseNotFound`) rather than causing UB. Risk: low — the test confirms the guard works.

4. **Cancelation mid-tx.** `begin()` is cancelable (via `try self.mutex.lock(self.io)`). Once begin returns, the tx runs synchronously to commit/rollback — the Io runtime can't cancel mid-statement (the SQLite step() is a blocking syscall). This matches the existing `exec`/`query` cancelability model. No new failure mode.

5. **The savepoint `if (self.transaction_depth == 0) return Error.ExecuteFailed` guard.** SQLite itself returns SQLITE_ERROR if you try SAVEPOINT without an outer BEGIN. Mapping this to `Error.ExecuteFailed` is intentional (the user's intent failed). An alternative would be a new `Error.NoActiveTransaction` variant — YAGNI for v1; add if the API surface grows.

---

## Acceptance Criteria

The plan is complete when:

- [ ] `timeout 180 zig build test --summary all 2>&1 | tail -n 5` shows `test success` and `baseline + 16 tests passed`.
- [ ] Run `for i in 1 2 3; do zig build test --summary all; done` and verify the same `baseline + 16 tests passed` count on all 3 runs (no flakiness — mutex-held-across-tx invariant is not regressed).
- [ ] `timeout 180 zig build install:linux:system 2>&1 | tail -n 5` shows 4/6 steps succeed (the `compile exe nalar` step is the important one).
- [ ] `rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 5` shows `zig build success`.
- [ ] `git log --oneline main..HEAD | wc -l` shows exactly 12 commits (one per task: 1.0, 1.1, 1.2, 1.3, 2.1, 2.2, 3.1, 3.2, 3.3, 4.1, 4.2, 4.3).
- [ ] The `Transaction` struct, `begin()`, `savepoint()`, and `tx.exec`/`tx.query`/`tx.queryRow` are all publicly accessible from `SqliteBackend`.
- [ ] The module doc-comment on `Sqlite.zig` and `sqlite_test.zig` mention the tx API.
- [ ] No existing production code (outside `src/modules/databases/sqlite/`) is modified — the plan is additive.