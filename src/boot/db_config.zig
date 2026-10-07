//! The SQLite connection policy pabrik opens its database with.
//!
//! ONE place, because the daemon (`boot/server_boot.zig`) and the
//! `create-admin` CLI (`boot/cli_dispatch.zig`) open the SAME file: a CLI
//! that opened it with different pragmas would behave differently on the
//! same data, and that difference would only show up under load.
//!
//! Every value here comes from the ruangsql benchmark harness
//! (`sparringhttp`, sqlite scenario: 5000-row table, point read / list /
//! LIKE search / insert / update / delete, equal-spec 2-CPU container,
//! `wrk -c50`). The two that actually changed the numbers:
//!
//!   - `read_conns` — WAL allows MANY concurrent readers and exactly ONE
//!     writer, so opening extra read connections and round-robining reads
//!     across them is what moved a benchmark server's read throughput
//!     +270% (50k -> 185k rps on a 16-core host). Before it, every read
//!     queued behind one mutex, so a read waiting on a write inherited the
//!     write's latency.
//!
//!   - `cache_size_kb` — SQLite ships a 2 MiB page cache per connection.
//!     8 MiB is what the harness ran with. NOTE it MULTIPLIES by the
//!     connection count: 8 connections x 8 MiB = ~64 MiB of page cache for
//!     this process, which is the number to watch if pabrik's RSS matters.
//!     Lower it (and/or `read_conns`) rather than leaving the product
//!     unbounded on a small machine.
//!
//! `mmap_size_bytes` maps the database file instead of `read()`-ing it:
//! pages still come from the OS file cache, but each hit skips a syscall
//! and a copy, and it is file-backed — so unlike `cache_size` it does not
//! count against a container's `memory.max`.
//!
//! `synchronous = .normal` is WAL's documented pairing (sync at
//! checkpoints rather than on every commit). Trade-off: an OS crash or
//! power cut can lose the last few commits; `PRAGMA integrity_check` still
//! passes, because recovery goes through the checkpoint. It was already
//! pabrik's choice before this file existed.
//!
//! `busy_timeout_ms`, `journal_size_limit_bytes` and
//! `wal_autocheckpoint_pages` are stated explicitly rather than left to the
//! package so this struct is a COMPLETE description of the connection.
//! The 15 s timeout is the ruangsql#1 fix that turned "write lost after 5 s
//! with database is locked" into "write delayed".

const std = @import("std");
const databases = @import("databases");

/// The measured-best sqlite policy for pabrik's agent database.
pub const best: databases.database.SqliteConfig = .{
    .synchronous = .normal,
    .busy_timeout_ms = 15_000,
    .read_conns = 7, // 8 connections total: 1 writer + 7 readers
    .cache_size_kb = 8_000, // 8 MiB per connection (SQLite default is 2 MiB)
    .mmap_size_bytes = 256 * 1024 * 1024,
    .journal_size_limit_bytes = 64 * 1024 * 1024,
    .wal_autocheckpoint_pages = 1_000,
};

/// Page cache this policy commits to, in KiB — `read_conns + 1` for the
/// write connection. Used by the test below to keep the product honest.
pub const page_cache_budget_kb: u32 = best.cache_size_kb * (@as(u32, @intCast(best.read_conns)) + 1);

/// Read one single-column pragma back from a live connection.
fn readPragmaInt(db: *databases.database.Db, allocator: std.mem.Allocator, sql: []const u8) !i64 {
    var row = try db.queryRow(allocator, sql, &.{});
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.NoValue;
    return std.fmt.parseInt(i64, row.values[0], 10);
}

/// Close the database and its WAL siblings so a test starts from nothing.
fn removeDbFiles(io: std.Io, path: [:0]const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    var buf: [512]u8 = undefined;
    const wal = std.fmt.bufPrintZ(&buf, "{s}-wal", .{path}) catch return;
    std.Io.Dir.deleteFileAbsolute(io, wal) catch {};
    const shm = std.fmt.bufPrintZ(&buf, "{s}-shm", .{path}) catch return;
    std.Io.Dir.deleteFileAbsolute(io, shm) catch {};
}

