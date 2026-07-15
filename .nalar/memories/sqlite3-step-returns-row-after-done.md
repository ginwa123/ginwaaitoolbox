# sqlite3 — `step()` can return ROW again (not SQLITE_MISUSE) after SQLITE_DONE

This contradicts the documented SQLite API contract. The SQLite docs say
that after `step()` returns SQLITE_DONE, the next call to `step()` should
return SQLITE_MISUSE (21). **In practice (Zig 0.16 + vendored sqlite3 3.53+
on Linux x86_64), `step()` after DONE on a SELECT can return SQLITE_ROW
(100) again with the LAST row's data — not SQLITE_MISUSE.**

## Symptom

You write a `while (try q.next()) |r|` loop. The loop reads N rows from a
SELECT that returns N rows. After consuming row N, the loop ends (next()
returns null = DONE). You call `next()` one more time "just to be safe" or
your iteration code does so accidentally. You expect SQLITE_MISUSE → null.
You get SQLITE_ROW instead → the same row N re-allocated and returned,
your test asserts `== null` and fails, AND the leaked Row allocation is
flagged by `std.testing.allocator`.

## Empirically confirmed

```
[DEBUG next] step() rc=101  ← call #2 (after consuming row 1 of 1): DONE
[DEBUG next] step() rc=100  ← call #3 (the "extra" call): ROW — RE-YIELDS!
```

So:
- call #1: ROW (the only row 'a')
- call #2: DONE (my fix correctly returns null)
- call #3: ROW again — same row 'a'!

Without the fix, the wrapper treats call #3 as a normal ROW, allocates a
new Row struct with a new values array, returns it to the caller who
expects null, the assertion fails, and the new Row is leaked.

## The fix

Don't rely on `step()`'s post-DONE behavior. Track an explicit `done` flag
on the Rows iterator and short-circuit subsequent `next()` calls:

```zig
pub const Rows = struct {
    allocator: std.mem.Allocator,
    stmt: ?*c.sqlite3_stmt,
    done: bool = false,  // ← NEW

    pub fn next(self: *Rows) Error!?Row {
        if (self.done) return null;       // ← short-circuit
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) {
            self.done = true;
            return null;
        }
        if (rc == c.SQLITE_MISUSE) {     // ← handle both for safety
            self.done = true;
            return null;
        }
        // ... ROW handling ...
    }
};
```

## Why this matters

The wrapper's contract is `while (try q.next()) |r| ...` — callers expect
null to mean "iteration complete, no more rows". If `step()` can return
ROW after DONE, that contract is broken without the explicit `done` flag.
Real-world callers that call `next()` "one extra time" by accident
(common pattern: loop terminates, then a defensive `q.next()` to ensure
the iterator is fully drained) would see a duplicated final row.

## The other related fix: SQLITE_MISUSE constant was missing

The wrapper's non-Linux c struct (manual `extern "c" fn` block) didn't
define `SQLITE_MISUSE`. Linux uses `@cImport(@cInclude("sqlite3.h"))`
which gets the full enum. On macOS/Windows (cross-compile from Linux),
`c.SQLITE_MISUSE` would have been a compile error. Added it to the
manual struct so cross-compile still works:

```zig
pub const SQLITE_MISUSE: c_int = 21;
```

## When this bites

- Writing ANY test that calls `next()` more times than there are rows.
- Code that drains an iterator with a "one extra defensive call"
  pattern.
- Any wrapper around `sqlite3_step` that doesn't track done state.
- The fix is small (one `done: bool` field + a 2-line check at the top
  of `next`) and locks in the contract regardless of what the SQLite
  C library returns.

## Concrete precedent in this repo

`src/modules/databases/sqlite/Sqlite.zig` — `Rows.next()` got the
`done: bool` flag and the `if (self.done) return null;` short-circuit
in commit `115cfde4` on branch `worktree/sqlite-edge-case-tests`. The
test that surfaced the bug:

```zig
test "Rows.next() after DONE returns null (defensive against SQLITE_MISUSE)" {
    // ...
    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    var q = try ctx.db.query(alloc, "SELECT id FROM foo", &.{});
    defer q.deinit();
    const r1 = (try q.next()) orelse return error.ExpectedRow;
    r1.deinit(alloc);
    try testing.expect((try q.next()) == null);  // ← would fail pre-fix
    try testing.expect((try q.next()) == null);  // ← would fail pre-fix
}
```

## Related memories

- `zig-0.16-test-log-err-count.md` — the `std.log.err` → `std.log.warn`
  demotion that came up in the same TDD session for a different reason
  (user-input errors should not be `.err` level).
- `zig-slice-headers-across-defer-lifetimes.md` — different zig 0.16
  ownership/lifetime trap pattern.
- `nalar-zig-0.16-inmemory-sqlite-test-setup.md` — the `Io.Threaded +
  :memory:` pattern that makes these tests work.