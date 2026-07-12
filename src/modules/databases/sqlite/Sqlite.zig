const std = @import("std");
const builtin = @import("builtin");

// Alternative sqlite3_bind_text binding that takes the destructor parameter
// as `isize` (a raw integer) instead of a `sqlite3_destructor_type` function
// pointer. The cImport-generated binding uses the function-pointer type,
// which Zig's comptime alignment check rejects when we try to pass `-1`
// (the SQLITE_TRANSIENT sentinel) because `-1` (= 0xFFFFFFFFFFFFFFFF) is not
// 8-byte aligned on aarch64-macos. At the C ABI level both isize and a
// function pointer occupy one 8-byte register on x86_64/aarch64 — the
// bits pass through unchanged. SQLite's compiled check
// `if (xDel == SQLITE_TRANSIENT)` is a bitwise comparison and succeeds
// regardless of whether we declared the parameter as isize or as a
// function pointer on the Zig side.
// Wrapper for `sqlite3_bind_text` that takes the destructor parameter as
// `isize` (a raw integer) instead of `sqlite3_destructor_type` (a function
// pointer). The cImport-generated binding uses the function-pointer type,
// which Zig's comptime alignment check rejects when we try to construct
// the SQLITE_TRANSIENT sentinel (= -1 cast to a function pointer, but
// `0xFFFFFFFFFFFFFFFF` is not 8-byte aligned on aarch64-macos).
//
// We side-step the alignment check by declaring this wrapper with an
// `isize` destructor parameter. At the C ABI level both `isize` and a
// function pointer occupy one 8-byte register on x86_64/aarch64 — the
// bits pass through unchanged. SQLite's compiled check
// `if (xDel == SQLITE_TRANSIENT)` is a bitwise comparison and succeeds
// regardless of whether we declared the parameter as `isize` or as a
// function pointer on the Zig side.
//
// The `@extern` builtin returns `?*const FnType` (nullable); we unwrap with
// `orelse unreachable` because the symbol is statically linked from
// `vendor/sqlite3/sqlite3.c` on all platforms.
const sqlite3_bind_text_isize_Fn = fn (
    ?*anyopaque,
    c_int,
    [*]const u8,
    c_int,
    isize,
) callconv(.c) c_int;
const sqlite3_bind_text_isize_opt: ?*const sqlite3_bind_text_isize_Fn =
    @extern(*const sqlite3_bind_text_isize_Fn, .{ .name = "sqlite3_bind_text" });
const sqlite3_bind_text_isize: *const sqlite3_bind_text_isize_Fn =
    sqlite3_bind_text_isize_opt orelse unreachable;

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

