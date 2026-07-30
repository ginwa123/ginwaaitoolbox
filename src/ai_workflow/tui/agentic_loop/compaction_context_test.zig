const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const ctx = @import("compaction_context.zig");

/// Set up an in-memory SQLite DB with a minimal `llm_history` schema that
/// matches the columns `fetchUserChatHistory` and `fetchReadFilePaths`
/// select on. Mirrors the schema slice used by
/// `workflow_compaction_envelope_test.zig::setupDb` — we only need the
/// columns the queries actually read, not the full Migration 059+ shape.
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
        "CREATE TABLE llm_history (" ++
            "  id TEXT PRIMARY KEY," ++
            "  session_id TEXT NOT NULL," ++
            "  model TEXT," ++
            "  response_content TEXT," ++
            "  role TEXT," ++
            "  tool_name TEXT," ++
            "  is_input INTEGER DEFAULT 0," ++
            "  is_output INTEGER DEFAULT 0," ++
            "  is_feed_to_llm INTEGER DEFAULT 1," ++
            "  created_at TEXT DEFAULT (datetime('now'))" ++
            ")",
        &[_][]const u8{},
    );
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

/// Seed one `llm_history` row with the columns our queries need.
fn seedRow(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    row: struct {
        id: []const u8,
        session_id: []const u8,
        role: []const u8,
        tool_name: []const u8,
        content: []const u8,
        is_input: []const u8,
        is_output: []const u8,
        created_at: []const u8,
    },
) !void {
    try db.exec(
        alloc,
        "INSERT INTO llm_history " ++
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at) " ++
            "VALUES (?, ?, 'test-model', ?, ?, ?, ?, ?, 1, ?)",
        &.{ row.id, row.session_id, row.content, row.role, row.tool_name, row.is_input, row.is_output, row.created_at },
    );
}

// ─── parseReadFilePath (pure-function, no DB) ─────────────────────────────

test "parseReadFilePath extracts the path from a valid envelope" {
    const content = "<path>/home/user/foo.zig</path>\n<content>body</content>";
    try testing.expectEqualStrings("/home/user/foo.zig", ctx.parseReadFilePath(content).?);
}

test "parseReadFilePath returns null when the tag is missing" {
    const content = "<content>body without a path</content>";
    try testing.expect(ctx.parseReadFilePath(content) == null);
}

test "parseReadFilePath returns null when the close tag is missing" {
    const content = "<path>/home/user/foo.zig\n<content>body</content>";
    try testing.expect(ctx.parseReadFilePath(content) == null);
}

test "parseReadFilePath handles paths with spaces and unicode" {
    const content = "<path>/home/user/My Files/日本語.txt</path><content>x</content>";
    try testing.expectEqualStrings("/home/user/My Files/日本語.txt", ctx.parseReadFilePath(content).?);
}

// ─── fetchUserChatHistory (DB-backed) ────────────────────────────────────

test "fetchUserChatHistory returns only matching session's user rows with non-null content, in chrono order" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    try seedRow(alloc, &s.db, .{
        .id = "u1",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "first ask",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "a1",
        .session_id = "sess_a",
        .role = "assistant",
        .tool_name = "",
        .content = "first reply",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:02",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u2",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "second ask",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:03",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u3",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "", // empty content -> filtered by != ''
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:04",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u_x",
        .session_id = "sess_b",
        .role = "user",
        .tool_name = "",
        .content = "wrong session",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:01",
    });

    var turns = try ctx.fetchUserChatHistory(alloc, &s.db, "sess_a");
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), turns.items.len);
    try testing.expectEqualStrings("first ask", turns.items[0].content);
    try testing.expectEqualStrings("second ask", turns.items[1].content);
    try testing.expectEqualStrings("2026-01-01 00:00:01", turns.items[0].created_at);
    try testing.expectEqualStrings("2026-01-01 00:00:03", turns.items[1].created_at);
}

// ─── fetchReadFilePaths (DB-backed + parse) ──────────────────────────────

test "fetchReadFilePaths returns only matching session's read_file outputs, with parsed paths" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    try seedRow(alloc, &s.db, .{
        .id = "rf1",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/foo.zig</path>\n<content>foo body</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf2",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/bar.zig</path>\n<content>bar body</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:02",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf3",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/ignored.zig</path>",
        .is_input = "1", // is_input not is_output -> filtered
        .is_output = "0",
        .created_at = "2026-01-01 00:00:03",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf_x",
        .session_id = "sess_b",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/wrong.zig</path>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf_malformed",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<content>no path tag here</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:04",
    });

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var turns = try ctx.fetchReadFilePaths(alloc, &s.db, "sess_a", &lg);
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    // rf3 is filtered by is_output=0; rf_malformed is dropped with a warning
    // (not failed). 2 valid rows remain.
    try testing.expectEqual(@as(usize, 2), turns.items.len);
    try testing.expectEqualStrings("/home/user/foo.zig", turns.items[0].path);
    try testing.expectEqualStrings("/home/user/bar.zig", turns.items[1].path);
    try testing.expect(std.mem.indexOf(u8, turns.items[0].raw_content, "foo body") != null);
}