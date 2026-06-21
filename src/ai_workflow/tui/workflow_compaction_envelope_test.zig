const std = @import("std");
const testing = std.testing;
const workflow = @import("workflow.zig");
const agent = @import("nalarcore").agent;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("llm_history.zig");
const logger_mod = @import("nalarcore").logger;

/// Build a minimal in-memory SQLite DB with the tables that
/// compactMessageInMemoryNew touches: llm_history (for saveMessage +
/// markMessageNotForLlmRun) and sessions (for the cwd UPDATE).
/// Mirrors the test setup in src/ai_workflow/tui/llm_history_routines_test.zig.
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema — exactly the columns saveMessage writes and
    // markMessageNotForLlmRun updates. ORDER matches the production
    // CREATE TABLE in src/ai_workflow/tui/migration.zig (latest rev).
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
        \\  image_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  cwd TEXT,
        \\  name TEXT,
        \\  status TEXT,
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  updated_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

/// Build a synthetic in-memory message list shaped like the agent's
/// real messages: [system, user-1, assistant-1, tool-result-1, user-2, assistant-2].
/// Uses allocator.dupe'd slices so compactMessageInMemoryNew can free
/// them safely after compaction.
fn buildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
    var list: std.ArrayList(agent.AgentMessage) = .empty;
    try list.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "You are a coding agent."),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Fix the login bug"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I'll investigate"),
    });
    try list.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "tests pass: 42/42"),
        .tool_call_id = try allocator.dupe(u8, "tc_1"),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Now ship it"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "Shipping."),
    });
    return list;
}

test "compactMessageInMemoryNew: envelope contains metadata header" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const messages = try buildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const compacted_xml =
        \\GOAL: fix login
        \\NEXT ACTION: ship it
    ;

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc,
        messages,
        compacted_xml,
        "sess_123",
        "gpt-4o",
        "/tmp",
        &s.db,
        s.threaded.io(),
        &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), new_messages.items.len); // [system, compact_summary]
    const summary = new_messages.items[1].content.?;
    try testing.expect(std.mem.indexOf(u8, summary, "<compact_messages>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</compact_messages>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<session_id>sess_123</session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<model>gpt-4o</model>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<original_count>6</original_count>") != null);
    // Compactor's summary text is preserved inside <summary>...</summary>
    try testing.expect(std.mem.indexOf(u8, summary, "<summary>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "GOAL: fix login") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "NEXT ACTION: ship it") != null);
    // The <compacted_at> tag must exist and be non-empty
    try testing.expect(std.mem.indexOf(u8, summary, "<compacted_at>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</compacted_at>") != null);
    const ca_tag = std.mem.indexOf(u8, summary, "<compacted_at>").?;
    const ca_close = std.mem.indexOf(u8, summary, "</compacted_at>").?;
    try testing.expect(ca_close > ca_tag + "<compacted_at>".len);
}

test "compactMessageInMemoryNew: message_index lists every dropped message with id, role, preview" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const messages = try buildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary text", "sess_abc", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // <message_index> section must exist and contain one entry per dropped
    // message (everything except index 0 = the system prompt). The 6-msg
    // fixture drops 5 messages (indices 1..5).
    try testing.expect(std.mem.indexOf(u8, summary, "<message_index>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "</message_index>") != null);

    // Every non-system role from the fixture must appear in the index.
    try testing.expect(std.mem.indexOf(u8, summary, "<role>user</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>assistant</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>tool</role>") != null);

    // Each index entry must include a message id and a preview.
    // The compactor's job is to retrieve these BEFORE markMessageNotForLlmRun,
    // so they must be populated from the in-memory message list, not the DB.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>adhoc_") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<preview>") != null);
}

test "compactMessageInMemoryNew: tool-role index entries include tool_call_id" {
    // Regression: a tool-result message has `tool_call_id`. The index must
    // surface it so the agent can match the result back to the call.
    // (tool_name is not available on the in-memory AgentMessage struct in
    // this codebase; the envelope cannot surface it from the in-memory
    // list. The read_compacted_messages tool can fetch tool_name from the
    // DB row directly via getCompactedMessages.)
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const messages = try buildMessages(alloc);
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership
    // (T → !T): its body deinits messages.items + the ArrayList, leaving our
    // test scope's copy stale. Double-deinit would crash.

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_xyz", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;
    try testing.expect(std.mem.indexOf(u8, summary, "<tool_call_id>tc_1</tool_call_id>") != null);
}

test "compactMessageInMemoryNew: existing short-circuit (total <= 4) returns messages unchanged" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "hi") });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const result = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_1", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        // Free each AgentMessage's content then the ArrayList.
        for (result.items) |*m| m.deinit(alloc);
        var result_owned = result;
        result_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), result.items.len); // unchanged
    try testing.expectEqualStrings("hi", result.items[1].content.?);
}