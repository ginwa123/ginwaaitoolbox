//! Returns the enabled tool names for the agent bound to a workspace_item.
//!
//! This is the **input** to the runtime tool filter wired into
//! `workflow.zig:runAgenticMultiStepnew` (Task 12). The filter then
//! takes the returned slice and:
//!   - if non-empty: joins with `,` and passes as `allowed_tools` to
//!     `WorkflowArgs.allowed_tools` (which `filterAndMergeTools` reads)
//!   - if empty: passes `""` (empty string), which `filterAndMergeTools`
//!     interprets as "register zero tools"
//!
//! Returns empty slice (NOT error) in 3 cases (spec D1 — secure-by-default):
//!   - `workspace_item_id` doesn't exist in `workspace_items`
//!   - `workspace_items.item_type` is not `'agent'`
//!   - the agent has no rows in `agent_tools` (zero tools allowed)
//!
//! Callers MUST treat an empty slice as "no tools" — NOT as "all tools".
//! This is the central UX choice of Agent Mode: a brand-new Agent
//! without any enabled tools is a pure chat (no function calls).
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 3)
//! Spec: docs/superpowers/specs/2026-08-15-agent-mode-design.md (D1, D2)

const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

/// Resolve the enabled tool names for the agent bound to
/// `workspace_item_id`. Returns an owned slice of `[]const u8`; caller
/// must `free` each element AND the slice header (via `free` loop).
///
/// Returns `&.{}` (zero-length slice) on any "not an agent" condition.
/// Does NOT propagate "not found" as an error — the runtime filter
/// treats both "not found" and "empty allowlist" the same way (zero
/// tools). This avoids a class of bugs where a missing workspace_item
/// breaks the chat instead of silently running with no tools.
pub fn agentToolsAllowed(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]const []const u8 {
    // 1. Resolve agent_id (same as workspace_item_id per spec D3). If the
    //    workspace_item doesn't exist or isn't an agent, return empty.
    var q1 = db.query(allocator,
        "SELECT id FROM agents WHERE workspace_item_id = ?",
        &[_][]const u8{workspace_item_id},
    ) catch return &.{};
    defer q1.deinit();
    const row = (q1.next() catch null) orelse return &.{};

    // The id is the same string as workspace_item_id per D3, but we
    // still need to query by it (the index lookup is cheap). Use the
    // workspace_item_id directly since agents.id == workspace_item_id.
    // Avoid duplicating the string.
    const agent_id = workspace_item_id;
    row.deinit(allocator);

    // 2. Fetch the enabled tool names ordered by tool_name ASC.
    var q2 = db.query(allocator,
        \\SELECT tool_name FROM agent_tools
        \\WHERE agent_id = ? AND enabled = 1
        \\ORDER BY tool_name ASC
    , &[_][]const u8{agent_id}) catch return &.{};
    defer q2.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |name| allocator.free(name);
        out.deinit(allocator);
    }

    while ((q2.next() catch null)) |r| {
        defer r.deinit(allocator);
        try out.append(allocator, try allocator.dupe(u8, r.values[0]));
    }

    return try out.toOwnedSlice(allocator);
}