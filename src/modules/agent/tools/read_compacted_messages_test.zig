const std = @import("std");
const testing = std.testing;
const rcm = @import("read_compacted_messages.zig");
const sqlite = @import("nalarcore").sqlite;

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

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "execute_read_compacted_messages: index mode (no message_ids) returns only metadata" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Seed: 2 compacted + 1 active + 1 different-session
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h1','sess_1','user','Fix login',0)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h2','sess_1','assistant','On it',0)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h3','sess_1','user','active',1)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h4','sess_2','user','other',0)", &.{});

    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_1", .{});
    defer alloc.free(xml);

    // Index mode: <message_index> present, NO <content> tags
    try testing.expect(std.mem.indexOf(u8, xml, "<message_index>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<preview>Fix login</preview>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<preview>On it</preview>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content>") == null); // CRITICAL — index mode hides full content
    // Different-session rows are excluded
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h4</id>") == null);
    // Active rows (is_feed_to_llm=1) are excluded
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h3</id>") == null);
}

test "execute_read_compacted_messages: full mode (with message_ids) returns content" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h1','sess_1','user','Fix login',0)", &.{});
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) VALUES ('h2','sess_1','assistant','On it',0)", &.{});

    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_1",  .{ .mode = "full", .message_ids = "h1" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<content>Fix login</content>") != null);
    // h2 not requested — IN clause filters it out, so h2 is not in the output
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<content>On it</content>") == null);
}

test "execute_read_compacted_messages: tool_call_id and tool_name surfaced for tool-role messages" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    try s.db.exec(alloc, "INSERT INTO llm_history (id, session_id, role, response_content, tool_call_id, tool_name, is_feed_to_llm) VALUES ('h1','sess_1','tool','42/42 tests pass','tc_1','bash',0)", &.{});

    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_1",  .{ .message_ids = "h1" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<role>tool</role>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<tool_call_id>tc_1</tool_call_id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<tool_name>bash</tool_name>") != null);
}

test "execute_read_compacted_messages: empty result returns well-formed empty message_index" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const xml = try rcm.execute_read_compacted_messages(alloc, s.threaded.io(), &s.db, "sess_empty", .{});
    defer alloc.free(xml);

    // Allow either <message_index></message_index> or
    // <message_index>\n  </message_index> — both are well-formed.
    const has_empty = std.mem.indexOf(u8, xml, "<message_index>") != null and
        std.mem.indexOf(u8, xml, "</message_index>") != null;
    try testing.expect(has_empty);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>0</count>") != null);
}