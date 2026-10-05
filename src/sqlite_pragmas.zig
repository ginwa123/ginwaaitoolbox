//! Connection pragmas the server applies to its OWN `agent.db` connection
//! right after `database.open`.
//!
//! WHY THIS EXISTS — the symptom it kills is
//! `warning: sqlite3 step failed: database is locked (sql: UPDATE sessions
//! SET last_human_touched_at_nano = ? WHERE id = ?)` repeating down the
//! server log, each repeat paired with
//! `warning: frontend_log_post: Failed to persist log`.
//!
//! In WAL mode there is exactly ONE writer slot for the whole file. A
//! write that cannot take that slot blocks for `busy_timeout` milliseconds
//! and then fails with the message above. Reproduced against SQLite 3.53.4
//! with the vendored backend's exact settings (`journal_mode=WAL`,
//! `busy_timeout=5000`) — a second connection holding the slot produces,
//! back to back and forever:
//!
//! ```text
//! autocommit write #1: database is locked  (5.00s)
//! autocommit write #2: database is locked  (5.00s)
//! autocommit write #3: database is locked  (5.00s)
//! ```
//!
//! The vendored `databases` package sets only `journal_mode=WAL` and
//! `busy_timeout=5000` in `SqliteBackend.init`, and it is a URL-pinned,
//! gitignored dependency — so the four knobs below are unreachable from
//! there and have to be set by the app, which owns the connection.
//!
//! The values, and what each one buys:
//!
//!   - `busy_timeout` — the ONLY defence a WAL writer has against a
//!     competing writer. 5 s is not enough on a machine where `agent.db`
//!     is 4 GB and a second `pabrik` process (or a DB browser such as
//!     DBeaver) shares the file. 15 s costs nothing when nobody else is
//!     writing (the wait only happens while the slot is genuinely taken)
//!     and converts most real contention from "write lost" into "write
//!     delayed".
//!
//!   - `synchronous` — SQLite's default is `FULL`, which fsyncs on every
//!     commit. In WAL the documented recommendation is `NORMAL`: the WAL is
//!     synced at checkpoints instead of on every commit. TRADE-OFF: on an
//!     OS-level crash or power cut the last few commits may be lost —
//!     `PRAGMA integrity_check` still passes, and SQLite's WAL guarantees
//!     still hold, because the recovery path is the checkpoint. Pass
//!     `.full` in `Config` to opt back out.
//!
//!   - `journal_size_limit` — caps the `-wal` file. Without it the WAL on
//!     a long-lived install is only ever APPENDED: `wal_autocheckpoint`
//!     caps how much is copied back per checkpoint but nothing shrinks the
//!     file, so it keeps growing until a checkpoint can reset it. With
//!     `wal_autocheckpoint=1000` and a reader holding a snapshot far back
//!     in the log (a DB browser with a result grid left open pins the read
//!     mark), that reset never happens and the WAL grows without bound.
//!
//!   - `wal_autocheckpoint` — the SQLite default, set explicitly so the
//!     value is visible at the call site and so `apply` is a complete,
//!     re-runnable description of the connection rather than a delta on
//!     top of whatever `init` happened to do.
//!
//! NOTE: `journal_mode=WAL` is re-asserted too. `PRAGMA journal_mode`
//! needs a brief exclusive lock to change mode, so re-asserting it on a
//! database that is already in WAL mode is a no-op that does not contend.
//! It is here so `apply` + `readBack` describe the connection completely.

const std = @import("std");
const sqlite = @import("databases").sqlite;
const helpers = @import("helpers");

/// Values SQLite accepts for `PRAGMA synchronous`. Kept as an enum (not a
/// raw integer) so a caller cannot silently pass 7 and get whatever
/// SQLite's bitmask does with it.
pub const Synchronous = enum(u8) {
    off = 0,
    normal = 1,
    full = 2,
    extra = 3,

    fn sql(self: Synchronous) []const u8 {
        return switch (self) {
            .off => "OFF",
            .normal => "NORMAL",
            .full => "FULL",
            .extra => "EXTRA",
        };
    }
};

