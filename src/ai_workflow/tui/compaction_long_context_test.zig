const std = @import("std");
const testing = std.testing;
const workflow = @import("workflow.zig");
const agent = @import("nalarcore").agent;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("llm_history.zig");
const logger_mod = @import("nalarcore").loggermod;

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  finish_reason TEXT,
        \\  role TEXT,
        \\  tool_calls_json TEXT,
        \\  tool_call_id TEXT,
        \\  reasoning_content TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  loop_index INTEGER DEFAULT 0,
        \\  temperature REAL DEFAULT 0.2,
        \\  is_thinking INTEGER DEFAULT 0,
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  updated_at TEXT DEFAULT (datetime('now')),
        \\  parent_session_id TEXT,
        \\  parent_id TEXT,
        \\  prompt_tokens INTEGER DEFAULT 0,
        \\  completion_tokens INTEGER DEFAULT 0,
        \\  total_tokens INTEGER DEFAULT 0,
        \\  is_input INTEGER DEFAULT 0,
        \\  is_output INTEGER DEFAULT 0,
        \\  tool_name TEXT,
        \\  diffview_before TEXT,
        \\  diffview_after TEXT,
        \\  image_url TEXT,
        \\  -- Mirrors Migration 059: regular TEXT column populated by
        \\  -- application code (defaults to now UTC in tests).
        \\  created_iso TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, name TEXT, status TEXT, created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')))
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "end-to-end: compaction envelope is queryable via getCompactedMessages" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Build a 6-message fixture (system + 5 dropped). Capture the
    // DB ids we'll write for the dropped messages so we can verify
    // they show up in the read tool's output AFTER compaction.
    const session_id = "sess_e2e_1";
    const dropped_ids = [_][]const u8{ "h_real_1", "h_real_2", "h_real_3", "h_real_4", "h_real_5" };
    const dropped_contents = [_][]const u8{
        "Fix the login bug",
        "I'll investigate the auth flow",
        "running tests now",
        "tests pass: 42/42",
        "shipping the patch",
    };
    const dropped_roles = [_][]const u8{ "user", "assistant", "assistant", "tool", "user" };

    // Pre-seed the DB with realistic ids (so the agent can fetch them after compaction).
    for (dropped_ids, dropped_contents, dropped_roles) |id, content, role| {
        const sql =
            \\INSERT INTO llm_history (id, session_id, model, response_content, role, is_feed_to_llm, created_at, tool_call_id, tool_name)
            \\VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
        ;
        const created_at = "2025-01-01 00:00:00";
        var tcid_buf: [16]u8 = undefined;
        const tcid = if (std.mem.eql(u8, role, "tool")) std.fmt.bufPrint(&tcid_buf, "tc_{s}", .{id}) catch "" else "";
        const tname = if (std.mem.eql(u8, role, "tool")) "bash" else "";
        try s.db.exec(alloc, sql, &.{ id, session_id, "gpt-4o", content, role, created_at, tcid, tname });
    }

    // Build the in-memory message list and compact it.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "You are a coding agent.") });
    for (dropped_contents, 0..) |content, i| {
        const role_str = dropped_roles[i];
        const role_enum = std.meta.stringToEnum(agent.Role, role_str) orelse .user;
        try messages.append(alloc, .{
            .role = role_enum,
            .content = try alloc.dupe(u8, content),
            .tool_call_id = if (std.mem.eql(u8, role_str, "tool")) try alloc.dupe(u8, "tc_x") else null,
        });
    }
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership (T → !T).

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "GOAL: ship the fix\nNEXT: deploy",
        session_id, "gpt-4o", "/tmp", &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    // Now exercise getCompactedMessages in both modes.

    // INDEX MODE: should return the 5 dropped messages.
    const index_results = try llm_history.getCompactedMessages(alloc, &s.db, session_id, .{});
    defer {
        for (index_results) |*m| m.deinit(alloc);
        alloc.free(index_results);
    }
    try testing.expectEqual(@as(usize, 5), index_results.len);
    for (dropped_ids) |id| {
        // The read tool returns rows by their pre-seeded h_real_* ids
        // (the in-memory messages in this test don't set .id, so the
        // envelope uses "unknown" placeholders — but the DB rows still
        // carry the real h_real_* ids and are findable here). The
        // separate "envelope ids are real DB ids" test in
        // workflow_compaction_envelope_test.zig verifies the contract
        // when the in-memory messages DO set .id.
        try testing.expect(std.mem.indexOf(u8, id, "h_real_") == null or index_results.len > 0);
    }
    // Verify the h_real_ ids appear in the read tool's results
    var found_real = [_]bool{ false, false, false, false, false };
    for (index_results) |m| {
        for (dropped_ids, 0..) |id, idx| {
            if (std.mem.eql(u8, m.id, id)) found_real[idx] = true;
        }
    }
    for (found_real) |found| {
        try testing.expect(found);
    }
    // And verify the tool result for the tool role includes tool_name
    for (index_results) |m| {
        if (std.mem.eql(u8, m.role, "tool")) {
            try testing.expect(m.tool_name != null);
            try testing.expectEqualStrings("bash", m.tool_name.?);
        }
    }
}
