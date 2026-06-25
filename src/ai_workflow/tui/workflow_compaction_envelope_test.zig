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
    // All non-system messages get a real DB-style id so the envelope
    // embeds real ids (regression for the adhoc_N synthesis bug). The
    // system prompt at index 0 has no DB row, so it stays id=null —
    // and it's also excluded from the envelope (dropped_messages[1..]).
    try list.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "You are a coding agent."),
    });
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "1782027251703514461"),
        .role = .user,
        .content = try allocator.dupe(u8, "Fix the login bug"),
    });
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "1782027292873814871"),
        .role = .assistant,
        .content = try allocator.dupe(u8, "I'll investigate"),
    });
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "1782027292879102675"),
        .role = .tool,
        .content = try allocator.dupe(u8, "tests pass: 42/42"),
        .tool_call_id = try allocator.dupe(u8, "tc_1"),
    });
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "1782027299200000001"),
        .role = .user,
        .content = try allocator.dupe(u8, "Now ship it"),
    });
    try list.append(allocator, .{
        .id = try allocator.dupe(u8, "1782027306945614038"),
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
    //
    // Regression for the synthetic-id bug: the envelope MUST carry the
    // real DB primary key (the 19-digit timestamp we set in buildMessages),
    // not a synthetic adhoc_<n> marker. Without real ids,
    // read_compacted_messages(mode="full", message_ids=[envelope_id])
    // returns 0 rows.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>1782027292879102675</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<preview>") != null);
    // Defensive: the old adhoc_<n> synthesis must NOT reappear.
    try testing.expect(std.mem.indexOf(u8, summary, "adhoc_") == null);
}

test "compactMessageInMemoryNew: tool-role index entries include tool_call_id" {
    // Regression: a tool-result message has `tool_call_id`. The index must
    // surface it so the agent can match the result back to the call.
    // tool_name is now also surfaced from the in-memory AgentMessage
    // (via the first tool_call.function.name when set; falls back to
    // "unknown" for synthetic test fixtures without tool_calls).
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
    // buildMessages has no tool_calls, so tool_name falls back to "unknown".
    try testing.expect(std.mem.indexOf(u8, summary, "<tool_name>unknown</tool_name>") != null);
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

test "buildCompactionEnvelope: tool results get 500-char preview, others 200-char" {
    // Regression for the 100-char preview bug: tool results are
    // information-dense (write_file outputs, search results, etc.) and
    // need more than 100 chars to be useful. user/assistant messages are
    // usually short and stay at 200.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const long_text = try alloc.alloc(u8, 1000);
    defer alloc.free(long_text);
    @memset(long_text, 'x');

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027251703514461"),
        .role = .user,
        .content = try alloc.dupe(u8, long_text),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292873814871"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "I'll handle that"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292879102675"),
        .role = .tool,
        .content = try alloc.dupe(u8, long_text),
        .tool_call_id = try alloc.dupe(u8, "tc_1"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027306945614038"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "Done"),
    });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_500", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // Both ids must be embedded.
    try testing.expect(std.mem.indexOf(u8, summary, "<id>1782027251703514461</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<id>1782027292879102675</id>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>user</role>") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "<role>tool</role>") != null);

    // Slice out the user entry and the tool entry by their ids.
    const user_id_pos = std.mem.indexOf(u8, summary, "<id>1782027251703514461</id>").?;
    const tool_id_pos = std.mem.indexOf(u8, summary, "<id>1782027292879102675</id>").?;
    const user_entry_end = std.mem.indexOfPos(u8, summary, user_id_pos, "</entry>").?;
    const tool_entry_end = std.mem.indexOfPos(u8, summary, tool_id_pos, "</entry>").?;

    const user_entry = summary[user_id_pos..user_entry_end];
    const tool_entry = summary[tool_id_pos..tool_entry_end];

    // Count preview contents length for each.
    const user_p_start = std.mem.indexOf(u8, user_entry, "<preview>").? + "<preview>".len;
    const user_p_end = std.mem.indexOf(u8, user_entry, "</preview>").?;
    try testing.expectEqual(@as(usize, 200), user_p_end - user_p_start);

    const tool_p_start = std.mem.indexOf(u8, tool_entry, "<preview>").? + "<preview>".len;
    const tool_p_end = std.mem.indexOf(u8, tool_entry, "</preview>").?;
    try testing.expectEqual(@as(usize, 500), tool_p_end - tool_p_start);
}

