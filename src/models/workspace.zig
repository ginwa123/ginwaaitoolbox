//! Data model for the `workspaces` entity table.
//!
//! One row per workspace. A workspace owns 0..N `workspace_items`
//! (kanbans, designs, folders) and is the top-level container in the
//! sidebar tree.
//!
//! Schema: Migration 020 (`create_workspaces`) + Migration 022
//! (`add_position_to_workspaces`).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
name: []u8,
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,
/// Drag-and-drop sort key (Migration 022). Higher = higher in the
/// sidebar. Scoped globally (no parent scope).
position: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    name: []const u8,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    position: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .name = try allocator.dupe(u8, args.name),
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
        .updated_at = if (args.updated_at) |ua| try allocator.dupe(u8, ua) else null,
        .position = args.position,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    if (self.name.len > 0) allocator.free(self.name);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
}

/// Deep-copy constructor. Useful for callers that need an owned copy
/// of an existing instance (e.g. a row pulled from a query result).
pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .name = self.name,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
        .position = self.position,
    });
}