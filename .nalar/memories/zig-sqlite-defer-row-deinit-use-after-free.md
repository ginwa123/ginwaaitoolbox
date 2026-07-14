# Zig SQLite test — `defer row.deinit(alloc)` inside a loop + post-loop assertion = use-after-free

When iterating `db.query(...).next()` in a test (or production code) with the
pattern:

```zig
var q = try db.query(alloc, "...", &.{});
defer q.deinit();
var owned: [N][]const u8 = undefined;  // ← BUG
var idx: usize = 0;
while (try q.next()) |row| {
    defer row.deinit(alloc);           // ← fires at END of iteration body
    if (idx < N) owned[idx] = row.values[0];  // ← borrowed slice header
    idx += 1;
}
// later: expectEqualStrings("width", owned[0]);  // SEGFAULT here
```

The `defer row.deinit(alloc)` registers cleanup that fires at the END of the
loop body iteration (when control flows back to the top of `while`). So after
iteration 0:
1. `owned[0] = row.values[0]` runs (slice header copied, but the backing
   memory is still owned by the row).
2. Control returns to the top of `while (try q.next()) |row|`.
3. The `defer row.deinit(alloc)` from iteration 0 fires, freeing
   `row.values[0]`.
4. **Now `owned[0]` is a dangling pointer** — its header still says
   `(.ptr, .len) = (the_freed_address, N)`, but the bytes are gone.
5. After the loop exits and the post-loop `expectEqualStrings("width", owned[0])`
   runs, `findDiff` dereferences the freed pointer → segfault inside
   `std/mem.zig:838` `if (a[index] != b[index])`.

## The fix — dupe before the row.deinit() can fire

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
try testing.expectEqualStrings("width", owned[0]);  // safe — owned[0] is heap-owned
```

Now `owned[0]` is a fresh heap allocation, independent of the row's
`values` array. The `defer row.deinit(alloc)` can free `row.values[0]`
without affecting `owned[0]`.

## Why this bites

1. The Zig 0.16 `SqliteBackend` (`src/modules/databases/sqlite/Sqlite.zig:167,173`)
   allocates `row.values[i]` from the passed `allocator`, and `row.deinit(allocator)`
   frees them. Borrowed slice headers across the `defer` boundary are
   classic use-after-free territory — same shape as the
   `get_skill.zig`/`view_skill.zig` 0xAA pattern (see memory
   `zig-slice-headers-across-defer-lifetimes`).
2. The bug is invisible when the test only does `idx += 1` (count) and
   never reads `owned[0]` after the loop — single-row tests never
   trigger it.
3. Debug allocator reports it as "segfault" in `findDiff`, far away
   from the actual misuse. Easy to misdiagnose as "the migration
   didn't run" or "the data is wrong".

## When this bites

- Any new test that does `defer row.deinit(alloc)` inside a
  `while (try q.next()) |row|` loop AND stores `row.values[X]` in
  a local array for post-loop assertion.
- Any production code that snapshots row data before the row is
  cleaned up.
- The same shape exists in any stdlib that owns the row's column
  slices and lets the caller `defer` a cleanup that frees them.

## How to detect

If `findDiff`/`memcmp` inside a `expectEqualStrings` segfaults at
`std/mem.zig:838` (or any `findDiff` line), and the call site is
inside a test that did `defer row.deinit(alloc)` in a `next()`
loop, the row's `values` array has been freed and the test is
reading dangling memory.

The crash is a "ghost value" — the test prints clean output through
the loop (the values are still alive while the loop body runs) and
only blows up on the first post-loop read of the stored slice.

## How to verify after the fix

```bash
# Re-run the test binary directly:
TEST_BIN=$(find .zig-cache/o -name "test" -type f -executable 2>/dev/null \
    | xargs file 2>/dev/null | grep "x86-64" | grep -v "windows" \
    | sort | tail -n 1 | cut -d: -f1)
timeout 60 "$TEST_BIN" 2>&1 | grep -E "Migration056|FAIL|expected"
# Expected: all Migration056 tests pass with "OK"; no FAIL or
# "expected this output" diff blocks.
```

## Concrete precedent in this repo

`src/ai_workflow/tui/migration_056_test.zig` (line ~230, the
`Migration056 runs on a v1 DB` integration test). The first version
of the test stored `row.values[0]` into `var found: [6][]const u8`
inside the `next()` loop, then asserted `expectEqualStrings("width",
found[0])` after the loop. Result: segfault at `findDiff` line
inside `expectEqualStrings`. Fix: change the local to `var owned:
[4][]u8` and `owned[idx] = try alloc.dupe(u8, row.values[0])` so the
slice owns its backing memory. After fix: test passes cleanly,
1125/1128 tests pass overall.

## Related memories

- `zig-slice-headers-across-defer-lifetimes.md` — same anti-pattern
  with 0xAA fill bytes in the output (different symptom: bytes
  instead of segfault, because that case copies a slice header
  from a defer-managed struct into a longer-lived one).
- `zig-migration-tests-three-pitfalls.md` — adjacent migration-test
  pitfall (PrepareFailed vs QueryFailed for missing tables).
- `nalar-tui-history-tool-call-id-field.md` — different Zig
  field-shape mix-up (`.tools` vs `.tool_call_id`).
