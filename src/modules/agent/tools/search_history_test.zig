const std = @import("std");
const testing = std.testing;
const sh = @import("search_history.zig");
const sqlite = @import("nalarcore").sqlite;

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
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content
        \\)
    , &.{});
    // Sync triggers (same shape as Migration 058 in production).
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "execute_search_history: mode=text returns FTS hits with snippets" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','the login bug needs fixing')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"text\">") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<query>login bug</query>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<snippet>") != null);
}

test "execute_search_history: mode=session returns ALL messages (live + compacted) for session_id" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live_h','s_X','user','Fix login (live)',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact_h','s_X','assistant','On it (compacted)',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('other_h','s_other','user','different session',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"session\">") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<session_id>s_X</session_id>") != null);
    // BOTH the live and compacted rows for s_X are present.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>live_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact_h</id>") != null);
    // Other session is excluded.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>other_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>2</count>") != null);
}

test "execute_search_history: mode=session with message_ids includes full <content>" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h1','s_X','user','Fix login bug',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h2','s_X','assistant','On it now',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
        .message_ids = "h1",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<content>Fix login bug</content>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h2</id>") == null);
}

test "execute_search_history: invalid mode returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "bogus",
        .query = "anything",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Invalid mode") != null);
}

test "execute_search_history: mode=text with empty query returns error" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "requires non-empty query") != null);
}

test "execute_search_history: mode=session with empty session_id returns error" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "requires non-empty session_id") != null);
}

test "toXmlSuccess and toXmlError produce well-formed XML envelopes" {
    const alloc = testing.allocator;
    const inner = try sh.toXmlSuccess(alloc, "<inner/>");
    defer alloc.free(inner);
    try testing.expectEqualStrings("<inner/>", inner);

    const err_xml = try sh.toXmlError(alloc, "boom");
    defer alloc.free(err_xml);
    try testing.expect(std.mem.indexOf(u8, err_xml, "<search_history>") != null);
    try testing.expect(std.mem.indexOf(u8, err_xml, "<error>boom</error>") != null);
}