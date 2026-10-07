const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration046AddGitWorktreeCwdToSessions = struct {
    pub const version: u32 = 46;
    pub const name = "add_git_worktree_cwd_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Nullable: NULL means "no worktree bound". The application code
        // maps NULL → "" via COALESCE for the API surface, matching the
        // convention used for `cwd`, `created_at`, `updated_at`, and
        // `selected_profile_model` (see llm_history.zig:1802).
        try db.exec(allocator,
            "ALTER TABLE sessions ADD COLUMN git_worktree_cwd TEXT",
            &[_][]const u8{});
    }
};
