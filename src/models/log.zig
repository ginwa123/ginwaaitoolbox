//! Data model for the `logs` entity table.
//!
//! Captures structured log entries emitted by the agent runtime —
//! both backend (Zig) logs and frontend (browser console) logs.
//!
//! Schema: Migration 064 (`add_frontend_logs`).
//!
//! Note: `created_at` is stored as INTEGER (unix-ms) on this table —
//! distinct from the DATETIME convention used by most other tables.

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
/// Unix-milliseconds timestamp (NOT a DATETIME string). The
/// frontend's `console.error` hook stamps this directly with
/// `Date.now()` before posting to the backend.
created_at: i64,
/// One of `"error"` | `"warn"` | `"info"` | `"debug"` | `"trace"`.
/// The DB column has no CHECK constraint.
level: []u8,
/// One of `"console_error"` | `"console_warn"` |
/// `"unhandled_rejection"` | `"window_error"` | `"unknown"`. The
/// DB column has no CHECK constraint.
kind: []u8,
message: []u8,
stack: ?[]u8 = null,
source: ?[]u8 = null,
line: ?i64 = null,
route_path: ?[]u8 = null,
session_id: ?[]u8 = null,
/// De-duplication counter. Frontend batches consecutive identical
/// log entries and bumps this rather than inserting a new row.
count: i64 = 1,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    created_at: i64,
    level: []const u8,
    kind: []const u8,
    message: []const u8,
    stack: ?[]const u8 = null,
    source: ?[]const u8 = null,
    line: ?i64 = null,
    route_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    count: i64 = 1,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .created_at = args.created_at,
        .level = try allocator.dupe(u8, args.level),
        .kind = try allocator.dupe(u8, args.kind),
        .message = try allocator.dupe(u8, args.message),
        .stack = if (args.stack) |s| try allocator.dupe(u8, s) else null,
        .source = if (args.source) |s| try allocator.dupe(u8, s) else null,
        .line = args.line,
        .route_path = if (args.route_path) |r|
            try allocator.dupe(u8, r)
        else
            null,
        .session_id = if (args.session_id) |sid|
            try allocator.dupe(u8, sid)
        else
            null,
        .count = args.count,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.level);
    allocator.free(self.kind);
    allocator.free(self.message);
    if (self.stack) |s| allocator.free(s);
    if (self.source) |s| allocator.free(s);
    if (self.route_path) |r| allocator.free(r);
    if (self.session_id) |sid| allocator.free(sid);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .created_at = self.created_at,
        .level = self.level,
        .kind = self.kind,
        .message = self.message,
        .stack = if (self.stack) |s| s else null,
        .source = if (self.source) |s| s else null,
        .line = self.line,
        .route_path = if (self.route_path) |r| r else null,
        .session_id = if (self.session_id) |sid| sid else null,
        .count = self.count,
    });
}