/// Cross-platform sqlite3 bindings.
///
/// IMPORTANT: The `c` declarations are scoped INSIDE `SqliteBackend` (lazily
/// resolved when the struct is referenced) — not at file level. The reason is
/// that `@cImport(@cInclude("sqlite3.h"))` requires the sqlite3 header to be
/// present in the compiler's include path AT THE TIME the import is resolved.
/// On macOS, the system's `sqlite3.h` is keg-only and not in the default
/// include path; CI installs only `openssl@3`, not `sqlite3`. Hoisting the
/// `@cImport` to file level would force every translation unit that
/// `@import("Sqlite.zig")`s to provide sqlite3 headers — including the test
/// target, which has no good reason to need them at type-check time. The
/// original (pre-windows-compatibility) code put cImport inside the struct
/// for this reason; we preserve that pattern here.
///
/// On Windows (where vendored sqlite3 is compiled in from source), the
/// `c` is a struct of manual `extern fn` declarations — also evaluated
/// lazily because the struct field of the same name is referenced only
/// when SqliteBackend is actually used.
pub const SqliteBackend = struct {
    const c = if (builtin.os.tag == .linux)
        @cImport(@cInclude("sqlite3.h"))
    else
        struct {
            pub const sqlite3 = opaque {};
            pub const sqlite3_stmt = opaque {};

            pub const SQLITE_OK: c_int = 0;
            pub const SQLITE_ROW: c_int = 100;
            pub const SQLITE_DONE: c_int = 101;
            pub const SQLITE_MISUSE: c_int = 21;
            pub const SQLITE_CANTOPEN: c_int = 14;
            pub const SQLITE_PERM: c_int = 3;
            pub const SQLITE_FULL: c_int = 13;
            pub const SQLITE_CORRUPT: c_int = 11;

            pub extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
            pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
            pub extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
            pub extern fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, callback: ?*anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]const u8) c_int;
            pub extern fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*]const u8) c_int;
            pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
            pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
            pub extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, text: [*]const u8, n: c_int, destroy: isize) c_int;
            pub extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, idx: c_int) c_int;
            pub extern fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
            pub extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, col: c_int) ?[*]const u8;
            pub extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, col: c_int) c_int;
            pub extern fn sqlite3_changes(db: ?*sqlite3) c_int;
        };

    // `SQLITE_TRANSIENT` sentinel — passed as -1 via the
    // `sqlite3_bind_text_isize` wrapper above (which takes isize instead
    // of the cImport-generated `sqlite3_destructor_type` function pointer
    // type). See the long comment on the wrapper for why this matters.
    const SQLITE_DESTRUCTOR_TRANSIENT: isize = -1;

    io: std.Io = .failing,
    db: ?*c.sqlite3 = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(self: *SqliteBackend, io: std.Io, db_path: [:0]const u8) Error!void {
        self.io = io;
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            // Demoted from `std.log.err` to `std.log.warn`: a bad path is
            // a user-input error (not a programmer error), and the wrapper
            // already surfaces it via the structured Error return value.
            // Calling `err` here triggered `log_err_count > 0` in
            // `zig build test`, which exited 1 even on passing assertions.
            std.log.warn("SQLite: {s}", .{err_msg});
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

        // Empty SQL is a successful no-op. sqlite3_prepare_v2 with a
        // zero-length input returns OK with stmt=NULL; calling step()
        // on a NULL stmt is documented as harmless. Treat the whole
        // thing as a no-op up front to avoid the NULL-stmt edge case
        // and to make the documented behavior explicit at the wrapper
        // level (callers don't need to special-case "" themselves).
        if (sql.len == 0) return;

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
                rc = sqlite3_bind_text_isize(@ptrCast(stmt), param_idx, arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
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
            // Demoted from `std.log.err` — see `init` for rationale.
            std.log.warn("Prepare failed: {s}", .{err_msg});
            return Error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        for (argv, 0..) |arg, i| {
            const bind_rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
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
        /// Tracks whether the iterator has reached SQLITE_DONE so that
        /// subsequent `next()` calls short-circuit to null without
        /// re-invoking `sqlite3_step()`. See `next` for the rationale.
        done: bool = false,

        pub fn deinit(self: *Rows) void {
            if (self.stmt) |s| {
                _ = c.sqlite3_finalize(s);
            }
        }

        pub fn next(self: *Rows) Error!?Row {
            // Defensive: once we've returned null (DONE) for a query,
            // subsequent calls should keep returning null without
            // re-invoking sqlite3_step. Empirically, calling step()
            // after DONE on a SELECT can return ROW again (with the
            // same row data) on some SQLite versions/configurations —
            // which would surface as a duplicated final row in the
            // caller's loop. Track the done state explicitly so we
            // don't depend on sqlite's rc-after-DONE behavior.
            if (self.done) return null;
            const rc = c.sqlite3_step(self.stmt);
            if (rc == c.SQLITE_DONE) {
                self.done = true;
                return null;
            }
            if (rc == c.SQLITE_MISUSE) {
                // The statement has already returned DONE and step()
                // was called again. Treat the same as DONE.
                self.done = true;
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
            const bind_rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
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
        // CRITICAL: null out `db` after closing so the Transaction code's
        // `self.backend.db == null` use-after-free guard actually fires.
        // Without this, the pointer dangles and any subsequent operation
        // would dereference freed memory.
        self.db = null;
    }

    /// Number of rows changed by the most recent INSERT/UPDATE/DELETE
    /// statement. Used by callers that need to know whether their
    /// `db.exec` actually matched any rows (the API doesn't return the
    /// change count directly). See `sqlite3_changes` in the C API.
    /// Caller is responsible for being on the same thread (or holding
    /// the mutex) as the most recent write — the count is per-connection
    /// state in SQLite, not per-statement.
    pub fn changes(self: *SqliteBackend) i64 {
        const db = self.db orelse return 0;
        return c.sqlite3_changes(db);
    }
};