/// The knobs `apply` sets. Every field has a production default; tests
/// pass smaller `busy_timeout_ms` / `wal_autocheckpoint_pages` so the
/// suite does not pay production-sized waits.
pub const Config = struct {
    busy_timeout_ms: u32 = 15_000,
    synchronous: Synchronous = .normal,
    wal_autocheckpoint_pages: u32 = 1_000,
    journal_size_limit_bytes: u32 = 64 * 1024 * 1024,
};

/// What `readBack` observed on the connection. Used by the tests as the
/// proof that the pragmas took, and printed once at boot so a user
/// staring at "database is locked" can see the live connection's actual
/// settings instead of guessing.
/// SQLite's journal-mode names ("delete", "truncate", "persist", "memory",
/// "wal", "off") all fit in 16 bytes. A fixed buffer keeps `Applied`
/// allocation-free — it exists for one log line at boot and must not hand
/// the caller an ownership obligation.
const JOURNAL_MODE_BUF_LEN = 16;

pub const Applied = struct {
    journal_mode_buf: [JOURNAL_MODE_BUF_LEN]u8 = undefined,
    journal_mode_len: usize = 0,
    busy_timeout_ms: u32,
    synchronous: i64,
    wal_autocheckpoint_pages: u32,
    /// Signed on purpose: SQLite's DEFAULT for this pragma is -1 ("no
    /// limit"), which is exactly the value a connection nobody configured
    /// reports — and it must be readable without an overflow panic so the
    /// boot log can show what the vendored backend left in place.
    journal_size_limit_bytes: i64,

    /// Borrowed view of `journal_mode_buf` — valid for as long as `self`.
    pub fn journal_mode(self: *const Applied) []const u8 {
        return self.journal_mode_buf[0..self.journal_mode_len];
    }
};

/// Apply `cfg` to `db`. Every statement is a PRAGMA with no bind
/// parameters, so `db.exec` is safe here — the "empty slice binds as
/// NULL" rule only bites when a `?` is present.
pub fn apply(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cfg: Config,
) !void {
    const busy = try std.fmt.allocPrint(allocator, "PRAGMA busy_timeout = {d}", .{cfg.busy_timeout_ms});
    defer allocator.free(busy);
    const auto_ckpt = try std.fmt.allocPrint(allocator, "PRAGMA wal_autocheckpoint = {d}", .{cfg.wal_autocheckpoint_pages});
    defer allocator.free(auto_ckpt);
    const size_limit = try std.fmt.allocPrint(allocator, "PRAGMA journal_size_limit = {d}", .{cfg.journal_size_limit_bytes});
    defer allocator.free(size_limit);
    const sync = try std.fmt.allocPrint(allocator, "PRAGMA synchronous = {s}", .{cfg.synchronous.sql()});
    defer allocator.free(sync);

    try db.exec(allocator, "PRAGMA journal_mode = WAL", &.{});
    try db.exec(allocator, busy, &.{});
    try db.exec(allocator, sync, &.{});
    try db.exec(allocator, auto_ckpt, &.{});
    try db.exec(allocator, size_limit, &.{});
}

