const std = @import("std");

pub const Error = error{
    OpenFailed,
    DatabaseNotFound,
    PermissionDenied,
    DiskFull,
    DatabaseCorrupt,
    QueryFailed,
    PrepareFailed,
    BindFailed,
    ExecuteFailed,
    RowNotFound,
    OutOfMemory,
};

pub const SqliteBackend = struct {
    const c = @cImport(@cInclude("sqlite3.h"));

    db: ?*c.sqlite3 = null,
    mutex: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn init(self: *SqliteBackend, db_path: [:0]const u8) Error!void {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.err("SQLite: {s}", .{err_msg});
            _ = c.sqlite3_close(db);
            return switch (rc) {
                c.SQLITE_CANTOPEN => Error.DatabaseNotFound,
                c.SQLITE_PERM => Error.PermissionDenied,
                c.SQLITE_FULL => Error.DiskFull,
                c.SQLITE_CORRUPT => Error.DatabaseCorrupt,
                else => error.OpenFailed,
            };
        }
        self.db = db;
    }

    pub fn exec(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
        _ = allocator;
        self.mutex.lock();
        defer self.mutex.unlock();
        const db = self.db orelse return Error.DatabaseNotFound;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        defer {
            if (stmt) |s| {
                _ = c.sqlite3_finalize(s);
            }
        }
        if (rc != c.SQLITE_OK) {
            std.debug.print("sqlite3_prepare_v2 error: {s}\n", .{@errorName(Error.PrepareFailed)});
            return Error.PrepareFailed;
        }

        for (argv, 0..) |arg, i| {
            const param_idx: c_int = @intCast(i + 1);
            if (arg.len == 0) {
                rc = c.sqlite3_bind_null(stmt, param_idx);
            } else {
                rc = c.sqlite3_bind_text(stmt, param_idx, arg.ptr, @intCast(arg.len), c.SQLITE_TRANSIENT);
            }
            if (rc != c.SQLITE_OK) {
                std.debug.print("sqlite3_bind_text error: {s}\n", .{@errorName(Error.BindFailed)});
                return Error.BindFailed;
            }
        }

        while (true) {
            rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_ROW) {
                continue;
            } else if (rc == c.SQLITE_DONE) {
                break;
            } else {
                std.debug.print("sqlite3_step error: {s}\n", .{@errorName(Error.ExecuteFailed)});
                return Error.ExecuteFailed;
            }
        }
    }

    pub fn queryRow(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
        self.mutex.lock();
        defer self.mutex.unlock();

        const db = self.db orelse return Error.DatabaseNotFound;

        var stmt: ?*c.sqlite3_stmt = null;
        const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prep_rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.err("Prepare failed: {s}", .{err_msg});
            return Error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        for (argv, 0..) |arg, i| {
            const bind_rc = c.sqlite3_bind_text(stmt, @intCast(i + 1), arg.ptr, @intCast(arg.len), c.SQLITE_TRANSIENT);
            if (bind_rc != c.SQLITE_OK) {
                return Error.BindFailed;
            }
        }

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_ROW) {
            return Error.RowNotFound;
        }

        const col_count = c.sqlite3_column_count(stmt);
        var values = try allocator.alloc([]u8, @intCast(col_count));

        for (0..@intCast(col_count)) |i| {
            const col_text = c.sqlite3_column_text(stmt, @intCast(i));
            if (col_text) |text| {
                const len = c.sqlite3_column_bytes(stmt, @intCast(i));
                values[i] = try allocator.alloc(u8, @intCast(len));
                @memcpy(values[i][0..@intCast(len)], text[0..@intCast(len)]);
            } else {
                values[i] = try allocator.alloc(u8, 0);
            }
        }

        return Row{ .values = values };
    }

    pub const Rows = struct {
        allocator: std.mem.Allocator,
        stmt: ?*c.sqlite3_stmt,

        pub fn deinit(self: *Rows) void {
            if (self.stmt) |s| {
                _ = c.sqlite3_finalize(s);
            }
        }

        pub fn next(self: *Rows) Error!?Row {
            const rc = c.sqlite3_step(self.stmt);
            if (rc == c.SQLITE_DONE) {
                return null;
            }
            if (rc != c.SQLITE_ROW) {
                return Error.QueryFailed;
            }

            const col_count = c.sqlite3_column_count(self.stmt);
            const values = self.allocator.alloc([]u8, @intCast(col_count)) catch return Error.OutOfMemory;

            for (0..@intCast(col_count)) |i| {
                const col_text = c.sqlite3_column_text(self.stmt, @intCast(i));
                if (col_text) |text| {
                    const len = c.sqlite3_column_bytes(self.stmt, @intCast(i));
                    values[i] = self.allocator.alloc(u8, @intCast(len)) catch return Error.OutOfMemory;
                    @memcpy(values[i][0..@intCast(len)], text[0..@intCast(len)]);
                } else {
                    values[i] = self.allocator.alloc(u8, 0) catch return Error.OutOfMemory;
                }
            }

            return Row{ .values = values };
        }
    };

    pub const Row = struct {
        values: [][]u8,

        pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
            for (self.values) |v| {
                allocator.free(v);
            }
            allocator.free(self.values);
        }
    };

    pub fn query(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
        self.mutex.lock();
        defer self.mutex.unlock();
        const db = self.db orelse return Error.DatabaseNotFound;

        var stmt: ?*c.sqlite3_stmt = null;
        const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prep_rc != c.SQLITE_OK) {
            return Error.PrepareFailed;
        }

        for (argv, 0..) |arg, i| {
            const bind_rc = c.sqlite3_bind_text(stmt, @intCast(i + 1), arg.ptr, @intCast(arg.len), c.SQLITE_TRANSIENT);
            if (bind_rc != c.SQLITE_OK) {
                _ = c.sqlite3_finalize(stmt);
                return Error.BindFailed;
            }
        }

        return Rows{
            .allocator = allocator,
            .stmt = stmt,
        };
    }

    pub fn deinit(self: *SqliteBackend) void {
        if (self.db) |d| {
            _ = c.sqlite3_close(d);
        }
    }
};

test {
    _ = @import("sqlite_test.zig");
}
