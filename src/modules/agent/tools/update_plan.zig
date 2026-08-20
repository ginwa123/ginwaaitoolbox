//! Agent-callable tool: `update_plan` — UPSERT the agent's task plan for
//! the current session as markdown with a `- [ ]` / `- [x]` checklist.
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8 (Task 2 of 9)
//!
//! Wire shape:
//!   input:  { content: string }
//!   output: <update_plan>
//!            <session_id>...</session_id>
//!            <updated_at>...</updated_at>
//!            <plan><![CDATA[
//!            ...markdown body...
//!            ]]></plan>
//!          </update_plan>
//!   or:     <update_plan><error>...</error></update_plan>
//!
//! The `<plan>` block carries the just-written content (CDATA-wrapped,
//! byte-for-byte) so the LLM AND the frontend UI see the same canonical
//! body back without depending on `parameters` (the agent's input args).
//! Mirrors `get_plan`'s `<plan><![CDATA[...]]></plan>` shape exactly so
//! the frontend can reuse the same envelope parser.
//!
//! The actual UPSERT lives in `session_plan.savePlan`. This file is a
//! thin XML wrapper (mirrors the `save_memory.zig` pattern — same
//! successXml/errorXml shape, same XmlEscape for user-trusted content).
//!
//! Design choices:
//!   - `session_id` is NOT in the input (D3 — implicit from
//!     `ToolExecContext.session_id` in the exec adapter). The pure-fn
//!     API takes `session_id` as an explicit parameter so the exec
//!     adapter in Task 4 can wire `ctx.session_id` through.
//!   - Hard cap is 256 KiB (`session_plan.MAX_PLAN_BYTES`) — see D7.
//!   - Empty content is rejected (InvalidContent) — distinguishes
//!     "no plan" (use `get_plan`, see `<empty/>`) from "explicitly clear"
//!     (caller should not call update_plan with empty; use a final marker
//!     like `# Plan complete\nAll steps done.` instead).
//!   - CDATA wrapping (vs. `helpers.xml_escape`) preserves the user's
//!     exact markdown byte-for-byte; the LLM sees its own plan back
//!     without any escape substitutions. Same trade-off as `get_plan`.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const helpers = nalarcore.helpers;
const xmlEscape = helpers.xml_escape;

// Import the storage layer directly (the `nalarcore.session_plan`
// alias is wired up in src/root.zig by Task 4; for the pure-fn layer
// we just need the module itself).
const session_plan = @import("../../../ai_workflow/tui/agentic_loop/session_plan.zig");

/// Re-export the storage-layer cap so callers/tests don't have to
/// reach into the storage module. Same value (256 KiB).
pub const MAX_PLAN_BYTES: usize = session_plan.MAX_PLAN_BYTES;

/// Input for `update_plan`.
pub const UpdatePlanInput = struct {
    /// The markdown plan body. 1 byte – 256 KiB. Empty content is
    /// rejected (use a final marker like `# Plan complete` to "close"
    /// a plan instead of calling with empty). The plan body is plain
    /// markdown with `- [ ]` for todo items and `- [x]` for done.
    content: []const u8 = "",
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// tells the agent to overwrite the plan after every checklist item,
/// flipping `- [ ]` to `- [x]`.
pub const update_plan_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "update_plan",
        .description =
            \\The `update_plan` tool overwrites (UPSERT) the agent's structured task plan for the current session. The plan body is plain markdown with a `- [ ]` (todo) / `- [x]` (done) checklist.
            \\
            \\Use `update_plan` to:
            \\1. Lay out your plan BEFORE you start work, after understanding the user's request.
            \\2. Overwrite the plan AFTER completing each checklist item, flipping `- [ ]` to `- [x]`.
            \\
            \\The plan is automatically re-injected into your system prompt on every iteration,
            \\so the next agent (after compaction, restart, or sub-agent handoff) sees the
            \\same structured progress you do.
            \\
            \\Format suggestion (the agent is free to adapt):
            \\```
            \\## Goal
            \\<one-line summary>
            \\
            \\## Steps
            \\- [x] Step 1 — done
            \\- [ ] Step 2 — in progress
            \\- [ ] Step 3 — pending
            \\
            \\## Notes
            \\<free-form>
            \\```
            \\
            \\Constraints:
            \\- `content` must be 1 byte – 256 KiB. Empty content is rejected.
            \\- The tool overwrites the prior plan every time (UPSERT) — there is no merge.
            \\- `session_id` is implicit (the tool operates on the current session).
            \\- To "close out" a finished plan, call with a final marker like
            \\  `# Plan complete\nAll steps done.` — do NOT call with empty content.
            \\- To read the current plan, use the companion `get_plan` tool.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The full markdown plan body. 1 byte – 256 KiB. Replaces any existing plan. Required.",
                },
            },
            .required = &.{"content"},
        },
    },
};

