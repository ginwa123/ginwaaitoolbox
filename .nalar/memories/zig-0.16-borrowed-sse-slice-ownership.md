# Zig 0.16 — Borrowed SSE/Event-Bus Slices Need Explicit Ownership Tracking

When a function builds a `[]const u8` slice for an event-bus payload
(SSE emitter, log entry, JSON field), the slice is typically **borrowed**
by the receiver — the receiver reads it during the call, formats it,
and the caller's memory is still owned by the caller. The caller MUST
free the memory after the function returns.

The naive pattern is fragile and easy to get wrong in Zig 0.16 because
of type unification across `catch` and `orelse`.

## Symptom

You write something like:

```zig
const created_at: []const u8 = blk: {
    var q = db.query(...) catch break :blk null;
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);  // []u8
    }
    break :blk null;  // hmm, type is ?[]u8
} orelse std.fmt.allocPrint(allocator, "{d}", .{now_ms}) catch "0";
//                                          ^^^^^^^^^^^^^^^^^^^^^^^^^
//                      "0" is *const [1:0]u8, NOT []u8
//                      Type unification fails across `orelse` + `catch`
defer allocator.free(created_at);  // unsafe on string-literal fallback
```

Errors you might see:
- `error: expected type '[]u8', found '*const [1:0]u8'`
- `error: expected type '[]u8', found '*const [0]u8'` (for `&[_]u8{}`)
- `error: cannot convert '[]const u8' to '[]u8'` (when assigning `[]const u8` to `[]u8`)

## The fix — split into an owned + a borrowed fallback

```zig
// Step 1: track the owned path separately so we know whether to free it.
const created_at_owned: ?[]u8 = blk: {
    var q = db.query(allocator, "SELECT created_at FROM ...", &.{id}) catch break :blk null;
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        break :blk allocator.dupe(u8, row.values[0]) catch null;
    }
    break :blk null;
};
// Free the owned path if we got it.
defer if (created_at_owned) |c| allocator.free(c);

// Step 2: build a fallback for the failure path. If it ALSO fails,
// return early — we have nothing to emit.
const created_at: []const u8 = created_at_owned orelse
    std.fmt.allocPrint(allocator, "{d}", .{now_ms}) catch {
    // (optional logging)
    return;
};
// Free the fallback only if the owned path was null (i.e., we used it).
defer if (created_at_owned == null) allocator.free(created_at);

// Step 3: pass `created_at` to the borrower (SSE emitter, log, etc.).
sse.emit(.{ .created_at = created_at, ... });
```

The two `defer if (...)` blocks are **mutually exclusive**:
- If `created_at_owned != null`: line A frees the dupe; line B sees `created_at_owned != null` and skips.
- If `created_at_owned == null`: line A sees null and skips; line B frees the allocPrint result.

## Why this works

- `[]u8` (from `allocator.dupe`) coerces to `[]const u8` for the `orelse` RHS, then the `orelse` result is assigned to `const created_at: []const u8` (one coercion, no unification).
- The fallback path is `[]u8` from `std.fmt.allocPrint` — same type as the success path's `[]u8`. No type mismatch.
- The `catch { return; }` on the fallback handles the OOM case explicitly (give up, no SSE emit).
- The string-literal anti-pattern (`catch "0"`) is avoided — `"0"` would NOT unify with `[]u8`.

## When this bites

- Any function that builds a string slice for an event-bus / SSE / log payload where the receiver only borrows.
- Any function that has a primary "DB read" path AND a "compute fallback" path for the same field.
- Any function that uses `blk:` for early-return-style control flow with non-trivial types.
- Code reviews that copy the "catch with string literal" pattern from languages where string literals are heap-allocated (Java, Python) — in Zig, string literals are inline and `catch "x"` produces a `*const [N:0]u8` (a stack pointer), not a `[]u8` (a fat pointer to heap memory).

## How to verify after writing

1. Compile and check for type-mismatch errors. If you see "expected `[]u8`, found `*const [...]u8`", you have the bug.
2. Run with `zig build test --summary all` and confirm no memory leak (the `testing.allocator` will report leaks).
3. If the borrowed receiver is async (event-bus, SSE), the function returns BEFORE the receiver actually delivers. The caller still owns the memory and must free it — this is NOT a transfer of ownership.

## Related

- `zig-slice-headers-across-defer-lifetimes.md` — different bug (use-after-free on slice headers), but same "Zig 0.16 defer pattern" category.
- `custom-http-server-per-request-arena.md` — different ownership model (per-request arena reaps everything; no explicit `defer` needed).
- The actual fix in the nalar codebase is at `src/ai_workflow/tui/notifications.zig:189-211` (the `maybeInsertStopNotification` function, commit `7a2d2c8` on `feature/stop-notification`).
</markdown>
</invoke>