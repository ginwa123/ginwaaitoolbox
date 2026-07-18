# Zig — SQLite patterns and pitfalls

This file consolidates SQLite-specific Zig patterns in the nalar codebase. For related nalar schema/migration patterns, see `nalar-data-and-routines.md`. For testing patterns, see `zig-build-and-test.md`.

---

## `SqliteBackend.exec` binds empty `[]const u8` as SQL NULL

In `src/modules/databases/sqlite/Sqlite.zig:73-74`, `exec` treats any `arg.len == 0` as `NULL` (empty slice → NULL, NOT empty string). The `query` function does the same at line 209.

**Why this bites:** When a column is declared `NOT NULL`, callers cannot pass an empty string as a sentinel — the empty slice gets bound as NULL and the INSERT/UPDATE fails with `NOT NULL constraint failed: <table>.<column>`.

**Symptom:**
```
sqlite3_step error: NOT NULL constraint failed: kanban_columns.description
```
from `db.exec(...)` returning `Error.ExecuteFailed`.

**Fix patterns:**

**Pattern A — split INSERT into "with description" / "without description":**

```zig
if (description.len == 0) {
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES (?, ?, ?, ?)",
        &.{ id, workspace_item_id, name, pos_str });
} else {
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) " ++
        "VALUES (?, ?, ?, ?, ?)",
        &.{ id, workspace_item_id, name, description, pos_str });
}
```

**Pattern B — skip the UPDATE when value is empty (no-op semantics):**

```zig
if (description) |d| {
    if (d.len > 0) {
        try db.exec(alloc,
            "UPDATE kanban_columns SET description = ? WHERE id = ?",
            &.{ d, column_id });
    }
}
```

Trade-off: callers can't currently "clear" an existing description through this path — they'd need a separate "delete description" API.

**Pattern C — fix at the SQLite backend layer (NOT recommended).** Out of scope for incremental feature work.

**When this bites:** any new `db.exec` call that includes a `NOT NULL` column with `DEFAULT ''` and the caller may pass `""`; any model function using `?[]const u8` to mean "leave unchanged".

---

## `db.exec` / `db.query` only bind TEXT, never integers

`SqliteBackend.exec` and `query` only bind arguments via `sqlite3_bind_text`. There is no `sqlite3_bind_int` / `sqlite3_bind_int64` exposed. **Every argument must be `[]const u8`.**

**Symptom of getting it wrong:**

```zig
const now_us: i64 = ...;
db.exec(allocator, "INSERT INTO t (ts) VALUES (?)", &.{
    std.mem.asBytes(&now_us),  // ← BUG: 8 bytes of binary bound as TEXT
}) catch ...;
```

Compiles cleanly, bind succeeds (8 bytes as TEXT), but the stored value is binary garbage. `SELECT ts FROM t` returns `'\u0001@^'` instead of `"1234567890"`. The "no compile error" property makes this bug especially nasty.

**Fix — format i64 → string before binding:**

```zig
const now_us: i64 = ...;
const now_us_str = try std.fmt.allocPrint(allocator, "{d}", .{now_us});
defer allocator.free(now_us_str);
db.exec(allocator, "INSERT INTO t (ts) VALUES (?)", &.{ now_us_str }) catch ...;
```

SQLite coerces numeric-looking TEXT to INTEGER under INTEGER affinity on insert. Round-trip type-preserving; comparisons (`WHERE ts >= ?`) work correctly because SQLite coerces both sides to INTEGER.

**When this bites:** ANY new `db.exec` or `db.query` call needing to pass integer values (timestamps, counts, line numbers, positions). The codebase already uses this pattern in `kanban_model.zig:177` and `llm_history.zig:1026-1029`.

---

## `step()` can return ROW again (not SQLITE_MISUSE) after SQLITE_DONE

This contradicts the documented SQLite API contract. In practice (Zig 0.16 + vendored sqlite3 3.53+ on Linux x86_64), `step()` after DONE on a SELECT can return SQLITE_ROW (100) again with the LAST row's data — not SQLITE_MISUSE.

