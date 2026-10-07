const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 064 — Add the `logs` table for the frontend_log_post
/// endpoint (POST /api/log). The frontend batches browser-side
/// `console.error` / unhandled rejections / Vue runtime warnings and
/// ships them to the backend over a single POST; the backend dedups
/// by (kind, message, source, line, route_path) within a 1s window
/// and increments `count` instead of inserting a new row.
///
/// The schema mirrors the dedup key (kind, message, source, line,
/// route_path) plus a per-row `count` that the dedup UPDATE bumps.
/// Indexes on `created_at DESC` (latest-first reads) and `level`
/// (filter for warnings/errors in /api/log GET) support the
/// /api/log GET endpoint that lists recent logs.
///
/// Note: this migration was originally numbered 063 on this branch,
/// but main had already taken `063` for `add_session_auto_retry_until_stop`.
/// Renamed to 064 to avoid the collision.
pub const Migration064AddFrontendLogs = struct {
    pub const version: u32 = 64;
    pub const name = "add_frontend_logs";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(
            allocator,
            \\CREATE TABLE IF NOT EXISTS logs (
            \\  id TEXT PRIMARY KEY,
            \\  created_at INTEGER NOT NULL,
            \\  level TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  message TEXT NOT NULL,
            \\  stack TEXT,
            \\  source TEXT,
            \\  line INTEGER,
            \\  route_path TEXT,
            \\  session_id TEXT,
            \\  count INTEGER NOT NULL DEFAULT 1
            \\)
        , &[_][]const u8{});
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC)",
            &[_][]const u8{},
        );
        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level)",
            &[_][]const u8{},
        );
    }
};
