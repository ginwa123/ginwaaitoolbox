//! Data model for the `worker` entity table.
//!
//! One row per active agent worker (one per session that's currently
//! running). The scheduler / monitor queries this table to surface
//! "Active Workers" in the system prompt and the sidebar status
//! indicator.
//!
//! Schema: Migration 019 (`create_worker_table`) + Migration 020
//! (`add_worker_extra_fields`) + Migration 033 (`cancelled`) +
//! Migration 075 (`last_activity_nano` rename) + Migration 092
//! (`user_id` ownership; NULL/''/'user_system' = visible to all).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
session_id: []u8,
working_directory: ?[]u8 = null,
/// Unix-seconds timestamp of the last heartbeat. Updated by the
/// worker on every tool call.
last_activity: i64 = 0,
last_activity_description: ?[]u8 = null,
created_at: []u8,
/// Set to `true` by the worker shutdown handler. Cancelled rows are
/// filtered out of "Active Workers" listings but kept for
/// post-mortem debugging.
cancelled: bool = false,
/// Owner user id (Migration 092). `user_system`, NULL, or '' means
/// visible to all users; any other value is private to that user.
user_id: []u8,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    session_id: []const u8,
    working_directory: ?[]const u8 = null,
    last_activity: i64 = 0,
    last_activity_description: ?[]const u8 = null,
    created_at: []const u8 = "",
    cancelled: bool = false,
    user_id: []const u8 = "user_system",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .session_id = try allocator.dupe(u8, args.session_id),
        .working_directory = if (args.working_directory) |wd|
            try allocator.dupe(u8, wd)
        else
            null,
        .last_activity = args.last_activity,
        .last_activity_description = if (args.last_activity_description) |lad|
            try allocator.dupe(u8, lad)
        else
            null,
        .created_at = try allocator.dupe(u8, args.created_at),
        .cancelled = args.cancelled,
        .user_id = try allocator.dupe(u8, args.user_id),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.session_id);
    if (self.working_directory) |wd| allocator.free(wd);
    if (self.last_activity_description) |lad| allocator.free(lad);
    allocator.free(self.created_at);
    allocator.free(self.user_id);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .session_id = self.session_id,
        .working_directory = if (self.working_directory) |wd| wd else null,
        .last_activity = self.last_activity,
        .last_activity_description = if (self.last_activity_description) |lad|
            lad
        else
            null,
        .created_at = self.created_at,
        .cancelled = self.cancelled,
        .user_id = self.user_id,
    });
}