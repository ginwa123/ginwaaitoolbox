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
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  -- Mirrors Migration 059 in production: a regular TEXT column.
        \\  -- No INSERT trigger — production populates it from application
        \\  -- code in `saveMessage`. Default to `now` localtime so tests that
        \\  -- don't specify `created_iso` get a sensible value matching
        \\  -- `created_at`'s default of `datetime('now')`.
        \\  created_iso TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S', 'now'))
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

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<query>login bug</query>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<snippet>") != null);
    // total_count is included in the text-mode header.
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>") != null);
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

    try testing.expect(std.mem.indexOf(u8, xml, "<search_history mode=\"session\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<session_id>s_X</session_id>") != null);
    // BOTH the live and compacted rows for s_X are present.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>live_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact_h</id>") != null);
    // Other session is excluded.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>other_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>2</count>") != null);
    // total_count reflects the count of rows that matched (same as count
    // here, since both rows fit in the default limit of 200).
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>2</total_count>") != null);
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

    // The full <content> is wrapped with a truncated="..." attribute
    // (the attribute is "0" because the content fits under MAX_FULL_CONTENT_BYTES).
    try testing.expect(std.mem.indexOf(u8, xml, "<content truncated=\"0\">Fix login bug</content>") != null);
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

test "execute_search_history: mode=text response includes total_count" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 5 matching rows
    for (0..5) |i| {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's1', 'user', 'fix login bug')", &.{id_buf});
    }
    // 1 non-matching row (sanity check)
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('other','s1','user','unrelated text')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
    });
    defer alloc.free(xml);

    // 5 hits returned, total_count = 5 (same — all fit in the page)
    try testing.expect(std.mem.indexOf(u8, xml, "<count>5</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>5</total_count>") != null);
}

test "execute_search_history: mode=text offset paginates FTS results" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 5 matching rows
    for (0..5) |i| {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's1', 'user', 'fix login bug')", &.{id_buf});
    }

    // Page 1: limit=2, no offset → first 2 hits
    const page1 = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
        .limit = 2,
    });
    defer alloc.free(page1);

    // Page 2: limit=2, offset=2 → next 2 hits (different ids)
    const page2 = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login bug",
        .limit = 2,
        .offset = 2,
    });
    defer alloc.free(page2);

    // Both pages must show count=2 + total_count=5 (offset doesn't change total).
    try testing.expect(std.mem.indexOf(u8, page1, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, page1, "<total_count>5</total_count>") != null);
    try testing.expect(std.mem.indexOf(u8, page1, "offset=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, page2, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, page2, "<total_count>5</total_count>") != null);
    try testing.expect(std.mem.indexOf(u8, page2, "offset=\"2\"") != null);

    // Pages must contain DIFFERENT ids (otherwise pagination didn't work).
    const p1_ids = [_][]const u8{ "<id>h0</id>", "<id>h1</id>", "<id>h2</id>", "<id>h3</id>", "<id>h4</id>" };
    var page1_first_id: ?[]const u8 = null;
    for (p1_ids) |needle| {
        if (std.mem.indexOf(u8, page1, needle) != null) {
            page1_first_id = needle;
            break;
        }
    }
    try testing.expect(page1_first_id != null);
    // The first id on page2 must be DIFFERENT from the first on page1
    // AND must be present on page2.
    var found_diff = false;
    for (p1_ids) |needle| {
        if (std.mem.eql(u8, needle, page1_first_id.?)) continue;
        if (std.mem.indexOf(u8, page2, needle) != null) {
            found_diff = true;
            break;
        }
    }
    try testing.expect(found_diff);
}

test "execute_search_history: mode=session order=desc returns most recent first" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 3 messages with explicit, increasing created_at to make order deterministic.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at) " ++
        "VALUES ('first','s_Z','user','first msg',1,'2026-01-01 10:00:00')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at) " ++
        "VALUES ('middle','s_Z','user','middle msg',1,'2026-01-02 10:00:00')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at) " ++
        "VALUES ('last','s_Z','user','last msg',1,'2026-01-03 10:00:00')", &.{});

    const xml_asc = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_Z",
    });
    defer alloc.free(xml_asc);
    const xml_desc = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_Z",
        .order = "desc",
    });
    defer alloc.free(xml_desc);

    // Order attribute is rendered in the header.
    try testing.expect(std.mem.indexOf(u8, xml_asc, "order=\"asc\"") != null);
    try testing.expect(std.mem.indexOf(u8, xml_desc, "order=\"desc\"") != null);

    // Asc: <id>first appears BEFORE <id>middle in the XML
    const asc_first_pos = std.mem.indexOf(u8, xml_asc, "<id>first</id>").?;
    const asc_middle_pos = std.mem.indexOf(u8, xml_asc, "<id>middle</id>").?;
    const asc_last_pos = std.mem.indexOf(u8, xml_asc, "<id>last</id>").?;
    try testing.expect(asc_first_pos < asc_middle_pos);
    try testing.expect(asc_middle_pos < asc_last_pos);

    // Desc: <id>last appears BEFORE <id>middle BEFORE <id>first
    const desc_last_pos = std.mem.indexOf(u8, xml_desc, "<id>last</id>").?;
    const desc_middle_pos = std.mem.indexOf(u8, xml_desc, "<id>middle</id>").?;
    const desc_first_pos = std.mem.indexOf(u8, xml_desc, "<id>first</id>").?;
    try testing.expect(desc_last_pos < desc_middle_pos);
    try testing.expect(desc_middle_pos < desc_first_pos);
}

