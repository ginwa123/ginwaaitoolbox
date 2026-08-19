//! Agent-callable tool: `get_plan` — fetch the agent's current task plan
//! for the current session as markdown.
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8 (Task 3 of 9)
//!
//! Wire shape:
//!   input:  {} (no params — session_id is implicit per D3)
//!   output: <get_plan><plan><![CDATA[...markdown...]]></plan></get_plan>
//!   or:     <get_plan><empty/></get_plan> (when no plan set, per D6)
//!
//! The actual read lives in `session_plan.getPlan`. This file is a
//! thin XML wrapper around it (mirrors the `load_memory.zig` pattern —
//! thin wrapper around `agent_memories.loadMemoriesByFts`).
//!
//! CDATA wrapping: the plan content is wrapped in CDATA so the raw
//! `<`, `>`, `&` inside user-written markdown never breaks the XML
//! envelope. Mirrors the `enrichCompactionXml` session_skills
//! section at `workflow_compact_message.zig:409` — including the
//! `]]>` boundary split (line 414), which is the same edge case
//! (literal `]]>` inside the body would otherwise terminate the
//! CDATA section early and break the XML envelope).
//!
//! Design choices:
//!   - `session_id` is NOT in the input (D3 — implicit from
//!     `ToolExecContext.session_id` in the exec adapter). The pure-fn
//!     API takes `session_id` as an explicit parameter so this file
//!     stays testable in isolation (mirrors `executeUpdatePlan`).
//!   - No `<session_id>` echo in the success XML (mirrors
//!     `load_memory`'s omission — the LLM already knows which session
//!     it's operating on; echoing wastes context).
//!   - CDATA wrapping (vs. `helpers.xml_escape`) preserves the
//!     user's exact markdown byte-for-byte; the agent sees its own
//!     plan back without any escape substitutions that would
//!     complicate regex/checklist matching in the LLM.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

// Import the storage layer directly (the `nalarcore.session_plan`
// alias is wired up in src/root.zig by Task 4; for the pure-fn layer
// we just need the module itself). Same pattern as update_plan.zig.
const session_plan = @import("../../../ai_workflow/tui/agentic_loop/session_plan.zig");

/// Input for `get_plan`. Empty struct — no params, session_id is implicit.
pub const GetPlanInput = struct {};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to call this tool — it explicitly
/// mentions the `<empty/>` absent signal so the agent knows to use
/// `update_plan` to lay out a plan when it sees the empty result.
pub const get_plan_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_plan",
        .description =
            \\Fetch the agent's current task plan for this session. Returns the markdown body wrapped in `<plan><![CDATA[...]]></plan>`, or `<empty/>` when no plan has been set yet (use `update_plan` to lay one out).
            \\
            \\The plan is also re-injected into your system prompt on every iteration, so calling `get_plan` is mostly useful for explicit verification, or after you've made several changes and want to see the current state without scrolling back through the system prompt.
            \\
            \\Use this tool to:
            \\1. Verify the current plan before flipping a `- [ ]` to `- [x]` in `update_plan`.
            \\2. Confirm `<empty/>` before laying out your first plan with `update_plan` (e.g. after a session handoff where the new agent didn't inherit a plan).
            \\3. Re-read the plan after a compaction event, to check that the auto-injected copy matches what you expect.
            \\
            \\The output is wrapped in XML CDATA, so the raw `<`, `>`, `&` inside the markdown body are preserved verbatim — the LLM sees its own plan back byte-for-byte.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

/// Execute get_plan. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
///
/// `session_id` is passed explicitly (NOT via `ToolExecContext`) so this
/// pure fn is testable in isolation. The exec adapter in Task 4 will pull
/// `session_id` from `ctx.session_id` and forward it here.
pub fn executeGetPlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    // session_plan.getPlan returns an allocated copy of the markdown body,
    // or an allocated "" when absent (canonical "no plan" sentinel).
    const plan = try session_plan.getPlan(allocator, db, session_id);
    defer allocator.free(plan);

    if (plan.len == 0) {
        return allocator.dupe(u8, "<get_plan><empty/></get_plan>");
    }

    // Present branch: wrap the plan body in CDATA inside <plan>...</plan>.
    // CDATA preserves the raw `<`, `>`, `&` bytes verbatim — no XML
    // escape substitution. The only escape we DO need is splitting
    // on the literal `]]>` sequence, which would otherwise terminate
    // the CDATA section early and break the XML envelope.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<get_plan><plan><![CDATA[\n");
    if (std.mem.indexOf(u8, plan, "]]>") == null) {
        // Fast path: no `]]>` in the body — append verbatim.
        try out.appendSlice(allocator, plan);
    } else {
        // Slow path: split on each `]]>` boundary, mirroring the
        // session_skills CDATA escape in enrichCompactionXml at
        // workflow_compact_message.zig:414. We close the current
        // CDATA section with the `]]` (already in the data), reopen
        // with `<![CDATA[`, and emit the literal `>` as content of
        // the new section. On the wire this reads as
        // `...]]><![CDATA[>...` — the `>` between `]]` and `<![CDATA[`
        // is the escaped-then-replayed end of the original sequence.
        var rest = plan;
        while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
            try out.appendSlice(allocator, rest[0..idx]); // up to but NOT incl "]]"
            try out.appendSlice(allocator, "]]><![CDATA[>"); // close current, reopen, literal '>'
            rest = rest[idx + 3 ..];
        }
        try out.appendSlice(allocator, rest);
    }
    try out.appendSlice(allocator, "\n]]></plan></get_plan>");
    return out.toOwnedSlice(allocator);
}
