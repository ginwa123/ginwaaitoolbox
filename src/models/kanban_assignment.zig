//! Data model for the `kanban` join table.
//!
//! One row per task-to-column assignment. A row exists iff the task
//! is currently assigned to a kanban column; unassigned tasks have
//! NO row here.
//!
//! Schema: Migration 072 (`Migration072ExtractKanbanTable`). Before
//! 072, the per-task kanban state lived directly on
//! `workspace_item_tasks.kanban_column_id` + `.kanban_position`.

const std = @import("std");

pub const EntityId = []u8;

workspace_item_task_id: EntityId,
kanban_column_id: []u8,
/// Position within the column (0 = top, higher = lower).
kanban_position: i64 = 0,

const Self = @This();

pub const InitArgs = struct {
    workspace_item_task_id: []const u8,
    kanban_column_id: []const u8,
    kanban_position: i64 = 0,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .workspace_item_task_id = try allocator.dupe(u8, args.workspace_item_task_id),
        .kanban_column_id = try allocator.dupe(u8, args.kanban_column_id),
        .kanban_position = args.kanban_position,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.workspace_item_task_id);
    allocator.free(self.kanban_column_id);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .workspace_item_task_id = self.workspace_item_task_id,
        .kanban_column_id = self.kanban_column_id,
        .kanban_position = self.kanban_position,
    });
}