test "execute_search_history: mode=session message_ids > MAX_MESSAGE_IDS returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Insert 60 messages so we can request 51 ids.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's_big', 'user', 'msg')", &.{id_buf});
    }

    // Build a CSV of 51 ids (one over the cap of 50). Each id is at most
    // 3 chars + 1 comma, so 51 * 4 = 204 bytes max.
    var csv_buf: [256]u8 = undefined;
    var csv_len: usize = 0;
    i = 0;
    while (i < 51) : (i += 1) {
        const part = try std.fmt.bufPrint(csv_buf[csv_len..], "{s}h{d}", .{
            if (i > 0) "," else "",
            i,
        });
        csv_len += part.len;
    }
    const csv: []const u8 = csv_buf[0..csv_len];

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_big",
        .message_ids = csv,
    });
    defer alloc.free(xml);

    // Should be an error, not a normal session response.
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Too many message_ids") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<message_index>") == null);
}

test "execute_search_history: mode=session full <content> > MAX_FULL_CONTENT_BYTES is truncated with truncated=\"1\"" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Build a single message with content > 16 KB.
    const huge_content = try alloc.alloc(u8, sh.MAX_FULL_CONTENT_BYTES + 1024);
    defer alloc.free(huge_content);
    @memset(huge_content, 'x');

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('big','s_big','assistant',?,0)", &.{huge_content});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_big",
        .message_ids = "big",
    });
    defer alloc.free(xml);

    // truncated="1" must be set when content exceeds MAX_FULL_CONTENT_BYTES.
    try testing.expect(std.mem.indexOf(u8, xml, "<content truncated=\"1\">") != null);

    // The serialized <content> body should be at most MAX_FULL_CONTENT_BYTES
    // bytes (the body is escaped, so just count the opening tag → closing tag
    // distance via finding the substring '<content truncated="1">' and the
    // next '</content>'). The exact escape length is MAX_FULL_CONTENT_BYTES
    // (no special chars in 'x' * N).
    const start_tag = "<content truncated=\"1\">";
    const end_tag = "</content>";
    const start = std.mem.indexOf(u8, xml, start_tag).? + start_tag.len;
    const end = std.mem.indexOf(u8, xml, end_tag).?;
    const body_len = end - start;
    try testing.expect(body_len == sh.MAX_FULL_CONTENT_BYTES);
}

test "execute_search_history: mode=session full <content> < MAX_FULL_CONTENT_BYTES sets truncated=\"0\"" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Small content (< 100 bytes — well under MAX_FULL_CONTENT_BYTES).
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('small','s_X','user','short content',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_X",
        .message_ids = "small",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<content truncated=\"0\">short content</content>") != null);
}

// =============================================================================
// Chunk 1 — is_feed_to_llm filter (live_only / compacted_only)
// =============================================================================

test "execute_search_history: mode=text live_only=true returns only live rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 1 live + 1 compacted + 1 live (different session) — query is "keyword"
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','keyword hit live',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','user','keyword hit compacted',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .live_only = true,
    });
    defer alloc.free(xml);

    // Only live row is in the result.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>1</total_count>") != null);
}

test "execute_search_history: mode=text compacted_only=true returns only compacted rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','keyword hit live',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','user','keyword hit compacted',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .compacted_only = true,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
}

test "execute_search_history: mode=session live_only=true returns only live rows for session" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','live msg',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','assistant','compacted msg',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_H",
        .live_only = true,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") == null);
}

test "execute_search_history: mode=session compacted_only=true returns only compacted rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live1','s_H','user','live msg',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact1','s_H','assistant','compacted msg',0)", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_H",
        .compacted_only = true,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>live1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>compact1</id>") != null);
}

test "execute_search_history: mode=text live_only and compacted_only both true returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "anything",
        .live_only = true,
        .compacted_only = true,
    });
    defer alloc.free(xml);

    // Mutually exclusive — error and no <results> block.
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "mutually exclusive") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<results>") == null);
}

