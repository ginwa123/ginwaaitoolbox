//! Data layer for the kanban workspace item (item_type='kanban').
//!
//! Each kanban workspace item has N user-defined columns (the default
//! seed is `todo / in progress / done`). Tasks assigned to a kanban
//! item get a `kanban_column_id` + `kanban_position` and are
//! drag-and-drop reorderable within and across columns.
//!
//! Schema: see Migration 051 (`Migration051AddKanban` in
//! `src/ai_workflow/tui/migration.zig`).
//!
//! SQL convention: every SELECT aliases its tables (`kc` for
//! `kanban_columns`, `t` for `workspace_item_tasks`) and qualifies
//! every column reference with the alias. See the project memory
//! `nalar-sql-alias-tables.md`.
//!
//! Row ownership: each `db.query()` row's `values[i]` slices are
//! owned by the `Row` and freed by `row.deinit(allocator)`. To keep
//! a value past the loop iteration, the field is duplicated with
//! `allocator.dupe(u8, row.values[i])`. Strings returned by
//! `listColumns` are owned by the caller and must be released with
//! `freeColumns`.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// One kanban column row, fully duplicated into heap memory.
/// Free with `freeColumns(allocator, slice)`.
pub const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    position: i64,
    created_at: []u8,
};

/// Free the per-column strings and the backing slice in one call.
pub fn freeColumns(allocator: std.mem.Allocator, cols: []KanbanColumn) void {
    for (cols) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_item_id);
        allocator.free(c.name);
        allocator.free(c.created_at);
    }
    allocator.free(cols);
}

/// List the columns of a kanban workspace item in `position` order.
///
/// Returns an owned slice; the caller must release it with
/// `freeColumns(allocator, slice)`. If the item has no columns, the
/// slice has length 0 (not an error).
pub fn listColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]KanbanColumn {
    var q = try db.query(allocator,
        \\SELECT kc.id, kc.workspace_item_id, kc.name, kc.position, COALESCE(kc.created_at, '')
        \\FROM kanban_columns kc
        \\WHERE kc.workspace_item_id = ?
        \\ORDER BY kc.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(KanbanColumn).empty;
    errdefer {
        for (rows.items) |c| {
            allocator.free(c.id);
            allocator.free(c.workspace_item_id);
            allocator.free(c.name);
            allocator.free(c.created_at);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .position = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[4]),
        });
    }
    return rows.toOwnedSlice(allocator);
}
