# Fix the 7 pre-existing broken reorderElements tests (now surfaced by inline refactor)

## Context

PR #275 (commit `63c8bbe4`) inlined `design_model_reorder_test.zig` into
`design_model.zig`. The README of `agentic_loop/` noted that 7 of the 8
reorder tests were *intentionally not registered* before the refactor
because they were "pre-existing broken — schema/setup issues" that
crashed with SIGABRT or failed assertions.

When the file was inlined, those 7 tests came along for the ride and
started running. PR #275's follow-up commit `9e312916` wrapped them in
`if (false) { ... }` to silence the failures, leaving a TODO pointing
at task `task_1787178257311820641` (this plan's kanban card).

This plan: actually fix the bugs so the 7 tests run and pass — instead
of papering over them with `if (false)`.

## Baseline

- `zig build test`: 2443 pass, 6 skip, 0 fail, 0 crash
- 7 of the 2443 "pass" were `if (false)` no-ops hiding the bugs.
- After unwrap: 2436 pass, 6 skip, 2 fail, 5 crash.

## Root causes (verified by reading code + running the unwrapped tests)

### Cause A — defers in wrong order (5 tests SIGABRT)

The 5 tests that crashed all share the same pattern:

```zig
const result = try reorderElements(...);
defer for (result) |e| freeElement(s.alloc, e);  // <-- runs SECOND
defer s.alloc.free(result);                       // <-- runs FIRST
```

Zig defers are LIFO. So at test teardown:

1. `s.alloc.free(result)` runs first → slice header freed.
2. `for (result) |e| freeElement(...)` runs second → reads the
   already-freed slice header → use-after-free → SEGV.

Fix: swap the two `defer` lines so `s.alloc.free(result)` is the FIRST
defer (LIFO → runs LAST) and the for-loop is the SECOND defer (LIFO →
runs FIRST, while the header is still valid).

The HTTP-handler test
(`design_elements_reorder_test.zig`) already uses a defer block to
sidestep this trap:

```zig
defer {
    for (result) |e| design_model.freeElement(allocator, e);
    allocator.free(result);
}
```

### Cause B — test expectations swapped (2 tests assertion fail)

The `bring_to_front` test expected `c(z=3), a(z=4)` but the algorithm
walks the input list in order, assigning `max_z + 1, max_z + 2, ...`.
With input `[a, c]`, `a` (first) gets `z=3` and `c` (second) gets
`z=4`. The comment ("c ends up topmost") describes what the algorithm
does — only the expected-z values were wrong. Same swap on
`send_to_back`: expected `a(z=-1), b(z=-2)` but the algorithm
iterates REVERSE, so `b` (last input, processed first) gets `z=-1` and
`a` (first input, processed last) gets `z=-2`.

The HTTP-handler test
(`design_elements_reorder_test.zig:122-133`) explicitly walks through
the algorithm and confirms `a(z=3), c(z=4)`, so the algorithm is the
authoritative contract — the model tests' expectations were wrong
from the day the function was added (commit `afacda15`).

### Cause C — algorithm gap (2 tests expect errors the model never raised)

`PageNotFound` and `CrossPageIds` were documented in
`ReorderError` but the model layer never raised them — it collapsed
both into `BadElementId`. The HTTP handler
(`design_elements_reorder.zig:128-146`) maps each error to a distinct
status code (400 / 404 / 409), so the 404 and 409 branches were
unreachable from production traffic. The http_handlers test
explicitly notes (lines 159-164) that the model layer was "brittle"
and that "Adding a dedicated PageNotFound test requires a pre-flight
SELECT for page existence; deferred to a follow-up." This is that
follow-up.

The fix follows the same pattern already used by `reparentElements`
(line 2332: `SELECT ... FROM design_pages WHERE id = ?` →
`PageNotFound`) and `moveElementsWithDescendantsBatch` (same).

### Cause D — `try testing.expect` inside a `for (result)` loop

`returned_slice` test had:

```zig
for (result) |e| {
    if (std.mem.eql(u8, e.id, a)) seen_a = true;
    if (std.mem.eql(u8, e.id, b)) seen_b = true;
    if (std.mem.eql(u8, e.id, c)) seen_c = true;
    try testing.expect(seen_a and seen_b and seen_c);  // <-- WRONG: inside loop
}
```

The `expect` fires on the FIRST iteration when only one of
`seen_a`/`seen_b`/`seen_c` is true → always fails. Move it AFTER the
loop.

## Fix

### 1. Algorithm — `src/ai_workflow/tui/agentic_loop/design_model.zig`

- Add a pre-flight `SELECT 1 FROM design_pages WHERE id = ?` so
  unknown `page_id` returns `PageNotFound` instead of `BadElementId`.
- For ids that don't resolve to a row on the requested page, probe
  `design_page_elements` to distinguish "missing entirely"
  (`BadElementId`) from "exists on a different page" (`CrossPageIds`).

### 2. Tests — same file, bottom

For each of the 7 unwrapped tests:

- Re-indent the body by 4 spaces (the `if (false) { ... }` wrapper
  collapsed the indent).
- Swap the order of the two `defer` lines (Cause A).
- Update the bring_to_front / send_to_back expectations to match the
  algorithm (Cause B).
- Move the `try testing.expect(seen_a and seen_b and seen_c);` AFTER
  the `for` loop (Cause D).
- Update the test comments to walk through the algorithm and document
  the actual z values.

## Result

```
$ zig build test --summary all
Build Summary: 7/7 steps succeeded; 2443/2449 tests passed (6 skipped)
test success
+- run test 2443 pass, 6 skip (2449 total)
```

2443 pass, 6 skip, 0 fail, 0 crash. The 7 reorder tests now run and
genuinely pass — no more `if (false)` hiding bugs.

The `design_advanced_test.py::test_reorder_elements_within_page`
functional test also still passes (single-element reorder: 'a' is
brought to front, ends up at top z — algorithm gives `a(z=3)`, test
expects 'a' at top: matches).

## Branch / commit

- Branch: `worktree/fix-reorder-elements-tests`
- Commit: `0b7befd3`
- Worktree path: `/home/ginwa/ginwaaitoolbox/.worktrees/fix-reorder-elements-tests`

## Closes

`task_1787178257311820641` — Fix pre-existing broken reorderElements
tests (now surfaced by inline refactor).
