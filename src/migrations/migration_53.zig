const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration053AddKanbanColumnDescription = struct {
    pub const version: u32 = 53;
    pub const name = "add_kanban_column_description";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Kanban column description — Chunk 1 of the
        // kanban-column-description-settings plan. Each kanban
        // column gains a free-text "meaning" field that the
        // Settings UI displays and edits. NOT NULL with DEFAULT ''
        // so existing rows (which have no description) survive the
        // ALTER TABLE without backfill. The frontend uses the
        // empty string as the "no description" sentinel — the
        // Settings UI shows "Add a description…" placeholder for
        // empty descriptions.
        //
        // Why NOT NULL (vs nullable):
        //   1. The application always reads description as
        //      []const u8 (never ?[]const u8) — a nullable column
        //      would force every SELECT to COALESCE and every
        //      INSERT to handle NULL explicitly.
        //   2. The DB-level NOT NULL is a defensive check; the
        //      application layer never writes NULL.
        //   3. Mirrors the project's convention for short text
        //      fields with a sentinel "absent" value.
        try db.exec(allocator,
            "ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''",
            &[_][]const u8{},
        );
    }
};
