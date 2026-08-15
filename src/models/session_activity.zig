//! Data model for the `session_activity` entity table.
//!
//! Append-only timeline of one-line "what did the agent just do?"
//! entries, surfaced in the ChatView's "Thinking..." timeline panel.
//!
//! Schema: Migration 068 (`add_session_activity`).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
session_id: []u8,
/// One-line description like
/// `"Implementing | Adding system-deps probe to custom_http_client/build.zig"`.
/// Never empty — callers MUST supply a non-empty description on
/// INSERT (the column is NOT NULL with no DEFAULT).
description: []u8,
created_at: []u8,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    session_id: []const u8,
    description: []const u8,
    created_at: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .session_id = try allocator.dupe(u8, args.session_id),
        .description = try allocator.dupe(u8, args.description),
        .created_at = try allocator.dupe(u8, args.created_at),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.session_id);
    allocator.free(self.description);
    allocator.free(self.created_at);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .session_id = self.session_id,
        .description = self.description,
        .created_at = self.created_at,
    });
}