/// Read the connection's current values back. Used at boot (one line in
/// the server log) and by the tests.
pub fn readBack(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !Applied {
    // `Row.values[i]` are allocator-owned and freed by `Row.deinit`, so
    // every value is copied out BEFORE that defer runs.
    var row = try db.queryRow(allocator, "PRAGMA journal_mode", &.{});
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.PragmaReturnedNoRow;
    if (row.values[0].len > JOURNAL_MODE_BUF_LEN) return error.JournalModeNameTooLong;
    var mode_buf: [JOURNAL_MODE_BUF_LEN]u8 = undefined;
    @memcpy(mode_buf[0..row.values[0].len], row.values[0]);

    return .{
        .journal_mode_buf = mode_buf,
        .journal_mode_len = row.values[0].len,
        .busy_timeout_ms = @intCast(try readInt(allocator, db, "PRAGMA busy_timeout")),
        .synchronous = try readInt(allocator, db, "PRAGMA synchronous"),
        .wal_autocheckpoint_pages = @intCast(try readInt(allocator, db, "PRAGMA wal_autocheckpoint")),
        .journal_size_limit_bytes = try readInt(allocator, db, "PRAGMA journal_size_limit"),
    };
}

fn readInt(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8) !i64 {
    var row = try db.queryRow(allocator, sql, &.{});
    defer row.deinit(allocator);
    if (row.values.len == 0) return error.PragmaReturnedNoRow;
    return std.fmt.parseInt(i64, row.values[0], 10) catch error.PragmaReturnedNonNumeric;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

/// Two `SqliteBackend` handles on ONE file-backed database, plus the
/// `std.Io.Threaded` runtime both need. File-backed (not `:memory:`)
/// because `:memory:` gives every connection a private database, and the
/// whole point is two connections contending for one WAL writer slot.
const TwoConns = struct {
    threaded: std.Io.Threaded,
    a: sqlite.SqliteBackend,
    b: sqlite.SqliteBackend,
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    fn init(cfg_b: Config) !TwoConns {
        const alloc = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
        const joined = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "pragma.db" });
        defer alloc.free(joined);
        const path = try alloc.dupeZ(u8, joined);
        errdefer alloc.free(path);

        var threaded = std.Io.Threaded.init(alloc, .{});
        errdefer threaded.deinit();

        var a: sqlite.SqliteBackend = .{};
        errdefer a.deinit();
        // `a` stands in for the process that got there first: it keeps the
        // vendored backend's own `init` settings, untouched.
        try a.init(threaded.io(), path);

        var b: sqlite.SqliteBackend = .{};
        errdefer b.deinit();
        try b.init(threaded.io(), path);

        try a.exec(alloc, "CREATE TABLE t (v INTEGER)", &.{});

        var self: TwoConns = .{
            .threaded = threaded,
            .a = a,
            .b = b,
            .tmp = tmp,
            .path = path,
        };
        // `b` is configured by the caller; do it here so every test that
        // builds the fixture gets the same treatment.
        apply(alloc, &self.b, cfg_b) catch |err| {
            self.deinit();
            return err;
        };
        return self;
    }

    fn deinit(self: *TwoConns) void {
        self.b.deinit();
        self.a.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
        testing.allocator.free(self.path);
    }
};

/// One connection opens a transaction, writes, holds WAL's single writer
/// slot for 400 ms, then commits. `locked` flips the instant the write is
/// inside the transaction, so the main thread never races thread start-up.
const HoldWriter = struct {
    db: *sqlite.SqliteBackend,
    allocator: std.mem.Allocator,
    locked: *std.atomic.Value(bool),

    fn run(self: *HoldWriter) !void {
        var tx = try self.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(self.allocator, "INSERT INTO t VALUES (1)", &.{});
        self.locked.store(true, .release);
        helpers.sleepMillis(400);
        try tx.commit();
    }
};

