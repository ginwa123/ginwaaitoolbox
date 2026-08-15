//! Data model for the `routines` entity table.
//!
//! One row per routine task — a recurring scheduled chat task. The
//! row is paired 1:1 with a `workspace_item_tasks` row (Migration
//! 044 introduced `task_type = 'routine'` to discriminate the two).
//!
//! Schema: Migration 044 (`Migration044AddRoutines`).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
task_id: []u8,
/// Standard 5-field cron expression (e.g. `"*/5 * * * *"` for
/// every 5 minutes). Validated by `routines/cron.zig`.
schedule: []u8,
/// The system-prompt injection that re-fires the agent on each run.
initial_prompt: []u8,
enabled: bool = true,
last_run_at: ?[]u8 = null,
next_run_at: []u8,
/// One of `"success"` | `"failed"` | `"running"` | NULL/empty (the
/// canonical "never run" state is NULL on disk). The DB column has
/// no CHECK constraint.
last_status: []u8 = &.{},
last_error: ?[]u8 = null,
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    task_id: []const u8,
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool = true,
    last_run_at: ?[]const u8 = null,
    next_run_at: []const u8,
    last_status: []const u8 = "",
    last_error: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .task_id = try allocator.dupe(u8, args.task_id),
        .schedule = try allocator.dupe(u8, args.schedule),
        .initial_prompt = try allocator.dupe(u8, args.initial_prompt),
        .enabled = args.enabled,
        .last_run_at = if (args.last_run_at) |lr|
            try allocator.dupe(u8, lr)
        else
            null,
        .next_run_at = try allocator.dupe(u8, args.next_run_at),
        .last_status = try allocator.dupe(u8, args.last_status),
        .last_error = if (args.last_error) |le| try allocator.dupe(u8, le) else null,
        .created_at = if (args.created_at) |ca|
            try allocator.dupe(u8, ca)
        else
            null,
        .updated_at = if (args.updated_at) |ua|
            try allocator.dupe(u8, ua)
        else
            null,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.task_id);
    allocator.free(self.schedule);
    allocator.free(self.initial_prompt);
    if (self.last_run_at) |lr| allocator.free(lr);
    allocator.free(self.next_run_at);
    if (self.last_status.len > 0) allocator.free(self.last_status);
    if (self.last_error) |le| allocator.free(le);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .task_id = self.task_id,
        .schedule = self.schedule,
        .initial_prompt = self.initial_prompt,
        .enabled = self.enabled,
        .last_run_at = if (self.last_run_at) |lr| lr else null,
        .next_run_at = self.next_run_at,
        .last_status = self.last_status,
        .last_error = if (self.last_error) |le| le else null,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
    });
}