**Symptom:**

```
[DEBUG next] step() rc=101  ← call #2: DONE
[DEBUG next] step() rc=100  ← call #3: ROW — RE-YIELDS!
```

A `while (try q.next()) |r|` loop that calls `next()` one extra time after iteration completes gets the LAST row re-allocated, returned, and leaked.

**Fix — track explicit `done` flag:**

```zig
pub const Rows = struct {
    allocator: std.mem.Allocator,
    stmt: ?*c.sqlite3_stmt,
    done: bool = false,

    pub fn next(self: *Rows) Error!?Row {
        if (self.done) return null;              // short-circuit
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) {
            self.done = true;
            return null;
        }
        if (rc == c.SQLITE_MISUSE) {             // both for safety
            self.done = true;
            return null;
        }
        // ... ROW handling ...
    }
};
```

**Also needed:** define `SQLITE_MISUSE` in the manual c struct (not used on Linux's `@cInclude` but needed for macOS/Windows cross-compile):

```zig
pub const SQLITE_MISUSE: c_int = 21;
```

**When this bites:** writing any test that calls `next()` more times than there are rows; code draining with a "one extra defensive call" pattern.

---

## SQLite Transaction Design — three critical safety decisions

### Pitfall 1: "Silent no-op" for completed Transactions is UNSAFE

If `commit()`/`rollback()` after completion return `void`, the user can write:

```zig
var tx = try db.begin();
try tx.commit();
try tx.exec(...);  // ← UB: mutex is released, races with other writers
```

After `commit()` releases the mutex, any further `tx.exec`/`tx.query` would call `executeStatement` WITHOUT the mutex, racing with concurrent threads' `db.exec`. Silent data corruption, not a crash.

**Correct pattern:** Return `Error.TransactionClosed` from ALL tx methods when `self.completed == true` (mirrors Go's `sql.ErrTxDone`). The defer idiom:

```zig
var tx = try db.begin();
defer tx.rollback() catch |err| switch (err) {
    error.TransactionClosed => {},         // already committed/rolled back
    else => return err,
};
```

A plain `catch {}` (fire-and-forget) is still safe.

### Pitfall 2: `deinit()` MUST null out `self.db` for use-after-free guards

```zig
// ❌ Existing buggy version:
pub fn deinit(self: *SqliteBackend) void {
    if (self.db) |d| {
        _ = c.sqlite3_close(d);
    }
    // ← self.db left as dangling non-null pointer
}
```

`const db = self.backend.db orelse return Error.DatabaseNotFound;` would NEVER hit the `orelse` branch after `deinit()`. The guard is silently broken.

**Fix:**

```zig
pub fn deinit(self: *SqliteBackend) void {
    if (self.db) |d| {
        _ = c.sqlite3_close(d);
    }
    self.db = null;  // ← CRITICAL: enables the use-after-free guard
}
```

### Pitfall 3: Dynamic SQL for `sqlite3_exec` requires sentinel-terminated buffer

`c.sqlite3_exec` takes `[*:0]const u8` (NUL-terminated). `std.fmt.bufPrint` returns `[]u8` (NOT NUL-terminated).

**Correct pattern:**

```zig
var sql_buf: [32:0]u8 = undefined;
const sql_slice = std.fmt.bufPrint(sql_buf[0..31], "RELEASE sp_{d}", .{depth}) catch return Error.ExecuteFailed;
sql_buf[sql_slice.len] = 0;  // write the NUL sentinel
const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
```

- `sql_buf[0..31]` is `[]u8` (what `bufPrint` accepts)
- The 32nd byte holds the NUL sentinel
- `&sql_buf` is `*[32:0]u8` which coerces to `[*:0]const u8`

This pattern works for any dynamic SQL passed to `sqlite3_exec` (SAVEPOINT, RELEASE, ROLLBACK TO, ATTACH, etc.).

### Bonus: `std.Io.Mutex` is NOT reentrant

Inner tx methods (`tx.exec`, `tx.query`, `tx.queryRow`) MUST NOT call `db.exec`/`db.query` (the locking versions). The mutex is already held by the tx; trying to re-lock would deadlock.

**Solution:** Refactor `exec`/`query`/`queryRow` into private helpers (`executeStatement`, `executeQuery`, `executeQueryRow`) that do NOT lock/unlock. The public methods wrap them with lock/unlock; the tx methods call them bare.

### RAII mutex-held-for-whole-resource-lifetime is the right pattern

The mutex-per-call pattern is fine for single-statement operations. For multi-statement transactions, the mutex MUST be held for the whole tx lifetime to provide true atomicity. The RAII `Transaction` struct is the cleanest way to encode this — its lifetime IS the lock duration, so dropping the struct (or calling `commit`/`rollback`) automatically releases the lock.

---

## `defer row.deinit(alloc)` inside a loop + post-loop assertion = use-after-free

Iterating `db.query(...).next()` with:

```zig
var q = try db.query(alloc, "...", &.{});
defer q.deinit();
var owned: [N][]const u8 = undefined;   // ← BUG
var idx: usize = 0;
while (try q.next()) |row| {
    defer row.deinit(alloc);             // ← fires at END of iteration body
    owned[idx] = row.values[0];         // ← borrowed slice header
    idx += 1;
}
// later: expectEqualStrings("...", owned[0]);  // SEGFAULT
```

The `defer row.deinit(alloc)` registers cleanup that fires when control flows back to the top of `while`. After iteration 0:
1. `owned[0] = row.values[0]` (slice header copied, row still alive)
2. Control returns to top of `while`
3. `defer row.deinit(alloc)` from iteration 0 fires, freeing `row.values[0]`
4. **Now `owned[0]` is a dangling pointer**
5. Post-loop `expectEqualStrings("...", owned[0])` dereferences freed memory → segfault inside `findDiff` at `std/mem.zig:838`

**Fix — dupe before the row.deinit() can fire:**

```zig
var owned: [N][]u8 = .{ &.{}, &.{}, ... };
defer for (owned) |s| if (s.len > 0) alloc.free(s);
var idx: usize = 0;
while (try q.next()) |row| {
    defer row.deinit(alloc);
    if (idx < N) {
        owned[idx] = try alloc.dupe(u8, row.values[0]);  // ← OWNED copy
        idx += 1;
    }
}
try testing.expectEqualStrings("...", owned[0]);  // safe
```

**When this bites:** any new test that does `defer row.deinit(alloc)` inside `while (try q.next()) |row|` AND stores `row.values[X]` in a local array for post-loop assertion; any production code that snapshots row data before cleanup.

---

## SQLite silently DROPS non-deterministic GENERATED ALWAYS AS STORED columns

When you write a `CREATE TABLE` or `ALTER TABLE ... ADD COLUMN` with `GENERATED ALWAYS AS <expr> STORED` whose `<expr>` is non-deterministic, SQLite **silently omits the column** — no error, no warning. The column just doesn't appear in `pragma_table_info`.

**Examples of non-deterministic:**
- `datetime(..., 'localtime')` — depends on the system timezone
- `datetime('now')` — depends on current time
- `randomblob(...)`, `random()` — depends on randomness

`datetime(<unix_secs>, 'unixepoch', 'utc')` IS deterministic and works inside generated columns.

**The fix — use triggers:**

```sql
ALTER TABLE foo ADD COLUMN iso TEXT;

CREATE TRIGGER foo_iso_ins AFTER INSERT ON foo
FOR EACH ROW
WHEN NEW.a IS NOT NULL AND NEW.a != ''
BEGIN
    UPDATE foo SET iso = datetime(
        CAST(NEW.a AS REAL) / 1000000,
        'unixepoch', 'localtime'
    ) WHERE rowid = NEW.rowid;
END;

-- Backfill existing rows:
UPDATE foo SET iso = datetime(CAST(a AS REAL) / 1000000, 'unixepoch', 'localtime')
WHERE iso IS NULL OR iso = '';
```

**The CAST(... AS REAL) trick for microsecond timestamps:** `datetime(<big_int>, 'unixepoch', 'localtime')` overflows past year 9999 and returns NULL. nalar stores Unix microseconds (17-digit integers). The fix: divide by 1000000 via `CAST(... AS REAL)` so SQLite treats it as fractional seconds.

Integer division `'1784119389936251112' / 1000000` = 1784119389936 (year 58000+). Float division does the right thing.

**How to detect:**

```bash
sqlite3 :memory: <<'EOF'
CREATE TABLE t (a TEXT, b TEXT GENERATED ALWAYS AS (datetime('now')) STORED);
PRAGMA table_info('t');
EOF
# 0|a|TEXT|0||0     ← only `a`. `b` was silently dropped.
```

**When this bites:** any schema with `created_at`-like Unix timestamps needing conversion to human-readable strings; any use of `localtime` inside a generated column expression; any migration that wants to add a date-derived column.

---

## SQLite query returns `error.PrepareFailed` (NOT `QueryFailed`) for missing tables

`db.exec` calls `sqlite3_prepare_v2` first; if the table doesn't exist, prepare fails. `QueryFailed` would only fire if prepare succeeded but step (execute) failed.

Always assert `error.PrepareFailed` (NOT `error.QueryFailed`) in migration tests against missing tables.

See `zig-build-and-test.md` for the full migration-test pitfalls section.

---

## `addColumnIfMissing` requires `column_name TYPE` as the definition arg

The helper `addColumnIfMissing(db, alloc, table, column, definition)` in `src/migrations/migration.zig` builds `ALTER TABLE {s} ADD COLUMN {s}`, so `definition` must include BOTH the column name AND the type:

```zig
// ❌ Wrong — creates a column literally named "TEXT"
try addColumnIfMissing(db, allocator, "llm_history", "created_iso", "TEXT");

// ✅ Correct — gives ADD COLUMN created_iso TEXT
try addColumnIfMissing(
    db, allocator,
    "llm_history",
    "created_iso",
    "created_iso TEXT",
);
```

**Why this design is fragile:** The helper has TWO column-name-related args (`column` for existence check, `definition` for the ALTER). Future refactor: pass `type_spec` only and have the helper build `name TYPE`.

**When this bites:** any new migration adding a column via `addColumnIfMissing`. Verify with `PRAGMA table_info(<table>)` — the column should have a real type, not be literally named with a type keyword.

---

## libc `localtime_r` symbol-resolution bug on glibc 2.x

`libc::localtime_r` cannot be safely called from Zig 0.16 on Arch Linux's glibc 2.x. The symbol resolves to a 32-bit-compatibility wrapper that truncates 64-bit timestamps, producing wildly wrong years.

**Symptom:** Calling with `sec = 1785000000` returns year 56606 instead of 2026.

**Fix — use Zig stdlib's `std.time.epoch`:**

```zig
const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = sec_u64 };
const epoch_day = epoch_seconds.getEpochDay();
const year_day = epoch_day.calculateYearDay();
const month_day = year_day.calculateMonthDay();
const day_seconds = epoch_seconds.getDaySeconds();

const iso = std.fmt.bufPrint(&buf,
    "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
    .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,        // 0 → 1
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    },
) catch unreachable;
```

**Don't write a hand-rolled Howard Hinnant algorithm.** The reference uses an offset of `+719468` (NOT `+2440588` which is JDN 1970-01-01) — getting the offset wrong produces dates off by 4712 years.

---

## Related / cross-references

- `zig-build-and-test.md` — `PrepareFailed` vs `QueryFailed`, migration test pitfalls
- `nalar-data-and-routines.md` — schema/migration patterns, routine fire pipeline
- `zig-cross-platform.md` — cross-platform libc wrapping patterns