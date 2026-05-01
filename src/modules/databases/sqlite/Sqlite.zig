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
        Canceled,
    };

pub const SqliteBackend = struct {
    const c = @cImport(@cInclude("sqlite3.h"));

    io: std.Io = .failing,
    db: ?*c.sqlite3 = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(self: *SqliteBackend, io: std.Io, db_path: [:0]const u8) Error!void {
        self.io = io;
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

        // Enable WAL mode for better concurrent access (crucial for multi-threaded usage)
        // WAL allows concurrent reads and single writer, preventing "database is locked" errors
        // Note: Using null for err_msg - we don't need the error details
        _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);

        // Also enable busy timeout for better concurrency handling
        _ = c.sqlite3_exec(db, "PRAGMA busy_timeout=5000;", null, null, null); // 5 second timeout
    }

    pub fn exec(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
        _ = allocator;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const db = self.db orelse return Error.DatabaseNotFound;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        defer {
            if (stmt) |s| {
                _ = c.sqlite3_finalize(s);
            }
        }
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.debug.print("sqlite3_prepare_v2 error: {s}\n", .{err_msg});
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
                const err_msg = c.sqlite3_errmsg(db);
                std.debug.print("sqlite3_bind_text error: {s}\n", .{err_msg});
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
                const err_msg = c.sqlite3_errmsg(db);
                std.debug.print("sqlite3_step error: {s}\n", .{err_msg});
                return Error.ExecuteFailed;
            }
        }
    }

    pub fn queryRow(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

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
            const err_msg = c.sqlite3_errmsg(db);
            std.debug.print("sqlite3_step error (queryRow): {s}\n", .{err_msg});
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
                // Note: Can't get err_msg here since stmt is already finalized after this returns
                std.debug.print("sqlite3_step error (Rows.next): rc={}\n", .{rc});
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
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const db = self.db orelse return Error.DatabaseNotFound;

        var stmt: ?*c.sqlite3_stmt = null;
        const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prep_rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.debug.print("sqlite3_prepare_v2 error (query): {s}\n", .{err_msg});
            return Error.PrepareFailed;
        }

        for (argv, 0..) |arg, i| {
            const bind_rc = c.sqlite3_bind_text(stmt, @intCast(i + 1), arg.ptr, @intCast(arg.len), c.SQLITE_TRANSIENT);
            if (bind_rc != c.SQLITE_OK) {
                const err_msg = c.sqlite3_errmsg(db);
                std.debug.print("sqlite3_bind_text error (query): {s}\n", .{err_msg});
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

