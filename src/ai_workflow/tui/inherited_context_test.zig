const std = @import("std");
const ic = @import("inherited_context.zig");

test "parseMode - null/empty string returns Mode.none" {
    const m = try ic.parseMode("");
    try std.testing.expect(m == .none);
}

test "parseMode - 'none' returns Mode.none" {
    const m = try ic.parseMode("none");
    try std.testing.expect(m == .none);
}

test "parseMode - 'last:5' returns Mode.last{5}" {
    const m = try ic.parseMode("last:5");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 5);
}

test "parseMode - 'last:' (no number) defaults to 10" {
    const m = try ic.parseMode("last:");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == ic.DEFAULT_LAST);
}

test "parseMode - 'last:0' clamps to 1" {
    const m = try ic.parseMode("last:0");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 1);
}

test "parseMode - 'last:999' clamps to 50" {
    const m = try ic.parseMode("last:999");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'last:50' stays 50" {
    const m = try ic.parseMode("last:50");
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'all' returns Mode.all" {
    const m = try ic.parseMode("all");
    try std.testing.expect(m == .all);
}

test "parseMode - 'since_last_user' returns Mode.since_last_user" {
    const m = try ic.parseMode("since_last_user");
    try std.testing.expect(m == .since_last_user);
}

test "parseMode - 'garbage' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("garbage"));
}

test "parseMode - 'last:abc' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("last:abc"));
}

test "parseMode - 'last:-3' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("last:-3"));
}

test "parseMode - '  none  ' (surrounding whitespace) returns Mode.none" {
    const m = try ic.parseMode("  none  ");
    try std.testing.expect(m == .none);
}

test "parseMode - 'None' (mixed case) returns Mode.none" {
    const m = try ic.parseMode("None");
    try std.testing.expect(m == .none);
}

test "parseMode - 'Last:7' (mixed case prefix) returns Mode.last{7}" {
    const m = try ic.parseMode("Last:7");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 7);
}

// --- Formatter tests (need DB) --------------------------------------------

const nalarcore = @import("nalarcore");

fn setupDb() !struct {
    db: nalarcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: nalarcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal llm_history schema — only the columns the formatter reads.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    created_at TEXT,
        \\    response_content TEXT,
        \\    role TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedMessage(
    alloc: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    created_at: []const u8,
    role: []const u8,
    content: []const u8,
) !void {
    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, created_at, response_content, role)
        \\VALUES (?, ?, ?, ?, ?)
    , &.{ id, session_id, created_at, content, role });
}

test "formatHistory - parent with no history returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try ic.formatHistory(alloc, &ctx.db, "parent_sess", .none);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - last:5 filters out tool messages" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "Hello");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", "Hi there");
    try seedMessage(alloc, &ctx.db, "m3", "p", "2024-01-01 00:00:03", "user", "Please do X");
    try seedMessage(alloc, &ctx.db, "m4", "p", "2024-01-01 00:00:04", "assistant", "On it");
    try seedMessage(alloc, &ctx.db, "m5", "p", "2024-01-01 00:00:05", "tool", "{\"result\":\"ok\"}");
    try seedMessage(alloc, &ctx.db, "m6", "p", "2024-01-01 00:00:06", "user", "Thanks");

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .{ .last = 5 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "## Conversation History From Parent Agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: Hi there") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Please do X") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: On it") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Thanks") != null);
    // Tool message must be filtered out. Use a substring that is specific to
    // the tool payload (`{"result":"ok"}`) and does not collide with the
    // HEADER's "results" word.
    try std.testing.expect(std.mem.indexOf(u8, out, "**[tool]**") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "result\":\"ok") == null);
    // Order check: "Hello" must appear before "Please do X"
    const a = std.mem.indexOf(u8, out, "Hello").?;
    const b = std.mem.indexOf(u8, out, "Please do X").?;
    try std.testing.expect(a < b);
}

test "formatHistory - last:1 returns only the last user/assistant turn" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "first");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", "second");
    try seedMessage(alloc, &ctx.db, "m3", "p", "2024-01-01 00:00:03", "user", "third");

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .{ .last = 1 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: third") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second") == null);
}

test "formatHistory - since_last_user starts at the last user message" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "first_user");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", "after_first");
    try seedMessage(alloc, &ctx.db, "m3", "p", "2024-01-01 00:00:03", "user", "second_user");
    try seedMessage(alloc, &ctx.db, "m4", "p", "2024-01-01 00:00:04", "assistant", "after_second");

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .since_last_user);
    defer alloc.free(out);

    // 'since_last_user' = from the last user message (m3) to the end.
    // So we expect: m3 user, m4 assistant. NOT m1 user, m2 assistant.
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: second_user") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: after_second") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first_user") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after_first") == null);
}

test "formatHistory - all mode caps at 50 messages and adds truncation notice" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "m{d}", .{i});
        defer alloc.free(id);
        const ts = try std.fmt.allocPrint(alloc, "2024-01-01 00:{d:0>2}:00", .{i});
        defer alloc.free(ts);
        try seedMessage(alloc, &ctx.db, id, "p", ts, "user", "x");
    }

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .all);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "more messages omitted") != null);
    // Count the bullet lines — must be exactly 50, not 60.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "- **[user]**")) count += 1;
    }
    try std.testing.expect(count == 50);
}

test "formatHistory - empty parent history returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // No rows seeded.
    const out = try ic.formatHistory(alloc, &ctx.db, "p", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - empty parent_session_id returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try ic.formatHistory(alloc, &ctx.db, "", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}
