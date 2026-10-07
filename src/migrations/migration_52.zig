const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration052DropSessionIdFromWorkspaceItemTasks = struct {
    pub const version: u32 = 52;
    pub const name = "drop_session_id_from_workspace_item_tasks";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Drop the redundant `session_id` column on `workspace_item_tasks`.
        //
        // The project's established convention is that for kanban /
        // routine tasks, `workspace_item_tasks.id` IS the session_id:
        // the frontend's AppLayout.vue binds `:chat-id="activeTask.id"`,
        // ChatView sets `sessionId.value = props.chatId.replace(/^chat-/, '')`,
        // the LLM call uses that as the session_id, and
        // `routines_run.zig` returns `{"session_id": "<task_id>"}` on
        // a routine fire. The `workspace_item_tasks.session_id` column
        // was therefore always the same value as `id` (when populated)
        // or NULL (when the task chat had not yet been started).
        //
        // The column was being read by exactly one query —
        // `getWorkspaceContext`'s anchor (`WHERE t.session_id = ?`).
        // For tasks where the column was NULL (the common case for
        // freshly-created kanban tasks, because the frontend's
        // `api.createTask` does NOT send a session_id in the request
        // body), the lookup returned zero rows and the system prompt's
        // `## Workspace Context` section was silently omitted. The
        // LLM then had to ask the user for the workspace_id / item_id
        // every time, which broke the `kanban_*` tools and any other
        // workspace-scoped tool that relies on context.
        //
        // After this migration, the anchor query uses `t.id = ?`
        // directly (the canonical session id), and the column is
        // dropped. The frontend's `Task.session_id` field is
        // also removed — clients should use `task.id` for the same
        // purpose. SQLite supports `ALTER TABLE ... DROP COLUMN`
        // since 3.35; the project's bundled sqlite is recent enough.
        //
        // Schema before: workspace_item_tasks (..., session_id TEXT, ...)
        // Schema after:  workspace_item_tasks (...,                  ...)
        //
        // `dropColumnIfExists` (not raw `DROP COLUMN`) because the
        // canonical migration 034 schema no longer declares
        // `session_id` (it was a redundant column — `task.id` IS the
        // session id). For fresh-DB users the column never exists, so
        // the raw `DROP COLUMN` would crash with "no such column:
        // session_id".
        try dropColumnIfExists(.{ .db = db }, allocator, "workspace_item_tasks", "session_id");
        // The session_id index (created in Migration 034) is now
        // unused and would just slow writes down. Drop it.
        try db.exec(allocator,
            "DROP INDEX IF EXISTS idx_workspace_item_tasks_session_id",
            &[_][]const u8{},
        );
        // ANALYZE so the query planner drops the dropped index from
        // its stats. Mirrors the ANALYZE-after-DDL pattern used by
        // Migrations 041/042/043/048/049/050/051.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
