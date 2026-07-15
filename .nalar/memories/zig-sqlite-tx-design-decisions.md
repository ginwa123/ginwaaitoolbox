# Zig SQLite Transaction Design — Critical Safety Decisions

Documented during the `sqlite with tx` plan (2026-07-12). Captures the 3 design pitfalls that would have caused UB / silent bugs, and the correct patterns.

## Pitfall 1: "Silent no-op" for completed Transactions is UNSAFE

If `commit()`/`rollback()` after completion return `void` (silent no-op), the user can write:

```zig
var tx = try db.begin();
try tx.exec(...);
try tx.commit();
try tx.exec(...);  // ← UB: mutex is released, races with other writers
```

After `commit()` releases the mutex, any further `tx.exec`/`tx.query`/`tx.queryRow` would call `executeStatement` on the connection WITHOUT the mutex, racing with concurrent threads' `db.exec`. This is silent data corruption, not a crash.

**Correct pattern:** Return `Error.TransactionClosed` from ALL tx methods when `self.completed == true`. Mirrors Go's `sql.ErrTxDone`. The defer idiom becomes:

```zig
var tx = try db.begin();
defer tx.rollback() catch |err| switch (err) {
    error.TransactionClosed => {}, // already committed/rolled back
    else => return err,
};
```

A plain `catch {}` (fire-and-forget) is still safe — `catch {}` swallows everything including `TransactionClosed`.

## Pitfall 2: `deinit()` MUST null out `self.db` for use-after-free guards to work

The existing `deinit()`:
```zig
pub fn deinit(self: *SqliteBackend) void {
    if (self.db) |d| {
        _ = c.sqlite3_close(d);
    }
}
```

leaves `self.db` as a dangling non-null pointer. Any code that does:
```zig
const db = self.backend.db orelse return Error.DatabaseNotFound;
```
... would NEVER hit the `orelse` branch after `deinit()`. The guard is silently broken.

**Fix:**
```zig
pub fn deinit(self: *SqliteBackend) void {
    if (self.db) |d| {
        _ = c.sqlite3_close(d);
    }
    self.db = null;  // ← CRITICAL: enables the use-after-free guard
}
```

This is a 1-line fix that should be added BEFORE introducing any code that relies on the `self.db == null` check (i.e., as a prerequisite for tx work).

## Pitfall 3: Dynamic SQL for `sqlite3_exec` requires sentinel-terminated buffer

`c.sqlite3_exec` takes `[*:0]const u8` (a NUL-terminated C string). `std.fmt.bufPrint` returns `[]u8` (NOT NUL-terminated). Naïve code:

```zig
var buf: [32]u8 = undefined;
const sql = std.fmt.bufPrint(&buf, "RELEASE sp_{d}", .{depth}) catch unreachable;
const rc = c.sqlite3_exec(db, sql.ptr, null, null, null);  // ← FAILS: sql.ptr is [*]const u8, not [*:0]const u8
```

Will NOT compile.

**Correct pattern:** Use a sentinel-terminated stack buffer:
```zig
var sql_buf: [32:0]u8 = undefined;
const sql_slice = std.fmt.bufPrint(sql_buf[0..31], "RELEASE sp_{d}", .{depth}) catch return Error.ExecuteFailed;
sql_buf[sql_slice.len] = 0;  // write the NUL sentinel
const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
```

- `sql_buf[0..31]` is `[]u8` (what `bufPrint` accepts; 31 bytes of payload).
- The 32nd byte holds the NUL sentinel.
- `&sql_buf` is `*[32:0]u8` which coerces to `[*:0]const u8` (the C string type `c.sqlite3_exec` expects).

This pattern works for any dynamic SQL passed to `sqlite3_exec` (SAVEPOINT, RELEASE, ROLLBACK TO, ATTACH, etc.).

## Bonus: `std.Io.Mutex` is NOT reentrant

Inner tx methods (`tx.exec`, `tx.query`, `tx.queryRow`) MUST NOT call `db.exec`/`db.query` (the locking versions). The mutex is already held by the tx; trying to re-lock would deadlock.

**Solution:** Refactor `exec`/`query`/`queryRow` into private helpers (`executeStatement`, `executeQuery`, `executeQueryRow`) that do NOT lock/unlock. The public `exec`/`query`/`queryRow` wrap them with lock/unlock; the tx methods call them bare.

## Cross-cutting lesson: RAII mutex-held-for-whole-resource-lifetime is the right pattern

The mutex-per-call pattern (the current `exec`/`query` behavior) is fine for single-statement operations. For multi-statement transactions, the mutex MUST be held for the whole tx lifetime to provide true atomicity. The RAII `Transaction` struct is the cleanest way to encode this — its lifetime IS the lock duration, so dropping the struct (or calling `commit`/`rollback`) automatically releases the lock.

The two existing reorder handlers' comment ("we don't use BEGIN/COMMIT because exec releases the mutex between calls — a transaction across calls wouldn't actually be atomic") is exactly correct. The fix isn't "just add BEGIN/COMMIT SQL"; the fix is "introduce a Transaction type that holds the mutex across all internal calls".

## Related nalar-internal notes

- The `Rows`/`Row` RAII precedent at `src/modules/databases/sqlite/Sqlite.zig:254-322` is the pattern the Transaction follows.
- The test pattern `DbCtx` (named struct with `db: SqliteBackend` + `threaded: std.Io.Threaded`) at `src/modules/databases/sqlite/sqlite_test.zig:36-60` is the test setup. The `defer teardown(&ctx)` cleanup is essential.
- `std.Io.Threaded.init(alloc, .{})` + `db.init(io, ":memory:")` is the test pattern (per `nalar-zig-0.16-inmemory-sqlite-test-setup` memory).
- Use `std.log.warn` not `std.log.err` for production error-path logging (per `zig-0.16-test-log-err-count` memory — `err` triggers `log_err_count > 0` in `zig build test`).

## Plan location

`/home/ginwa/agentic_coding_zig/ginwaaitoolbox/docs/superpowers/plans/2026-07-12-sqlite-tx-support.md`

12 tasks across 4 chunks. 16 new tests. No caller migration (out of scope; follow-up plans).