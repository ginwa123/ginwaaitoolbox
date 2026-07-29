# Conditional prompt block — gated on tool equipped (dynamic helper)

## Symptom

You want a dynamic prompt helper (one that reads the DB, like
`makeKanbanContext`) to append a section that only shows when a
specific tool is equipped for the session.

## Pattern (vs the static-section `.requires_tool`)

The `prompts.zig` static-section pattern uses `requires_tool`:

```zig
.{ .name = "global_memory_system", .content = GlobalMemorySystem,
   .requires_tool = "list_memory" }
```

This works for STATIC content. For DYNAMIC helpers (DB-querying,
session-aware, parameter-dependent), use a runtime check at the
end of the helper body, gated on a `tools: []const AgentTool`
parameter passed from the caller.

## Implementation

```zig
pub fn makeKanbanContext(
    allocator, db, session_id,
    tools: []const nalarcore.tool_models.AgentTool,  // ← new param
) ![]const u8 {
    // ... existing logic ...

    // Compute the gate ONCE — used at the end:
    const follow_up_tool_equipped = hasToolByName(tools, "create_kanban_task");

    // ... render the main block ...

    // Append conditional section:
    if (follow_up_tool_equipped) {
        try out.appendSlice(allocator, ...);
    }
    return out.toOwnedSlice(allocator);
}

fn hasToolByName(
    tools: []const nalarcore.tool_models.AgentTool, name: []const u8,
) bool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.function.name, name)) return true;
    }
    return false;
}
```

Caller updates:

```zig
// build_messages_for_agent_prompt.zig
const kanbanStatusContent = try agentic_loop.prompts_mod.makeKanbanContext(
    allocator, db, session_id, tools,  // ← pass tools
);
```

Tests update to pass an empty `&[_]AgentTool{}` slice for the
"tool not equipped" path. Then add new behavioral tests with
real `AgentTool` entries to verify the conditional rendering.

## Pitfalls

- **Don't filter tools at the caller.** Pass the full slice and let
  the helper filter — keeps tool-equipping logic co-located with the
  prompt that uses it.
- **Linear scan is fine.** Tool lists are small (~10-30). Don't add
  a hash map unless profiling shows it matters.
- **Use `function.name`, not `type` or any other field.** `type` is
  always `"function"` for LLM tools; the discriminator is
  `function.name`.
- **Pass `&[_]nalarcore.tool_models.AgentTool{}` (empty slice) in
  existing tests** to preserve prior behavior — don't pre-populate
  with `create_kanban_task` unless the test is specifically about
  the conditional rendering.

## When to use

- Adding a tool-discovery nudge: "if you have X equipped, mention Y"
- Conditional guidance that's better than zero (so always include the
  empty-tools case)
- Cross-section coordination (e.g. a follow-up hint that only makes
  sense if the tool that creates follow-ups is equipped)

## When NOT to use

- The content is purely static — use the `requires_tool` pattern on
  the static Section in `prompts.zig` instead.
- The gating depends on a non-tool condition (parent item_type,
  user role, time of day, etc.) — add the condition directly to the
  helper instead of routing through `tools`.