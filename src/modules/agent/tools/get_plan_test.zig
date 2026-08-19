//! Behavioural tests for `get_plan.zig` — the agent-callable tool
//! that fetches the session's markdown plan via `session_plan.getPlan`.
//!
//! Pattern mirrors `update_plan_test.zig` — in-memory DB + full migrations
//! walk + assert on the wire XML envelope (present / absent).
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8 (Task 3 of 9)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");

const get_plan_mod = @import("get_plan.zig");
const update_plan_mod = @import("update_plan.zig");
const session_plan = @import("../../../ai_workflow/tui/agentic_loop/session_plan.zig");

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

// ─── Test 1: present — returns the plan wrapped in CDATA inside <plan> ──────

test "executeGetPlan: returns the plan when present, wrapped in CDATA" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed a plan via update_plan (the same wire the agent will use).
    const session_id = "test_session_present";
    const seed_result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = "# Plan\n- [x] done\n- [ ] pending\n",
    });
    defer alloc.free(seed_result);

    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, session_id);
    defer alloc.free(result);

    // Envelope shape:
    //   <get_plan><plan><![CDATA[
    //   <markdown body>
    //   ]]></plan></get_plan>
    try testing.expect(std.mem.indexOf(u8, result, "<get_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</get_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</plan>") != null);
    // CDATA wrappers present (so the raw `<`, `>` inside the markdown body
    // cannot break the envelope — mirrors the enrichCompactionXml
    // session_skills pattern).
    try testing.expect(std.mem.indexOf(u8, result, "<![CDATA[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "]]>") != null);
    // No <empty/> when present.
    try testing.expect(std.mem.indexOf(u8, result, "<empty/>") == null);

    // Markdown body parts (CDATA preserves raw chars verbatim).
    try testing.expect(std.mem.indexOf(u8, result, "# Plan") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[x] done") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[ ] pending") != null);
}

// ─── Test 2: absent — returns <empty/> per D6 ───────────────────────────────

test "executeGetPlan: returns <empty/> when no plan exists (D6)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // No prior update_plan call — session has no row in session_plan.
    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, "nonexistent");
    defer alloc.free(result);

    // Envelope shape: <get_plan><empty/></get_plan>
    try testing.expect(std.mem.indexOf(u8, result, "<get_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<empty/>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</get_plan>") != null);
    // No <plan> tag when absent — the agent should use the absence
    // signal as a "use update_plan to lay out a plan" cue.
    try testing.expect(std.mem.indexOf(u8, result, "<plan>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "</plan>") == null);
    // No CDATA section either (nothing to wrap).
    try testing.expect(std.mem.indexOf(u8, result, "<![CDATA[") == null);
}

// ─── Test 3: XML escape — CDATA preserves raw chars verbatim ───────────────

test "executeGetPlan: CDATA preserves raw special chars verbatim (no XML escape)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Write a plan containing `<hello>` and `&` — these MUST survive
    // verbatim inside the CDATA section (no &lt; / &amp; substitution).
    const session_id = "test_session_escape";
    const seed_result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = "Note: <hello> & 'world'",
    });
    defer alloc.free(seed_result);

    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, session_id);
    defer alloc.free(result);

    // Raw `<hello>` and `&` MUST appear inside the CDATA verbatim —
    // that's the whole point of using CDATA for free-form content.
    try testing.expect(std.mem.indexOf(u8, result, "<hello>") != null);
    try testing.expect(std.mem.indexOf(u8, result, " & ") != null);
    // The XML-escaped forms MUST NOT appear — that's the alternative
    // approach (helpers.xml_escape + non-CDATA envelope) which we
    // explicitly avoid here. If a future refactor accidentally drops
    // the CDATA wrapping, the assertions below will fail closed.
    try testing.expect(std.mem.indexOf(u8, result, "&lt;hello&gt;") == null);
    try testing.expect(std.mem.indexOf(u8, result, "&amp;") == null);
}

// ─── Test 4: CDATA split on `]]>` boundary ──────────────────────────────────

test "executeGetPlan: splits CDATA on `]]>` boundary inside plan body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Embed a literal `]]>` sequence — the CDATA section MUST split
    // (mirror of the enrichCompactionXml session_skills pattern at
    // workflow_compact_message.zig).
    const session_id = "test_session_cdata";
    const seed_result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = "before ]]> middle ]]> after",
    });
    defer alloc.free(seed_result);

    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, session_id);
    defer alloc.free(result);

    // The two `]]>` sequences must be split into adjacent CDATA sections
    // so the envelope is still well-formed XML, with the literal `>`
    // reappearing between them (close current + reopen with the `>`
    // as content of the new section).
    try testing.expect(std.mem.indexOf(u8, result, "before ]]><![CDATA[> middle ]]><![CDATA[> after") != null);
}

// ─── Test 5: JSON schema shape (name / required / properties) ───────────────

test "get_plan_tool JSON schema: name='get_plan', no required params, no properties" {
    const tool = get_plan_mod.get_plan_tool;

    // Top-level type must be 'function' (OpenAI conventions).
    try testing.expectEqualStrings("function", tool.type);

    // Function name.
    try testing.expectEqualStrings("get_plan", tool.function.name);

    // Description must mention the tool name AND the <empty/> absent
    // signal — the description is the agent's primary "when to call
    // this" signal.
    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "get_plan") != null);
    try testing.expect(std.mem.indexOf(u8, description, "<empty/>") != null);

    // Required: empty slice — get_plan needs no input (D3 — session_id
    // is implicit).
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.required.len);

    // Properties: empty slice — no input parameters at all.
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.properties.len);
}