// `apply` really changes the connection, not just a local variable:
// read every knob back through SQLite.
test "apply: every pragma reads back at the value that was requested" {
    const alloc = testing.allocator;
    const cfg: Config = .{
        .busy_timeout_ms = 4321,
        .synchronous = .full,
        .wal_autocheckpoint_pages = 777,
        .journal_size_limit_bytes = 1_234_567,
    };
    var conns = try TwoConns.init(cfg);
    defer conns.deinit();

    const got = try readBack(alloc, &conns.b);

    try testing.expectEqualStrings("wal", got.journal_mode());
    try testing.expectEqual(@as(u32, 4321), got.busy_timeout_ms);
    try testing.expectEqual(@as(i64, 2), got.synchronous); // FULL
    try testing.expectEqual(@as(u32, 777), got.wal_autocheckpoint_pages);
    try testing.expectEqual(@as(i64, 1_234_567), got.journal_size_limit_bytes);

    // Positive control for the readback: the UNCONFIGURED connection `a`
    // still reports the vendored backend's own `busy_timeout=5000`. If
    // `readBack` were reading something global rather than per-connection,
    // this is the assertion that would catch it.
    const unconfigured = try readBack(alloc, &conns.a);
    try testing.expectEqual(@as(u32, 5000), unconfigured.busy_timeout_ms);
    try testing.expectEqual(@as(i64, 2), unconfigured.synchronous);
    // -1 is SQLite's own "no limit" default — `SqliteBackend.init` never
    // touches this pragma, so an unconfigured connection keeps it. That is
    // the unbounded-WAL behaviour `apply` exists to remove.
    try testing.expectEqual(@as(i64, -1), unconfigured.journal_size_limit_bytes);
}

test "apply: production defaults are WAL + NORMAL sync + bounded WAL" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{});
    defer conns.deinit();

    const got = try readBack(alloc, &conns.b);
    try testing.expectEqualStrings("wal", got.journal_mode());
    try testing.expectEqual(@as(u32, 15_000), got.busy_timeout_ms);
    try testing.expectEqual(@as(i64, 1), got.synchronous); // NORMAL
    try testing.expectEqual(@as(i64, 64 * 1024 * 1024), got.journal_size_limit_bytes);
}

// The behavioural core of the fix. Before `apply` existed the server
// inherited `busy_timeout=5000` and, under contention, every write
// returned `ExecuteFailed` — the `database is locked` in the bug report.
// With the timeout on the connection, the SAME contention is waited out
// and the write lands.
test "apply: a write waits out a competing writer instead of failing" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 5_000 });
    defer conns.deinit();

    // Handshake, not a sleep: the holder sets `locked` only AFTER its
    // INSERT is inside an open transaction, so `b`'s write is guaranteed
    // to meet a taken writer slot instead of racing the thread start.
    var locked = std.atomic.Value(bool).init(false);
    var hold = HoldWriter{ .db = &conns.a, .allocator = alloc, .locked = &locked };
    const thread = try std.Thread.spawn(.{}, HoldWriter.run, .{&hold});
    defer thread.join();

    var spins: usize = 0;
    while (!locked.load(.acquire)) : (spins += 1) {
        if (spins > 5_000) return error.HolderNeverTookTheWriteLock;
        helpers.sleepMillis(1);
    }

    // No retry here: the assertion is that SQLite's own busy handler,
    // armed by the pragma, covers the holder's 400 ms hold.
    try conns.b.exec(alloc, "INSERT INTO t VALUES (2)", &.{});

    thread.join();

    const got = try conns.b.queryRow(alloc, "SELECT COUNT(*) FROM t", &.{});
    defer got.deinit(alloc);
    try testing.expectEqualStrings("2", got.values[0]);
}

// The negative control for the test above: the SAME race against a
// connection that was never configured loses the write and reports
// `ExecuteFailed` — the exact failure the bug report is made of. Without
// this, the "waits it out" test could pass for reasons that have nothing
// to do with `busy_timeout` (a slow disk, a scheduler pause).
test "apply: without the pragma the same race still loses the write" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 1 });
    defer conns.deinit();

    var locked = std.atomic.Value(bool).init(false);
    var hold = HoldWriter{ .db = &conns.a, .allocator = alloc, .locked = &locked };
    const thread = try std.Thread.spawn(.{}, HoldWriter.run, .{&hold});
    defer thread.join();

    var spins: usize = 0;
    while (!locked.load(.acquire)) : (spins += 1) {
        if (spins > 5_000) return error.HolderNeverTookTheWriteLock;
        helpers.sleepMillis(1);
    }

    try testing.expectError(
        error.ExecuteFailed,
        conns.b.exec(alloc, "INSERT INTO t VALUES (2)", &.{}),
    );
}