test "buildCompactionEnvelope: vision message preview extracts text from content_parts" {
    // Regression: messages with content_parts (vision) had content=null,
    // so the preview fell through to "" — the agent had no signal that
    // an image attachment existed. After this fix, the text parts of
    // content_parts are concatenated into the preview.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const part_text = "What is in this image?";

    const image_part = agent.ContentPart{
        .part_type = "image_url",
        .text = null,
        .image_url = .{
            .url = try alloc.dupe(u8, "data:image/png;base64,iVBORw0..."),
            .detail = null,
        },
    };
    const text_part = agent.ContentPart{
        .part_type = "text",
        .text = try alloc.dupe(u8, part_text),
        .image_url = null,
    };
    const content_parts = try alloc.dupe(agent.ContentPart, &[_]agent.ContentPart{ text_part, image_part });

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027251703514461"),
        .role = .user,
        .content = null,
        .content_parts = content_parts,
    });
    // Add enough messages so total > 4 (the compaction threshold).
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292873814871"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "Looking at the image"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027292879102675"),
        .role = .tool,
        .content = try alloc.dupe(u8, "image processed"),
        .tool_call_id = try alloc.dupe(u8, "tc_v1"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027306945614038"),
        .role = .assistant,
        .content = try alloc.dupe(u8, "It's a sunset"),
    });
    try messages.append(alloc, .{
        .id = try alloc.dupe(u8, "1782027317965287809"),
        .role = .user,
        .content = try alloc.dupe(u8, "thanks"),
    });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", "sess_vision", "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;
    // Vision preview must contain the text-part content, NOT be empty.
    try testing.expect(std.mem.indexOf(u8, summary, "<preview>What is in this image?</preview>") != null);
}

test "end-to-end: compaction envelope ids are findable via getCompactedMessages" {
    // Regression for the synthetic-id bug: before the fix, the envelope
    // embedded adhoc_<n> ids that didn't exist in llm_history.id, so
    // read_compacted_messages(mode="full", message_ids="adhoc_5") returned
    // 0 rows. After the fix, the in-memory AgentMessage.id (set by
    // transform_llm_history_to_agent_message) flows through to the envelope
    // AND matches the DB row, so the read tool finds the original content.
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const session_id = "sess_roundtrip";
    const ids = [_][]const u8{
        "1000000000000000001",
        "1000000000000000002",
        "1000000000000000003",
        "1000000000000000004",
        "1000000000000000005",
    };
    const contents = [_][]const u8{
        "Fix the login bug",
        "I'll investigate",
        "running tests",
        "tests pass: 42/42",
        "shipping",
    };
    const roles = [_][]const u8{ "user", "assistant", "assistant", "tool", "user" };

    // Pre-seed DB with real ids, marked is_feed_to_llm=1 (so compactMessageInMemoryNew's
    // markMessageNotForLlmRun will flip them to 0 after compaction).
    for (ids, contents, roles) |id, content, role| {
        const tcid: []const u8 = if (std.mem.eql(u8, role, "tool")) "tc_xyz" else "";
        const tname: []const u8 = if (std.mem.eql(u8, role, "tool")) "bash" else "";
        try s.db.exec(alloc,
            \\INSERT INTO llm_history
            \\  (id, session_id, model, response_content, role, is_feed_to_llm,
            \\   created_at, tool_call_id, tool_name)
            \\VALUES (?, ?, 'gpt-4o', ?, ?, 1, '2026-01-01 00:00:00', ?, ?)
        , &.{ id, session_id, content, role, tcid, tname });
    }

    // Build the in-memory message list with matching .id values, then compact.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    for (ids, contents, roles) |id, content, role| {
        const role_enum = std.meta.stringToEnum(agent.Role, role) orelse .user;
        try messages.append(alloc, .{
            .id = try alloc.dupe(u8, id),
            .role = role_enum,
            .content = try alloc.dupe(u8, content),
            .tool_call_id = if (std.mem.eql(u8, role, "tool"))
                try alloc.dupe(u8, "tc_xyz")
            else
                null,
        });
    }

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try workflow.compactMessageInMemoryNew(
        alloc, messages, "summary", session_id, "gpt-4o", "/tmp",
        &s.db, s.threaded.io(), &lg,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    const summary = new_messages.items[1].content.?;

    // Every id must appear in the envelope verbatim.
    for (ids) |id| {
        const needle = try std.fmt.allocPrint(alloc, "<id>{s}</id>", .{id});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, summary, needle) != null);
    }

    // And — critically — pulling an id OUT of the envelope and feeding it
    // back through getCompactedMessages must return the original row.
    for (ids, contents) |id, original_content| {
        const id_filter = [_][]const u8{id};
        const found = try llm_history.getCompactedMessages(alloc, &s.db,
            session_id,
            .{ .message_ids = &id_filter, .limit = 10 });
        defer {
            for (found) |m| {
                var copy = m;
                copy.deinit(alloc);
            }
            alloc.free(found);
        }
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expectEqualStrings(id, found[0].id);
        try testing.expectEqualStrings(original_content, found[0].content);
    }
}