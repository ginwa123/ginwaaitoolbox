const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration103CreateWorkspaceSecrets = struct {
    pub const version: u32 = 103;
    pub const name = "create_workspace_secrets";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_secrets (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    name TEXT NOT NULL,
            \\    value TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Only ONE index, on purpose. `uq_workspace_secrets_name` is a
        // UNIQUE index on `(workspace_id, name)`, and a unique index is an
        // ordinary b-tree that SQLite will use for `WHERE workspace_id = ?`
        // and for the `ORDER BY name` the list path carries. A second index
        // on the same column pair would cost an extra write per INSERT and
        // UPDATE for no additional lookup the first one cannot serve.
        //
        // One name per workspace, enforced in the database rather than only
        // by the store's pre-check: two secrets called `GITHUB_TOKEN` in one
        // workspace is a user mistake that deserves a clean 409, not a
        // substitution that silently picks whichever row the planner finds
        // first. Scoped to `workspace_id`, so a second workspace is free to
        // reuse the same name.
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS uq_workspace_secrets_name
            \\ON workspace_secrets(workspace_id, name)
        , &[_][]const u8{});
    }
};
