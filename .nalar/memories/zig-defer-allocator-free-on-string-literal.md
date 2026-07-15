# Zig — `defer allocator.free(literal_string)` panics with "Invalid free"

`defer allocator.free(...)` is a HARD ASSERT that the slice passed in is
heap-owned. Passing a string literal (`"foo"` — a `*const [N:0]u8` pointing
at static read-only memory, NOT a fat pointer to heap memory) panics with
`Invalid free` (the debug allocator's canary check fails).

## Symptom

```zig
const sd_field: []const u8 = if (state.static_dir) |sd|
    try std.fmt.allocPrint(allocator, "\"{s}\"", .{sd})
else
    "null";
defer allocator.free(sd_field);  // ← crashes when state.static_dir == null
```

When `state.static_dir == null`, `sd_field = "null"` (a compile-time string
literal — `*const [4:0]u8`). The `defer` is unconditional; on scope exit it
calls `allocator.free(sd_field)` which goes through the debug allocator's
canary check, detects that `sd_field`'s backing memory wasn't allocated by
this allocator, and panics:

```
thread N panic: Invalid free
/usr/local/lib/zig/std/heap/debug_allocator.zig:885:49: 0x... in free
            if (bucket.canary != config.canary) @panic("Invalid free");
                                                ^
```

The bug is invisible until a test exercises the literal-fallback path
**with a debug allocator**. In release-fast/safe mode the allocator
silently no-ops or skips the canary, so the bug doesn't surface. In the
nalar codebase, the `state_file.writeStateFile` function had this bug
since the original commit; it was never caught because no test passed
`State{ .static_dir = null }` (or did so via a release-fast build).

## Fix (track ownership explicitly)

```zig
// Track whether we actually allocated. Only free when we did.
const sd_field: []const u8 = sd: {
    if (state.static_dir) |sd| {
        const owned = try std.fmt.allocPrint(allocator, "\"{s}\"", .{sd});
        errdefer allocator.free(owned);  // cleanup if json allocPrint below fails
        break :sd owned;
    }
    break :sd "null";  // literal — DO NOT free
};
defer if (state.static_dir != null) allocator.free(sd_field);
```

The key insight: **the defer condition must match the allocation
condition**. Use a bool flag, an `?[]const u8`, or — simplest — re-check
the same `if` predicate that decided whether to allocate.

## General pattern (project convention)

For functions that sometimes allocate and sometimes use a literal
fallback:

1. **Always pair `try allocator.alloc/dupe/print` with `defer allocator.free`**
   — but ONLY on the path that actually allocated.
2. **Don't pass literals to allocator.free**. Always check ownership.
3. **Prefer `?[]const u8`** for "maybe-allocated" return values, then
   `if (maybe_alloc) |s| allocator.free(s)` in the defer.

## Why this bites

The Zig 0.16 debug allocator (`std.heap.DebugAllocator`) adds a canary
byte before each allocation. The canary is checked in `free()`. Passing
a pointer to static memory (string literal, global const, etc.) trips
the canary check and panics.

The release-fast / release-safe allocators (and the default GeneralPurposeAllocator
in some configurations) DON'T have this canary — they just skip the
free. So the bug is invisible in:
- Release-fast / Release-safe builds
- Tests that pass `static_dir != null` (so sd_field is always allocated)
- Tests where `allocator == std.heap.page_allocator` (no canary)

The bug surfaces when:
- A debug-mode unit test exercises the literal fallback
- A DebugAllocator is used (`std.testing.allocator` is one)
- The test triggers scope exit of the function with the bug

## When this bites

- Any function that uses a ternary `if (cond) heap_alloc else "literal"` +
  unconditional `defer allocator.free(...)`. Common in:
  - JSON serialization helpers (`"null"` fallback when field is absent)
  - Optional string formatters
  - Resource-pool wrappers
- Any new function with a debug-allocator-enabled test that triggers
  the literal branch.
- Zig 0.16 + DebugAllocator combinations where the literal fallback
  wasn't exercised by the original tests.

## How to verify

If you see `Invalid free` from `std/heap/debug_allocator.zig:885` and the
trace points at `defer allocator.free(...)`:

1. Find the `defer allocator.free(...)` in the trace's caller.
2. Walk the function: is the freed variable ever assigned a literal
   string, an empty slice (`""`), or any non-heap value?
3. If yes, gate the defer with a flag or `?[]const u8` ownership
   tracker (see Fix pattern above).
4. Add a unit test that exercises BOTH branches (heap-allocated and
   literal) so the bug can't reappear in release-only builds.

## Concrete precedent in this repo

`src/state_file.zig:127` (pre-fix) had the bug; my Chunk 5 smoke test
caught it. After fix: `src/state_file.zig:127` uses the `sd:` block +
conditional defer pattern.

Real failure mode observed: `state_file_test.zig:100` —
`test.writeStateFile does mkdir-p into a fresh nested dir` — passes
`State{ ..., .static_dir = null }`, hits the literal branch, panics
with `Invalid free`. The fix is the ownership-tracked pattern above.

The new regression test ensures the bug can't reappear:
- `state_file_test.zig:39` — `writeStateFile round-trips a State` with
  `static_dir = "/tmp/..."` (heap-allocated branch)
- `state_file_test.zig:73` — `writeStateFile does mkdir-p into a fresh
  nested dir` with `static_dir = null` (literal-fallback branch)

Both paths now pass; both must continue to pass to avoid regression.

## Related

- `zig-componentiterator-cumulative-path.md` — different stdlib pitfall
  in the same Chunk 5 work (`componentIterator.path` is cumulative,
  not per-segment)
- `custom-http-server-per-request-arena.md` — different ownership
  model (per-request arena reaps everything; no explicit `defer` needed
  in handlers)
- `zig-slice-headers-across-defer-lifetimes.md` — different lifetime
  bug pattern