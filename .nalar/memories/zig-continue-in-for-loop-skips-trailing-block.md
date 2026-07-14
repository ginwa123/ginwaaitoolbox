# Zig — `continue` in a `for` loop skips the trailing block in the SAME iteration

In Zig, `continue` inside a `for` loop jumps to the next iteration of the
SAME for loop. **It does NOT fall through to any code below the `for` body
that belongs to the SAME iteration** — including blocks that come AFTER
the `continue` but BEFORE the end of the iteration.

## Symptom

You have a `for` loop with logic like:

```zig
for (items) |item| {
    var consumed = false;
    if (is_wildcard(item)) continue;  // jump to next iteration
    // ... process item ...
    if (!consumed) unconsumed.append(item);
}
```

You EXPECT the `if (!consumed) unconsumed.append(item)` block to also run
when `is_wildcard(item)` is true (since `consumed` is `false`).
But it does NOT — `continue` skips it entirely.

## Why

`continue` in a `for (items) |item|` loop is equivalent to jumping to the
increment step. Everything between the `continue` and the closing `}` of
the iteration body is SKIPPED, including the trailing `if (!consumed)` block.

The compiler does NOT warn about this; the bug surfaces only at runtime
(items that should have been added to `unconsumed` silently disappear).

## Fix

Two safe patterns:

### Option A — append BEFORE the continue (preferred when possible)

```zig
for (items) |item| {
    var consumed = false;
    if (is_wildcard(item)) {
        unconsumed.append(item);  // explicit, before continue
        continue;
    }
    // ... process item ...
    if (!consumed) unconsumed.append(item);
}
```

### Option B — restructure as `if/else` (preferred when the condition has complex consequences)

```zig
for (items) |item| {
    var consumed = false;
    if (!is_wildcard(item)) {
        // ... process item ...
    }
    if (!consumed) unconsumed.append(item);  // now runs in all paths
}
```

## When this bites

- Any `for` loop with an early-exit `continue` AND a trailing cleanup
  block ("if not handled above, do X") — the trailing block is silently
  skipped.
- Code reviews that reason about `continue` semantics assuming "fall
  through to cleanup" (a common pattern in Rust, C, Python, etc. — but
  NOT Zig).
- TDD scenarios where the failure mode is "result has fewer items than
  expected" (e.g., the `glob` walkDir test: "expected 1, found 0"
  because the wildcard pattern was never added to the unconsumed list).

## How to verify

If a for-loop uses `continue` and you need code AFTER the loop body
position to run in the early-exit case:

1. Trace the iteration by hand: starting from the `continue`, does control
   reach the trailing block? In Zig, NO.
2. Add a `std.debug.print` at the trailing block; run the test; if you
   never see the print on the early-exit path, the bug is confirmed.
3. Fix by restructuring the loop (Option A or B above).

## Concrete example in this project

`src/modules/agent/tools/glob.zig:701-703` (post-fix):

```zig
const first_slash = std.mem.indexOfScalar(u8, pat, '/') orelse pat.len;
const first_seg = pat[0..first_slash];
if (isWildcardPattern(first_seg)) {
    unconsumed.append(allocator, pat) catch continue;
    continue;  // explicit double-action: append THEN continue
}
```

The earlier "obvious" version was:

```zig
if (isWildcardPattern(first_seg)) continue;  // WRONG — skips the append
```

This was discovered when the `walkDir returns each file once for
wildcard-prefix pattern` test failed with `expected 1, found 0`. The
fix required putting `unconsumed.append` BEFORE the `continue`.