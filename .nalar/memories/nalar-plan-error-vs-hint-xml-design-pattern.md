# nalar — Plan-vs-test mismatch: "hint" XML responses (NOT `<error>`) for valid-but-empty cases

When a plan's implementation spec for an LLM tool says "return an
error XML" for a valid-but-empty case (e.g., "kanban exists but has
0 columns"), the test expectation often conflicts with that. The
plan says wrap the message in `<error>...</error>`; the test says
the response must NOT contain `<error>` and must contain a
`<columns></columns>` (or equivalent empty body) plus a hint
substring.

## Symptom

A test asserts:
```zig
try testing.expect(!contains(xml, "<error>"));
try testing.expect(contains(xml, "<columns></columns>"));
try testing.expect(contains(xml, "no columns"));
```

But the implementation (per the plan) wraps the message in
`<kanban><error>This kanban has no columns...</error></kanban>` —
which trips BOTH assertions (contains `<error>`, does NOT contain
`<columns></columns>`).

## Why this design pattern is correct

The user-facing semantic distinction is:
- **Wrong item_id / shape mismatch / DB failure** → caller did
  something wrong → `<error>` is the right signal (LLM retries with
  corrected input).
- **Valid input, but the answer is "0 of N"** → caller did nothing
  wrong → NOT an error, just an empty body + a friendly hint that
  the LLM can ignore or surface to the user as info.

Wrapping the "empty but valid" case in `<error>` confuses the LLM
into thinking the call failed (it didn't) and may trigger
unnecessary retries or fallback tool calls.

## Fix

When implementing an LLM tool that can return either "wrong input"
or "valid input, empty result", render TWO structurally distinct
responses:
1. Error case → `<error>...</error>` block with a self-correcting
   hint ("this looks like a task_id, try item_id").
2. Empty-but-valid case → the normal response body (e.g.,
   `<columns></columns>`) PLUS a sibling `<hint>...</hint>` block
   with the friendly message. NO `<error>` wrapper.

Concretely (from `kanban_list.zig`):
```zig
const empty_board_hint: ?[]u8 = if (cols.len == 0) blk: {
    const h = try std.fmt.allocPrint(allocator,
        \\This kanban item has no columns...
    , .{});
    break :blk h;
} else null;
defer if (empty_board_hint) |h| allocator.free(h);

// Render normal XML, then splice the hint before </kanban>:
const xml = try toXml(allocator, input.workspace_id, input.item_id,
    column_summaries.items, task_summaries.items);
if (empty_board_hint) |h| {
    const close_tag = "</kanban>";
    const idx = std.mem.indexOf(u8, xml, close_tag) orelse xml.len;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, xml[0..idx]);
    try out.appendSlice(allocator, "<hint>");
    const escaped_hint = try xmlEscape(allocator, h);
    defer allocator.free(escaped_hint);
    try out.appendSlice(allocator, escaped_hint);
    try out.appendSlice(allocator, "</hint>");
    try out.appendSlice(allocator, xml[idx..]);
    allocator.free(xml);
    return try out.toOwnedSlice(allocator);
}
return xml;
```

## When this bites

- Any plan that says "return error XML" without distinguishing
  between "wrong input" and "valid input, empty result".
- The test phase usually catches this (TDD exposes the conflict
  immediately). The fix is small but requires changing the
  implementation, not the test.
- If the plan ALSO says the test should `!contains(xml, "<error>")`
  + `contains(xml, "<hint_substring>")` for the empty-but-valid
  case (like the kanban-list-fix plan did), trust the test.

## Related

- `zig-test-substring-prefix-matching-pitfall.md` — a different test
  pitfall in the same chunk (substring matches for the negative
  assertion `id: ` failing against the new `_id:` label).