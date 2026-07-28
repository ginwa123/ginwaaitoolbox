const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const logger_mod = @import("nalarcore").loggermod;
const retry_delay_ms = @import("retry_delay_ms.zig");
const builtin = @import("builtin");

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
    try db.exec(alloc, "CREATE TABLE workers (id TEXT PRIMARY KEY)", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "retryDelayMs does not panic over 200 calls with delay_ms = 1 (race-window stress)" {
    if (builtin.mode != .Debug) return error.SkipZigTest;

    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const result = retry_delay_ms.retryDelayMs(.{
            .allocator = alloc,
            .delay_ms = 1,
            .db = &s.db,
            .session_id = "race_test_session",
            .io = s.threaded.io(),
            .logger = &lg,
        });
        try testing.expect(result == true);
    }
}