// =============================================================================
// Chunk 2 — tool_name filter
// =============================================================================

test "execute_search_history: mode=text tool_name=bash returns only bash rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 1 bash tool + 1 read_file tool + 1 user (no tool_name) — all match the query.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('bash_h','s_J','tool','grep result for keyword', 'bash')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('read_h','s_J','tool','file contents keyword', 'read_file')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('user_h','s_J','user','keyword in user msg', '')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .tool_name = "bash",
    });
    defer alloc.free(xml);

    // Only the bash row is in the result.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>bash_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>read_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>user_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<total_count>1</total_count>") != null);
}

test "execute_search_history: mode=session tool_name=read_file returns only read_file rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('bash_h','s_K','tool','bash result', 'bash')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, tool_name) " ++
        "VALUES ('read_h','s_K','tool','file result', 'read_file')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "session",
        .session_id = "s_K",
        .tool_name = "read_file",
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<id>read_h</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>bash_h</id>") == null);
}

// =============================================================================
// Chunk 3 — parent_session_id filter
// =============================================================================
// The `parent_session_id` column is added to the test schema during the
// `addColumnIfMissing` style helpers used in higher-level fixtures. For our
// minimal test schema we add it via `ALTER TABLE` in each test that uses
// it (keeps the shared `setupDb()` from drifting).
//
// Note: the production schema does have the column. See Migration 012.

test "execute_search_history: mode=text parent_session_id filter restricts to sub-agent rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Add the parent_session_id column (production schema has it via Migration 012).
    try s.db.exec(alloc,
        "ALTER TABLE llm_history ADD COLUMN parent_session_id TEXT DEFAULT ''",
        &.{});

    // 1 sub-agent row + 1 main-agent row + 1 sub-agent of a different parent — all match query.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, parent_session_id) " ++
        "VALUES ('sub_a1','s_subA','user','keyword in subA','s_parent')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, parent_session_id) " ++
        "VALUES ('main_h','s_main','user','keyword in main','')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, parent_session_id) " ++
        "VALUES ('sub_b1','s_subB','user','keyword in subB','s_other_parent')", &.{});

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .parent_session_id = "s_parent",
    });
    defer alloc.free(xml);

    // Only the row whose parent_session_id matches.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>sub_a1</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>main_h</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>sub_b1</id>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
}

// =============================================================================
// Chunk 4 — full content in mode="text"
// =============================================================================
// `message_ids` accepted in mode="text". When non-empty, the response
// includes full <content> for those ids alongside the FTS hit snippets.

test "execute_search_history: mode=text with message_ids includes full content for those ids" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 2 hits, 1 non-hit
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h1','s_T','user','fix login bug',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h2','s_T','assistant','on it now',0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('h3','s_T','user','unrelated',0)", &.{});

    // Ask for full content for h1 + h2 (both match + non-match would still
    // be returned if requested). h3 is NOT in message_ids — full content
    // is omitted even though it could match the FTS query (it doesn't).
    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "login",
        .message_ids = "h1,h2",
    });
    defer alloc.free(xml);

    // mode="text" header still includes the FTS hit count (only h1 matches "login").
    try testing.expect(std.mem.indexOf(u8, xml, "<count>1</count>") != null);
    // h1 is a FTS hit AND a requested message_id → present in <results>.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h1</id>") != null);
    // h3 is NOT a requested id → never appears.
    try testing.expect(std.mem.indexOf(u8, xml, "<id>h3</id>") == null);
    // The full_contents block IS rendered when message_ids is provided.
    // Per-row content rendering is exercised by separate unit tests on
    // `getMessagesByIds` in `llm_history_messages_by_ids_test.zig`.
    try testing.expect(std.mem.indexOf(u8, xml, "<full_contents>") != null);
}

test "execute_search_history: mode=text message_ids > MAX_MESSAGE_IDS returns error XML" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // 60 messages
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const id_buf = try std.fmt.allocPrint(alloc, "h{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's_M', 'user', 'keyword hit')", &.{id_buf});
    }

    // 51 ids
    var csv_buf: [256]u8 = undefined;
    var csv_len: usize = 0;
    i = 0;
    while (i < 51) : (i += 1) {
        const part = try std.fmt.bufPrint(csv_buf[csv_len..], "{s}h{d}", .{
            if (i > 0) "," else "",
            i,
        });
        csv_len += part.len;
    }
    const csv: []const u8 = csv_buf[0..csv_len];

    const xml = try sh.execute_search_history(alloc, s.threaded.io(), &s.db, .{
        .mode = "text",
        .query = "keyword",
        .message_ids = csv,
    });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "Too many message_ids") != null);
}
