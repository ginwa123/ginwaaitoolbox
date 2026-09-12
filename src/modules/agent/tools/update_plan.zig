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
//! thin XML wrapper (mirrors the `memory.zig` save_memory pattern — same
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

const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;

// Import the storage layer directly (the `nalarcore.session_plan`
// alias is wired up in src/root.zig by Task 4; for the pure-fn layer
// we just need the module itself).
const session_plan = @import("../../../agentic_loop/session_plan.zig");

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
pub const update_plan_tool_system_prompt =
    \\## Update Plan Tool — Behavior
    \\Use `update_plan` to create or overwrite the session's markdown plan (checklist with `- [ ]` / `- [x]`).
    \\- Call early for multi-step work and after each step to flip the checkbox. The plan is re-injected into your prompt every iteration.
    \\- Content must be 1 byte–256 KiB. Empty content is rejected.
    \\
;

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
        .system_prompt = update_plan_tool_system_prompt,
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

const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

const update_plan_mod = @import("update_plan.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: success path returns the successXml envelope ──────────────────

test "executeUpdatePlan: success returns successXml with session_id + updated_at + <plan> CDATA" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_success";
    const content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n";
    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = content,
    });
    defer alloc.free(result);

    // Envelope shape:
    //   <update_plan>
    //     <session_id>...</session_id>
    //     <updated_at>...</updated_at>
    //     <plan><![CDATA[ ...content... ]]></plan>
    //   </update_plan>
    try testing.expect(std.mem.indexOf(u8, result, "<update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<updated_at>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</updated_at>") != null);
    // <plan> CDATA block must be present — the frontend reads it
    // back from here to render the checklist preview.
    try testing.expect(std.mem.indexOf(u8, result, "<plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<![CDATA[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "]]></plan>") != null);
    // Content bytes land verbatim inside CDATA — no XML escaping.
    try testing.expect(std.mem.indexOf(u8, result, content) != null);
    // No <error> tag on success.
    try testing.expect(std.mem.indexOf(u8, result, "<error>") == null);
    // session_id MUST be echoed (escaped form, but plain alphanumeric here).
    try testing.expect(std.mem.indexOf(u8, result, session_id) != null);

    // DB read-back — verify the row actually landed with the right content.
    const stored = try session_plan.getPlan(alloc, &ctx.db, session_id);
    defer alloc.free(stored);
    try testing.expectEqualStrings(content, stored);
}

// ─── Test 1b: CDATA preserves raw special chars verbatim ───────────────────
//
// Mirrors `get_plan_test.zig` "CDATA preserves raw special chars verbatim".
// The agent may write `<`, `>`, `&` in their plan markdown (e.g. for
// comparison prose like `arr[i] > 0`). CDATA wrapping means these
// land byte-for-byte in the envelope — no XML escape substitutions
// that would complicate the LLM's regex/checklist matching.

test "executeUpdatePlan: CDATA preserves raw <, >, & inside plan body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const content = "## Notes\nIf arr[i] > 0 && x < 10, then... & done.";
    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "cd_session", .{
        .content = content,
    });
    defer alloc.free(result);

    // The raw bytes must appear verbatim — NOT escaped to &lt; / &gt; / &amp;.
    try testing.expect(std.mem.indexOf(u8, result, "arr[i] > 0") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x < 10") != null);
    try testing.expect(std.mem.indexOf(u8, result, "&& x") != null);
    // None of the escape substitutions should appear.
    try testing.expect(std.mem.indexOf(u8, result, "&lt;") == null);
    try testing.expect(std.mem.indexOf(u8, result, "&gt;") == null);
    try testing.expect(std.mem.indexOf(u8, result, "&amp;") == null);
}

// ─── Test 1c: literal "]]>" inside the body splits the CDATA section ──────
//
// Mirrors `get_plan_test.zig` "splits CDATA on `]]>` boundary inside plan
// body". The literal `]]>` sequence would terminate the CDATA section
// early and break the XML envelope — the successXml helper splits it
// into `]]><![CDATA[>` so the `>` between them becomes plain content.

test "executeUpdatePlan: splits CDATA on ]]> boundary inside plan body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const content = "before ]]> middle ]]> after";
    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "cdata_split_session", .{
        .content = content,
    });
    defer alloc.free(result);

    // The split sequence `]]><![CDATA[>` must appear at least twice
    // (once per `]]>` in the body) so the envelope stays well-formed.
    var count: usize = 0;
    var rest: []const u8 = result;
    while (std.mem.indexOf(u8, rest, "]]><![CDATA[>")) |idx| {
        count += 1;
        rest = rest[idx + "]]><![CDATA[>".len ..];
    }
    try testing.expectEqual(@as(usize, 2), count);

    // The envelope MUST still be a single well-formed <plan> block
    // (not two halves).
    try testing.expect(std.mem.indexOf(u8, result, "<plan><![CDATA[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "]]></plan>") != null);
}

// ─── Test 2: empty content is rejected with a "non-empty" error ────────────

test "executeUpdatePlan: empty content returns errorXml mentioning 'non-empty'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "any_session", .{
        .content = "",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "non-empty") != null);
    // No <session_id> or <updated_at> on error.
    try testing.expect(std.mem.indexOf(u8, result, "<updated_at>") == null);

    // DB has no row for "any_session".
    const stored = try session_plan.getPlan(alloc, &ctx.db, "any_session");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

// ─── Test 3: oversized content is rejected with a "256 KiB" error ──────────

test "executeUpdatePlan: oversized content (> MAX_PLAN_BYTES) returns errorXml mentioning '256 KiB'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate MAX_PLAN_BYTES + 1 byte of garbage.
    const big = try alloc.alloc(u8, update_plan_mod.MAX_PLAN_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "big_session", .{
        .content = big,
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</error>") != null);
    // Exact phrasing is '256 KiB' (per the plan's error mapping).
    try testing.expect(std.mem.indexOf(u8, result, "256 KiB") != null);
}

// ─── Test 4: JSON schema shape (name / required / properties) ──────────────

test "update_plan_tool JSON schema: name='update_plan', required=['content'], properties=[content]" {
    const tool = update_plan_mod.update_plan_tool;

    // Top-level type must be 'function' (OpenAI conventions).
    try testing.expectEqualStrings("function", tool.type);

    // Function name.
    try testing.expectEqualStrings("update_plan", tool.function.name);

    // Description must mention both the tool name and the checklist pattern
    // — the description is the agent's primary "when to call this" signal.
    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "update_plan") != null);
    try testing.expect(std.mem.indexOf(u8, description, "checklist") != null);

    // Required: exactly ["content"] — session_id is implicit (D3).
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.required.len);
    try testing.expectEqualStrings("content", tool.function.parameters.required[0]);

    // Properties: exactly one (content) — no session_id parameter.
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.properties.len);
    try testing.expectEqualStrings("content", tool.function.parameters.properties[0].name);
    try testing.expectEqualStrings("string", tool.function.parameters.properties[0].type);
}
