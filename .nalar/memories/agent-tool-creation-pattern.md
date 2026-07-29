# Agent tool that creates a child resource of a workspace_item

## What

Adding a new LLM-callable tool that creates a child resource (e.g. a kanban task under an item, a design element under a page). Mirrors `kanban_list` / `kanban_move_task` / `set_design_page` — reads DB directly via `nalarcore.ai_mod.*` helpers, never goes through HTTP.

## File touch map (~9 files)

| File | Action | Notes |
|---|---|---|
| `src/modules/agent/tools/<name>.zig` | NEW | Tool definition + `executeXxxToString(allocator, db, input) ![]u8` |
| `src/modules/agent/tools/<name>_test.zig` | NEW | 6 wire-shape + 9-11 behavioral + 5 registration tests |
| `src/modules/agent/tools/test_runner.zig` | EDIT | Add `_ = @import("<name>_test.zig");` (one line) |
| `src/root.zig` | EDIT | Add `pub const <name> = @import("modules/agent/tools/<name>.zig");` |
| `src/ai_workflow/tui/agentic_loop/tools_exec_<name>.zig` | NEW | The standard LLM-callable wrapper (parse + call + wrap) |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | EDIT | Add `pub const exec<Name> = @import("tools_exec_<name>.zig").exec<Name>;` |
| `src/ai_workflow/tui/agentic_loop/tool_registry.zig` | EDIT | Add the import + the registry entry in the right group |
| `src/ai_workflow/tui/agentic_loop/test_runner.zig` | EDIT (if needed) | Auto-discovers via `tools.zig` imports — usually no manual addition |
| `src/modules/test_runner.zig` / `src/ai_workflow/tui/test_runner.zig` | EDIT | Usually auto-discovers |

## Output XML convention

LLM-friendly XML wrappers. Two helpers in the tool file:

```zig
fn errorXml(allocator, error_msg: []const u8) ![]u8    // borrows input, dups internally
fn errorXmlOwned(allocator, error_msg: []u8) ![]u8    // frees the input
```

Use `errorXmlOwned` when the caller has a heap-allocated `std.fmt.allocPrint(...)` result
and wants to free it cleanly. Use `errorXml` for string literals (the `dupe` cost is fine).

## Anti-pattern: returning the error XML as a success value

`![]u8` where the error XML is returned via `return try errorXml(...)` confuses the
caller's `catch`. The `catch` only fires for Zig error values, NOT for successful
returns of `[]u8`. Use `!?[]u8` with `null = success`, `[]u8 = error XML` instead
(matches `validateItemTypeIsKanban` in `create_kanban_task.zig`).

## Pattern: validate column BEFORE inserting

When creating a child resource that needs a parent column/section:

1. Validate parent exists + correct type (`item_type='kanban'`)
2. Validate target column exists (auto-assign or explicit)
3. THEN insert
4. THEN assign the column

If you insert first and validate second, the error path leaks the inserted row +
its heap allocations. Reordering makes the error path cheap.

## Cross-platform / cross-compile

The tool file uses `helpers.unixTimestampNanos()` (cross-platform) for ID generation
and `nalarcore.ai_mod.*` helpers for DB access (cross-platform via Zig 0.16's
`std.c.*`). No `std.posix.*` direct calls.

Verify with:
```bash
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
```

## When to use this pattern

- Adding a new agent tool that creates/updates a workspace_item child resource
- Adding a tool that emits an LLM-facing XML response
- Adding a tool that needs both `error` and `success` response shapes

## When NOT to use this pattern

- Adding a tool that's read-only (use the `kanban_list` / `set_design_page` pattern
  — simpler, no INSERT/UPDATE, no SSE emit, no error XML needed for validation
  paths)
- Adding a tool that's just a wrapper around an existing HTTP endpoint (use the
  HTTP round-trip pattern; rare in this codebase — none exist currently)