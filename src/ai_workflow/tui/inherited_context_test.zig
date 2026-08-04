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

// --- isSubagent helper (no DB needed) ------------------------------------

test "isSubagent - empty parent_session_id returns false (not a subagent)" {
    try std.testing.expect(!ic.isSubagent("session_xyz", ""));
}

test "isSubagent - empty session_id returns false (defensive)" {
    try std.testing.expect(!ic.isSubagent("", "parent_xyz"));
}

test "isSubagent - both empty returns false" {
    try std.testing.expect(!ic.isSubagent("", ""));
}

test "isSubagent - session_id equal parent_session_id returns false (not a subagent)" {
    try std.testing.expect(!ic.isSubagent("session_xyz", "session_xyz"));
}

test "isSubagent - session_id differs from parent_session_id returns true (IS a subagent)" {
    try std.testing.expect(ic.isSubagent("session_child", "session_parent"));
}

test "isSubagent - case-sensitive (different case is treated as different)" {
    try std.testing.expect(ic.isSubagent("Session_xyz", "session_xyz"));
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

test "formatHistory - mode .none short-circuits to empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "parent_sess", .none);
    defer alloc.free(out);
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

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .{ .last = 5 });
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

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .{ .last = 1 });
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

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .since_last_user);
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

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
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
    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - empty parent_session_id returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - empty session_id returns empty string (defensive, new arg)" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed some history for the "parent" so we can confirm the empty
    // session_id short-circuit beats the DB read (no DB hit expected).
    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "should NOT appear");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", "should NOT appear");

    const out = try ic.formatHistory(alloc, &ctx.db, "", "p", .{ .last = 5 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
    // Header must NOT appear because we short-circuit before fetching.
    try std.testing.expect(std.mem.indexOf(u8, out, "should NOT appear") == null);
}

test "formatHistory - session_id equal parent_session_id returns empty string (NOT a subagent)" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed parent history — but the subagent guard says "session equals
    // parent → not a subagent → empty string". So the seeded messages
    // must NOT appear in the output.
    try seedMessage(alloc, &ctx.db, "m1", "self", "2024-01-01 00:00:01", "user", "should NOT appear");
    try seedMessage(alloc, &ctx.db, "m2", "self", "2024-01-01 00:00:02", "assistant", "should NOT appear");

    const out = try ic.formatHistory(alloc, &ctx.db, "self", "self", .{ .last = 5 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
    try std.testing.expect(std.mem.indexOf(u8, out, "should NOT appear") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Conversation History From Parent Agent") == null);
}

test "formatHistory - session_id differs from parent_session_id returns parent history (IS a subagent)" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "parent_sess", "2024-01-01 00:00:01", "user", "from parent: a question");
    try seedMessage(alloc, &ctx.db, "m2", "parent_sess", "2024-01-01 00:00:02", "assistant", "from parent: an answer");
    // A row tagged with the SAME session_id as the child (the subagent)
    // should never come back, because we filter by parent_session_id.
    try seedMessage(alloc, &ctx.db, "m3", "child_sess", "2024-01-01 00:00:03", "user", "from child — must NOT appear");

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "parent_sess", .{ .last = 5 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "## Conversation History From Parent Agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: from parent: a question") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: from parent: an answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "from child") == null);
}

test "formatHistory - 20KB byte cap emits truncation notice" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // 30 messages × 1 KB = 30 KB of content, well over the 20 KB byte cap
    // but well under the 50-message cap, so the byte cap (not the message
    // cap) is what fires.
    const big_content = try alloc.alloc(u8, 1024);
    defer alloc.free(big_content);
    @memset(big_content, 'x');

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "m{d}", .{i});
        defer alloc.free(id);
        const ts = try std.fmt.allocPrint(alloc, "2024-01-01 01:{d:0>2}:00", .{i});
        defer alloc.free(ts);
        try seedMessage(alloc, &ctx.db, id, "p", ts, "user", big_content);
    }

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
    defer alloc.free(out);

    // Byte cap should have fired (we seeded 30 KB of content, cap is 20 KB).
    try std.testing.expect(std.mem.indexOf(u8, out, "more messages omitted") != null);
    // The rendered output (HEADER + bullets + notice) must be ≤ 20 KB + slack.
    // Slack accounts for HEADER (~400) + notice (~50) + the bullet line that
    // was the next one to be considered but rejected by the cap check.
    // We assert < 25 KB to allow slack while still proving the cap fired.
    try std.testing.expect(out.len < 25 * 1024);
}

test "formatHistory - DB query failure returns the documented fallback string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Drop the table so the formatter's SELECT will fail.
    try ctx.db.exec(alloc, "DROP TABLE llm_history", &.{});

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .all);
    defer alloc.free(out);

    try std.testing.expectEqualStrings("(failed to load parent conversation history)", out);
}

test "formatHistory - empty content rows are filtered out" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "Hello");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", ""); // empty
    try seedMessage(alloc, &ctx.db, "m3", "p", "2024-01-01 00:00:03", "user", "Bye");

    const out = try ic.formatHistory(alloc, &ctx.db, "child_sess", "p", .{ .last = 5 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Bye") != null);
    // The empty-content assistant row should not produce a `- **[assistant]**:` bullet.
    // We check that if any assistant bullet exists, it must have non-empty content.
    const assistant_idx = std.mem.indexOf(u8, out, "- **[assistant]**") orelse 0;
    if (assistant_idx > 0) {
        // If a bullet line for assistant exists, it must have non-empty content.
        const after = out[assistant_idx..];
        const eol = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
        const line = after[0..eol];
        // Line is `- **[assistant]**: {content}` — content is everything after `: `.
        try std.testing.expect(line.len > "- **[assistant]**: ".len);
    }
}
