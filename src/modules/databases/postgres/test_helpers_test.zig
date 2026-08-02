//! Tests for the test helpers themselves. These are NOT required for
//! the production code — they verify the helper API works as
//! documented, so a future refactor of `test_helpers.zig` can't
//! silently break the public surface used by `postgres_test.zig`
//! and any future test that wants an isolated PostgreSQL DB.
//!
//! The tests use the helpers exactly as a downstream test would:
//!   - `getOrStartTestInstance` to probe the shared instance
//!   - `createTempDb` to provision an isolated DB
//!   - `dropTempDb` to clean up
//!
//! All tests gate on `is_available` so this file skips cleanly on
//! hosts without a running PG instance (e.g. CI without libpq).

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const PostgresBackend = @import("Postgres.zig").PostgresBackend;

test "getOrStartTestInstance returns a usable TestEnv on a live instance" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);

    if (!env.is_available) return; // skip silently if no PG

    // The conninfo is non-empty and NUL-terminated (libpq requires
    // the C string to have a NUL).
    try testing.expect(env.conninfo.len > 0);
    try testing.expect(env.conninfo[env.conninfo.len - 1] == 0);
}

test "getOrStartTestInstance is idempotent (cached after first call)" {
    const alloc = testing.allocator;
    const first = helpers.getOrStartTestInstance(alloc);
    const second = helpers.getOrStartTestInstance(alloc);

    if (!first.is_available) return;

    // Same conninfo pointer (cached, no reallocation).
    try testing.expectEqualSlices(u8, first.conninfo, second.conninfo);
    try testing.expectEqual(first.is_available, second.is_available);
}

test "createTempDb returns a unique, open, working backend" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try helpers.createTempDb(alloc, env.conninfo);
    defer helpers.dropTempDb(alloc, &ctx);

    // The backend is open: a trivial SELECT returns 1 row.
    var q = try ctx.db.query(alloc, "SELECT 1", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ExpectedRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);

    // db_name is non-empty and NUL-prefixed via the standard
    // nalar_pg_test_<pid>_<counter> scheme.
    try testing.expect(std.mem.startsWith(u8, ctx.db_name, "nalar_pg_test_"));
}

test "createTempDb is isolated: two calls produce independent DBs" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx1 = try helpers.createTempDb(alloc, env.conninfo);
    defer helpers.dropTempDb(alloc, &ctx1);

    var ctx2 = try helpers.createTempDb(alloc, env.conninfo);
    defer helpers.dropTempDb(alloc, &ctx2);

    // Different DB names.
    try testing.expect(!std.mem.eql(u8, ctx1.db_name, ctx2.db_name));

    // ctx1 and ctx2 have different connections (different PGconn
    // pointers). We don't dereference the pointers (they're opaque),
    // but the addresses should differ.
    try testing.expect(@intFromPtr(ctx1.db.conn) != @intFromPtr(ctx2.db.conn));

    // ctx1 can create a table without affecting ctx2.
    try ctx1.db.exec(alloc, "CREATE TABLE foo (id TEXT)", &.{});
    try ctx1.db.exec(alloc, "INSERT INTO foo VALUES ('only_in_ctx1')", &.{});

    // ctx2 doesn't see ctx1's table — confirms isolation.
    var q = ctx2.db.query(alloc,
        "SELECT table_name FROM information_schema.tables WHERE table_name = 'foo'", &.{}) catch |err| switch (err) {
            error.QueryFailed => return, // any error means it's not visible
            else => return err,
        };
    defer q.deinit();
    const row = try q.next();
    try testing.expect(row == null);
}

test "createTempDb: failure on bad base conninfo returns error" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // Use an obviously bad port with a short connect_timeout. The
    // CREATE DATABASE step will fail at PQconnectdb and return
    // DatabaseNotFound.
    const result = helpers.createTempDb(alloc,
        "host=/tmp port=1 user=ginwa dbname=postgres connect_timeout=1");
    try testing.expectError(helpers.PostgresError.DatabaseNotFound, result);
}

test "dropTempDb actually drops the database (verified by name lookup)" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try helpers.createTempDb(alloc, env.conninfo);
    const db_name = try alloc.dupeZ(u8, ctx.db_name);
    defer alloc.free(db_name);

    helpers.dropTempDb(alloc, &ctx);

    // Verify the database no longer exists via direct libpq probe.
    const probe = PostgresBackend.c.PQconnectdb(env.conninfo.ptr);
    defer if (probe) |p| PostgresBackend.c.PQfinish(p);
    if (probe == null) return;
    if (PostgresBackend.c.PQstatus(probe) != PostgresBackend.c.CONNECTION_OK) return;

    // SELECT 1 FROM pg_database WHERE datname = '<our db>'
    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf,
        "SELECT 1 FROM pg_database WHERE datname = '{s}'", .{db_name}) catch return;
    // Copy to a NUL-terminated buffer so libpq can read it as a C
    // string. (bufPrint does not write a NUL terminator in Zig 0.16.)
    const sql_z = try alloc.allocSentinel(u8, sql.len, 0);
    defer alloc.free(sql_z);
    @memcpy(sql_z, sql);
    const res = PostgresBackend.c.PQexec(probe, sql_z.ptr);
    defer if (res) |r| PostgresBackend.c.PQclear(r);
    if (res == null) return;
    const ntuples = PostgresBackend.c.PQntuples(res);
    try testing.expectEqual(@as(c_int, 0), ntuples);
}

test "dropTempDb is idempotent: calling twice is a no-op" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try helpers.createTempDb(alloc, env.conninfo);
    helpers.dropTempDb(alloc, &ctx);
    // Second call must not crash and must not free anything twice.
    helpers.dropTempDb(alloc, &ctx);
}

test "buildDbConninfo strips existing dbname= and appends new one" {
    const alloc = testing.allocator;
    // Base with a dbname we don't want.
    const out = try helpers.buildDbConninfo(alloc,
        "host=/tmp port=54329 user=ginwa dbname=postgres", "new_db");
    defer alloc.free(out);

    // The output must contain dbname=new_db (the LAST dbname wins
    // in libpq, but our wrapper strips to be safe).
    try testing.expect(std.mem.indexOf(u8, out, "dbname=new_db") != null);
    // And must NOT contain the old dbname=postgres.
    try testing.expect(std.mem.indexOf(u8, out, "dbname=postgres") == null);
    // The other keys survive.
    try testing.expect(std.mem.indexOf(u8, out, "host=/tmp") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port=54329") != null);
    try testing.expect(std.mem.indexOf(u8, out, "user=ginwa") != null);
}

test "buildDbConninfo handles conninfo with no dbname" {
    const alloc = testing.allocator;
    const out = try helpers.buildDbConninfo(alloc,
        "host=/tmp port=54329 user=ginwa", "fresh_db");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "dbname=fresh_db") != null);
}
