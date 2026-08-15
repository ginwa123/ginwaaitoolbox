//! Data model for the `sessions` entity table.
//!
//! One row per active chat session. Sessions are created lazily when
//! a task spawns an agent run; the session_id == task_id invariant
//! holds for routine tasks.
//!
//! Schema: Migration 008 (`create_sessions_table`) + 012 (cwd) +
//! 016 (workspace_id) + 029 (timestamps) + 035
//! (selected_profile_model) + 046 (git_worktree_cwd) + 063
//! (is_auto_retry_until_stop + last_finish_reason).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
name: []u8,
/// One of `"active"` | `"unknown"`. The DB column has no CHECK
/// constraint, so unknown values are stored verbatim.
status: []u8,
cwd: ?[]u8 = null,
workspace_id: ?[]u8 = null,
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,
/// Migration 035 — name of the LLM profile from
/// `LlmConfig.profiles`. NULL when the session uses the
/// backend-default profile.
selected_profile_model: ?[]u8 = null,
/// Migration 046 — absolute path of the git worktree bound to this
/// session. NULL when no worktree is bound.
git_worktree_cwd: ?[]u8 = null,
/// Migration 063 — opt-in flag for unattended mode. Wire-format is
/// `"0"` / `"1"` to match the SQL INTEGER column.
is_auto_retry_until_stop: bool = false,
/// Migration 063 — denormalized cache of the most recent
/// `finish_reason` the workflow observed. Empty until the first
/// successful turn; never NULL at the API edge.
last_finish_reason: []u8 = &.{},

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8 = "active",
    cwd: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    selected_profile_model: ?[]const u8 = null,
    git_worktree_cwd: ?[]const u8 = null,
    is_auto_retry_until_stop: bool = false,
    last_finish_reason: []const u8 = "",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .name = try allocator.dupe(u8, args.name),
        .status = try allocator.dupe(u8, args.status),
        .cwd = if (args.cwd) |c| try allocator.dupe(u8, c) else null,
        .workspace_id = if (args.workspace_id) |w| try allocator.dupe(u8, w) else null,
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
        .updated_at = if (args.updated_at) |ua| try allocator.dupe(u8, ua) else null,
        .selected_profile_model = if (args.selected_profile_model) |spm|
            try allocator.dupe(u8, spm)
        else
            null,
        .git_worktree_cwd = if (args.git_worktree_cwd) |gwc|
            try allocator.dupe(u8, gwc)
        else
            null,
        .is_auto_retry_until_stop = args.is_auto_retry_until_stop,
        .last_finish_reason = try allocator.dupe(u8, args.last_finish_reason),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.status);
    if (self.cwd) |c| allocator.free(c);
    if (self.workspace_id) |w| allocator.free(w);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
    if (self.selected_profile_model) |spm| allocator.free(spm);
    if (self.git_worktree_cwd) |gwc| allocator.free(gwc);
    if (self.last_finish_reason.len > 0) allocator.free(self.last_finish_reason);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .name = self.name,
        .status = self.status,
        .cwd = if (self.cwd) |c| c else null,
        .workspace_id = if (self.workspace_id) |w| w else null,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
        .selected_profile_model = if (self.selected_profile_model) |spm| spm else null,
        .git_worktree_cwd = if (self.git_worktree_cwd) |gwc| gwc else null,
        .is_auto_retry_until_stop = self.is_auto_retry_until_stop,
        .last_finish_reason = self.last_finish_reason,
    });
}