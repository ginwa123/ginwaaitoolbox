# Zig — `std.fmt.bufPrint` returns a slice into the buffer, NOT a new allocation

`std.fmt.bufPrint(buffer: []u8, comptime fmt: []const u8, args: anytype) ![]u8`
returns a **slice of the buffer you passed in** (up to where it wrote),
NOT a newly heap-allocated copy. If you reuse the same buffer across
loop iterations and store the returned slices, every iteration's
slices alias the same backing memory.

## Symptom

You write a loop that builds N rows of data, each with a unique id:

```zig
var items: [25]ItemSeed = undefined;
for (items[0..], 0..) |*it, i| {
    const id_buf = try alloc.alloc(u8, 16);    // ← ONE buffer per loop
    const id_str = std.fmt.bufPrint(id_buf, "wi_{d}", .{i}) catch unreachable;
    it.id = id_str;                            // ← every it.id is a slice of id_buf
}
defer for (items[0..]) |it| alloc.free(it.id); // ← double-free on iterations 2..N
```

Compile passes, but at the `defer` you get `thread panic: Invalid free`
(`std/heap/debug_allocator.zig:885`) on iteration 2+ — the canary check
detects that `id_buf` was already freed by iteration 1, or that the
buffer pointer no longer points at valid heap memory.

If the loop only ran ONCE (or each iteration allocated its own buffer),
the bug would not appear — that's why single-row tests don't catch it.

## The fix

Use `std.fmt.allocPrint(allocator, ...)` (which allocates a new heap
buffer each call) when you intend to **store** the result past the
end of the loop iteration:

```zig
for (items[0..], 0..) |*it, i| {
    const id_owned = try std.fmt.allocPrint(alloc, "wi_{d}", .{i});
    errdefer alloc.free(id_owned);
    it.id = id_owned;   // each it.id has its own heap backing
}
```

Keep `std.fmt.bufPrint` only for **immediate-use** strings (e.g.,
formatting into a local stack buffer that's read once and discarded).

## Why this bites Zig specifically

In Zig, slices are `(ptr, len)` headers — sharing a slice header
across multiple owners (a `var items: [N]ItemSeed` plus a `defer`
that frees every entry) silently aliases if the underlying buffer
is the same. Languages with reference semantics (Python, Java)
would never see this bug because strings are immutable handles;
Rust would catch it at compile time via the borrow checker.
Zig has neither — it trusts you to know when a slice is borrowed
vs owned.

## How to verify after a fix

The failure mode is "Invalid free" on `defer free(it.id)`. Replace
`bufPrint` with `allocPrint` and re-run; the panic disappears and the
test runs cleanly.

## When this bites

- Any test that builds N rows in a loop with dynamically formatted ids/names
  and then `defer`s a per-row cleanup.
- Helpers that fan out and reuse a scratch buffer (logger formatters,
  request-id generators, etc.).
- The specific case in this codebase: `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig`
  tests 4 and 5 (25 items + 8 tasks) hit this when each row tried to
  share a single `id_buf` across iterations.
