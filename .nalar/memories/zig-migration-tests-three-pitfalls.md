# nalar — Migration tests: three pitfalls that bit me on Migration047AddNotifications

When writing a new `*_test.zig` for a `MigrationXXXAddXxx` struct in
`src/ai_workflow/tui/migration.zig`, three pitfalls will bite you in the
exact order the test compiles-then-runs. All three were caught and fixed
during Task 1 of the stop-notification feature (commit `4b6c9a78` on
branch `feature/stop-notification`).

## Pitfall 1 — Single-line `\\` raw string has no terminating `;`

The spec / plan often writes:

```zig
const expected_cols =
    \\SELECT name FROM pragma_table_info('notifications') ORDER BY cid;
```

This is a Zig parse error: `error: expected ';' after statement` at the
trailing `;`. The `\\…` raw string ends at the newline (content is
everything between `\\` and `\n`), and the SQL's `;` is now INSIDE the
string, so the const declaration has no statement-terminator.

**Fix:** put the `;` on its own line (matches the project's multi-line
raw-string convention in `llm_history.zig:670-674`):

```zig
const expected_cols =
    \\SELECT name FROM pragma_table_info('notifications') ORDER BY cid
;
```

## Pitfall 2 — `row.values[i]` is freed by `row.deinit`; storing raw slice headers = use-after-free

`SqliteBackend.next()` allocates `row.values[i]` from the passed
allocator (see `src/modules/databases/sqlite/Sqlite.zig:167` and `:173`).
`row.deinit(allocator)` frees them. If you do:

```zig
var names: [5][]const u8 = undefined;
while (try q.next()) |row| {
    defer row.deinit(alloc);                    // ← frees row.values[0]
    names[count] = row.values[0];
    count += 1;
}
// later: expectEqualStrings("id", names[0]);   // ← CRASH: dangling pointer
```

`names[0]` now points at freed memory. The crash shows up as a
`Segmentation fault` inside `std.testing.expectEqualStrings` (or
`std.mem.findDiff`) at the line of the assertion — not at the use-after-free
site itself.

**Fix:** keep an owned copy:

```zig
var names: [5][]u8 = undefined;
var owned: [5][]u8 = undefined;
while (try q.next()) |row| {
    defer row.deinit(alloc);
    owned[count] = try alloc.dupe(u8, row.values[0]);
    names[count] = owned[count];
    count += 1;
}
defer for (owned[0..count]) |n| alloc.free(n);
```

Or assert inside the loop, before `row.deinit` fires.

## Pitfall 3 — `db.exec` returns `error.PrepareFailed`, not `error.QueryFailed`, for missing tables

When writing the "drop table" inverse test for a migration:

```zig
// ❌ Wrong — spec-style guess
const rc = db.exec(alloc, "SELECT 1 FROM notifications LIMIT 1", &.{});
try testing.expectError(error.QueryFailed, rc);

// ✅ Correct — verified at src/modules/databases/sqlite/Sqlite.zig:65-69
const rc = db.exec(alloc, "SELECT 1 FROM notifications LIMIT 1", &.{});
try testing.expectError(error.PrepareFailed, rc);
```

`db.exec` calls `sqlite3_prepare_v2` first; if the table doesn't exist,
the prepare itself fails (the statement can't even be built), so the
function returns `error.PrepareFailed`. `error.QueryFailed` would only
fire if the prepare succeeded but the step (execute) failed.

## When these bite

- Any new `migration_xxx_test.zig` file in `src/ai_workflow/tui/`.
- Any test that walks a `db.query()` cursor and stores column values for
  later assertion.
- Any test that exercises `db.exec()` against a missing table or index.
- Plans that draft test code without running it through the compiler
  first.

## How to verify

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/<branch>
timeout 180 zig build test --summary all 2>&1 | tail -n 10
# Expect: "565/568 tests passed (3 skipped)" — was 563 before the
# migration, +2 for the up/down tests.
```

For pinpoint confirmation of WHICH tests are yours, run the test binary
directly and grep:

```bash
TEST_BIN=$(ls -t .zig-cache/o/*/test | head -n 1)
timeout 60 "$TEST_BIN" 2>&1 | rg -i Migration047
```

The Zig test runner doesn't print passing test names in the normal
`zig build test` output, only in the raw binary output. Use the binary
grep pattern to confirm by name.