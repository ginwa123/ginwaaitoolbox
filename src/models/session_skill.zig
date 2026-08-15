//! Data model for the `session_skills` entity table.
//!
//! Tracks which skills each session has loaded. The skill loader
//! writes here so a session restart re-hydrates the same skill set
//! without re-reading the skill files from disk.
//!
//! Schema: Migration 009 (`add_session_skills`).
//!
//! Composite PRIMARY KEY: (session_id, skill_name).
//!
//! Note: `loaded_at` is stored as INTEGER (unix-seconds), distinct
//! from the DATETIME convention used by most other tables.

const std = @import("std");

pub const EntityId = struct {
    session_id: []const u8,
    skill_name: []const u8,
};

session_id: []u8,
skill_name: []u8,
/// The verbatim SKILL.MD content as loaded at `loaded_at`. Used by
/// the compact-and-rehydrate flow to detect drift between the
/// on-disk skill file and what the agent has in context.
content: []u8,
/// Unix-seconds timestamp of the load event.
loaded_at: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    session_id: []const u8,
    skill_name: []const u8,
    content: []const u8,
    loaded_at: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .session_id = try allocator.dupe(u8, args.session_id),
        .skill_name = try allocator.dupe(u8, args.skill_name),
        .content = try allocator.dupe(u8, args.content),
        .loaded_at = args.loaded_at,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.session_id);
    allocator.free(self.skill_name);
    allocator.free(self.content);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .session_id = self.session_id,
        .skill_name = self.skill_name,
        .content = self.content,
        .loaded_at = self.loaded_at,
    });
}