/// Execute update_plan. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
///
/// `session_id` is passed explicitly (NOT via `ToolExecContext`) so this
/// pure fn is testable in isolation. The exec adapter in Task 4 will pull
/// `session_id` from `ctx.session_id` and forward it here.
///
/// The success envelope echoes the just-written `content` (CDATA-wrapped)
/// so the LLM AND the frontend UI see the canonical body back. Mirrors
/// `executeGetPlan`'s `<plan><![CDATA[...]]></plan>` shape.
pub fn executeUpdatePlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    input: UpdatePlanInput,
) ![]const u8 {
    const updated_at = session_plan.savePlan(allocator, db, .{
        .session_id = session_id,
        .content = input.content,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "content must be non-empty (1 byte minimum)",
            error.ContentTooLarge => "content exceeds the 256 KiB per-plan cap",
            error.InvalidSessionId => "session_id is required (this is a bug — exec adapter should pass ctx.session_id)",
            error.RowNotFoundAfterInsert => "row missing after UPSERT (DB inconsistency)",
            else => @errorName(err),
        };
        return errorXml(allocator, msg);
    };
    defer allocator.free(updated_at);

    return successXml(allocator, session_id, updated_at, input.content);
}

fn successXml(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    updated_at: []const u8,
    content: []const u8,
) ![]u8 {
    const sid_e = try xmlEscape(allocator, session_id);
    defer allocator.free(sid_e);
    const ts_e = try xmlEscape(allocator, updated_at);
    defer allocator.free(ts_e);

    // Build the <plan> block in CDATA. Mirrors executeGetPlan.zig so
    // the frontend can reuse the same envelope parser. CDATA preserves
    // raw `<`, `>`, `&` bytes verbatim; the only escape we need is the
    // literal `]]>` sequence (would terminate the CDATA section early).
    var plan_buf: std.ArrayList(u8) = .empty;
    defer plan_buf.deinit(allocator);

    try plan_buf.appendSlice(allocator, "<plan><![CDATA[\n");
    if (std.mem.indexOf(u8, content, "]]>") == null) {
        // Fast path — append verbatim.
        try plan_buf.appendSlice(allocator, content);
    } else {
        // Slow path — split on each `]]>` boundary, mirroring
        // session_skills' CDATA escape in enrichCompactionXml. On the
        // wire this reads as `...]]><![CDATA[>...` — the `>` between
        // `]]` and `<![CDATA[` is the escaped-then-replayed end of
        // the original sequence.
        var rest = content;
        while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
            try plan_buf.appendSlice(allocator, rest[0..idx]); // up to but NOT incl "]]"
            try plan_buf.appendSlice(allocator, "]]><![CDATA[>"); // close, reopen, literal '>'
            rest = rest[idx + 3 ..];
        }
        try plan_buf.appendSlice(allocator, rest);
    }
    try plan_buf.appendSlice(allocator, "\n]]></plan>");

    return std.fmt.allocPrint(allocator,
        "<update_plan>" ++
        "<session_id>{s}</session_id>" ++
        "<updated_at>{s}</updated_at>" ++
        "{s}" ++
        "</update_plan>",
        .{ sid_e, ts_e, plan_buf.items });
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<update_plan><error>{s}</error></update_plan>",
        .{escaped});
}
