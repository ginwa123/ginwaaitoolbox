//! Render the "## Current Plan" markdown block for the LLM's system
//! prompt. Reads the session's `session_plan` row (Migration 076) and
//! emits a fenced markdown block plus the timestamp footer. Returns
//! `""` (a 0-byte heap-owned slice) when no plan exists for the
//! session, so the caller can omit the section silently — matching
//! `makeKanbanContext`'s empty-case behaviour.
//!
//! Block shape (omitted when no row exists, when `session_id` is
//! empty, or when the DB lookup fails):
//!
//! ```markdown
//! ## Current Plan
//!
//! This session has an active task plan. **You MUST keep it in sync**
//! by calling the `update_plan` tool after completing each checklist
//! item (flip `- [ ]` → `- [x]`). The plan is automatically re-injected
//! into your system prompt on every iteration, so you always see the
//! current state.
//!
//! ```markdown
//! <full plan body, raw>
//! ```
//!
//! _Last updated: <iso timestamp>_
//! ```
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task 5 of 9

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const session_plan = nalarcore.session_plan;

/// Build a "## Current Plan" section for the system prompt. Reads
/// `session_plan` for the current `session_id` and renders the
/// markdown inside a labelled block, with explicit instructions for
/// the agent to call `update_plan` after every checklist item.
///
/// Returns `""` (a 0-byte heap-owned slice) when:
///   - `session_id.len == 0`
///   - no row exists in `session_plan` for this session
///   - the DB lookup fails (logged via `std.log.warn`)
/// so the caller can omit the section silently — matches the
/// `makeKanbanContext` / `makeDesignContext` pattern.
pub fn makePlanContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    // 1. Read the plan row (graceful-skip on DB error so the system
    //    prompt never breaks because of a plan lookup failure —
    //    mirrors `makeKanbanContext`'s pattern).
    const row = session_plan.getPlanOpt(allocator, db, session_id) catch |err| {
        std.log.warn("BuildPlanContext: getPlanOpt failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer if (row) |r| r.deinit(allocator);

    const plan_row = row orelse return allocator.dupe(u8, "");

    // 2. Render the markdown block.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Current Plan\n\n");
    try out.appendSlice(allocator,
        \\This session has an active task plan. **You MUST keep it in sync** by
        \\calling the `update_plan` tool after every checklist item (flip
        \\`- [ ]` → `- [x]`). The plan is automatically re-injected into your
        \\system prompt on every iteration, so you always see the current state.
        \\
    );

    // Wrap the raw plan body in a markdown fence so the agent's parser
    // treats it as a code block rather than as top-level instructions.
    // The plan content may contain backticks / bold / headings — the
    // fence prevents any plan content from hijacking the outer
    // prompt's structure.
    try out.appendSlice(allocator, "```markdown\n");
    try out.appendSlice(allocator, plan_row.plan_md);
    // Ensure the plan body ends with a newline so the closing fence
    // can never fuse with the trailing lines of the plan body.
    if (plan_row.plan_md.len == 0 or plan_row.plan_md[plan_row.plan_md.len - 1] != '\n') {
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "```\n");

    if (plan_row.updated_at.len > 0) {
        try out.appendSlice(allocator, "\n_Last updated: ");
        try out.appendSlice(allocator, plan_row.updated_at);
        try out.appendSlice(allocator, "_\n");
    }

    return out.toOwnedSlice(allocator);
}
