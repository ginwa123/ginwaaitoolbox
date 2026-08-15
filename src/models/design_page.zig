//! Data model for the `design_pages` entity table.
//!
//! One row per design page (e.g. "Login", "Dashboard"). Pages belong
//! to a `design` workspace item. Element HTML bodies live on disk
//! under `<workspace_item.path>/.nalar/design/<page_name>/<element>.html`.
//!
//! Schema: Migration 055 (`create_design_pages`) + 056
//! (`upgrade_design_pages_to_file_model`) + 066 (1:1 chat pairing via
//! `workspace_item_task_id`) + 071 (width/height/x/y defaults).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
workspace_item_id: []u8,
name: []u8,
position: i64 = 0,
created_at: []u8,
updated_at: []u8,
/// Viewport dimensions in design-px.
width: i64 = 1440,
height: i64 = 1024,
/// Pan-zoom canvas offset for the page (NOT the page origin).
x: i64 = 0,
y: i64 = 0,
/// Migration 066 — 1:1 FK to `workspace_item_tasks.id`. Set
/// atomically by `set_design_page` at create time. Empty slice
/// `""` for legacy pre-Migration-066 rows.
workspace_item_task_id: []u8 = &.{},

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    position: i64 = 0,
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    width: i64 = 1440,
    height: i64 = 1024,
    x: i64 = 0,
    y: i64 = 0,
    workspace_item_task_id: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .workspace_item_id = try allocator.dupe(u8, args.workspace_item_id),
        .name = try allocator.dupe(u8, args.name),
        .position = args.position,
        .created_at = try allocator.dupe(u8, args.created_at),
        .updated_at = try allocator.dupe(u8, args.updated_at),
        .width = args.width,
        .height = args.height,
        .x = args.x,
        .y = args.y,
        .workspace_item_task_id = try allocator.dupe(u8, args.workspace_item_task_id),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.workspace_item_id);
    allocator.free(self.name);
    allocator.free(self.created_at);
    allocator.free(self.updated_at);
    if (self.workspace_item_task_id.len > 0) allocator.free(self.workspace_item_task_id);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .workspace_item_id = self.workspace_item_id,
        .name = self.name,
        .position = self.position,
        .created_at = self.created_at,
        .updated_at = self.updated_at,
        .width = self.width,
        .height = self.height,
        .x = self.x,
        .y = self.y,
        .workspace_item_task_id = self.workspace_item_task_id,
    });
}