test "the policy pabrik opens with is the policy the connection reports" {
    // The point of this file is that these values are APPLIED, not just
    // declared — a struct that compiles proves nothing about the pragmas.
    // So: open a real (file-backed, WAL-capable) database with `best` and
    // read the live settings back off the connection.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/pabrik_db_config_test.db";

    removeDbFiles(io, path);
    defer removeDbFiles(io, path);

    var db: databases.database.Db = .{};
    defer db.deinit();
    try databases.database.openWithConfig(&db, io, .{ .sqlite_path = path }, best);

    // Copy the pragma out BEFORE `deinit`: `row.values` are freed by it, so
    // comparing the slice afterwards would read freed memory.
    var mode_buf: [16]u8 = undefined;
    var mode_len: usize = 0;
    {
        var row = try db.queryRow(allocator, "PRAGMA journal_mode", &.{});
        defer row.deinit(allocator);
        mode_len = @min(row.values[0].len, mode_buf.len);
        @memcpy(mode_buf[0..mode_len], row.values[0][0..mode_len]);
    }
    try std.testing.expectEqualStrings("wal", mode_buf[0..mode_len]);
    try std.testing.expectEqual(@as(i64, 15_000), try readPragmaInt(&db, allocator, "PRAGMA busy_timeout"));
    // 1 = NORMAL (0 OFF, 2 FULL, 3 EXTRA).
    try std.testing.expectEqual(@as(i64, 1), try readPragmaInt(&db, allocator, "PRAGMA synchronous"));
    // SQLite reports the page cache as a NEGATIVE KiB count.
    try std.testing.expectEqual(@as(i64, -8_000), try readPragmaInt(&db, allocator, "PRAGMA cache_size"));
    try std.testing.expectEqual(@as(i64, 64 * 1024 * 1024), try readPragmaInt(&db, allocator, "PRAGMA journal_size_limit"));
    try std.testing.expectEqual(@as(i64, 1_000), try readPragmaInt(&db, allocator, "PRAGMA wal_autocheckpoint"));
    // mmap_size may be clamped by the build/host, so assert "on", not a value.
    try std.testing.expect(try readPragmaInt(&db, allocator, "PRAGMA mmap_size") > 0);
}

test "a pooled connection still reads and writes correctly" {
    // Reader pooling must be invisible: a write on the primary connection
    // has to be visible to the next read, which lands on a reader.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/pabrik_db_config_pool_test.db";

    removeDbFiles(io, path);
    defer removeDbFiles(io, path);

    var db: databases.database.Db = .{};
    defer db.deinit();
    try databases.database.openWithConfig(&db, io, .{ .sqlite_path = path }, best);

    try db.exec(allocator, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)", &.{});
    try db.exec(allocator, "INSERT INTO t (id, v) VALUES (?, ?)", &.{ "1", "written" });

    // Several reads in a row exercise more than one reader connection.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var row = try db.queryRow(allocator, "SELECT v FROM t WHERE id = ?", &.{"1"});
        defer row.deinit(allocator);
        try std.testing.expectEqualStrings("written", row.values[0]);
    }

    // `last_insert_rowid()` is connection state, not table data: it must be
    // answered by the connection that inserted, or it returns 0.
    try db.exec(allocator, "INSERT INTO t (v) VALUES (?)", &.{"second"});
    var id_row = try db.queryRow(allocator, "SELECT last_insert_rowid()", &.{});
    defer id_row.deinit(allocator);
    try std.testing.expectEqualStrings("2", id_row.values[0]);
}

test "page cache stays inside the budget the comment claims" {
    // The cache is PER CONNECTION, so the number that matters is the
    // product. 128 MiB is the ceiling this project accepts.
    try std.testing.expect(page_cache_budget_kb <= 128 * 1024);
    try std.testing.expect(best.read_conns > 0);
    try std.testing.expectEqual(databases.sqlite.Synchronous.normal, best.synchronous);
}
