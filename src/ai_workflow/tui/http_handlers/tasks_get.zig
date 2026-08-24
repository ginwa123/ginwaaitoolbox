//! `GET /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`
//!
//! Single-task fetch for the kanban Task details dialog. Returns
//! `{ task: {...} }` using the same `WorkspaceItemTaskResponse` shape
//! as the list endpoint (`GET .../tasks`) so the frontend `Task` type
//! is unchanged. 404 when the task does not exist under the item.
//!
//! Replaces the dialog-open list refetch (`?limit=100` + pluck-one),
//! which downloaded every task's routine JOINs, tags, and base64
//! image_urls to update one row.
//!
//! Layered as `useCase` (resolve singleton + DB query + git branch +
//! build response) and a thin handler that maps errors to status
//! codes / JSON. Mirrors `tasks_list.zig` field-for-field.
//!
//! Plan: docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

pub const TasksGetError = error{
    QueryFailed,
    /// The task does not exist under the given item — the handler
    /// maps this to 404.
    TaskNotFound,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const TasksGetResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
    item_id: []const u8,
    task_id: []const u8,
) TasksGetError!TasksGetResult {
    const task_opt = ai_mod.llm_history.getWorkspaceItemTaskById(
        allocator,
        db,
        item_id,
        task_id,
    ) catch return error.QueryFailed;

    const task = task_opt orelse return error.TaskNotFound;
    defer task.deinit(allocator);

    // Kanban-task-git-branch (plan:
    // docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md).
    // Same fallback chain as the list endpoint: prefer the task's
    // worktree cwd; fall back to the parent item's path. Empty string
    // when neither is set → no badge on the frontend.
    const item_path = fetchWorkspaceItemPath(allocator, db, item_id) catch "";
    const cwd = if (task.git_worktree_cwd.len > 0)
        task.git_worktree_cwd
    else
        item_path;
    const git_branch: ?[]const u8 = blk: {
        if (cwd.len == 0) break :blk null;
        const branch = resolveGitBranch(allocator, io, cwd);
        if (branch.len == 0) break :blk null;
        break :blk branch;
    };

    // Routine metadata conversion — identical to tasks_list.zig (the
    // DB-layer RoutineMeta carries a `routines_model.RoutineRunStatus`
    // enum; the response layer wants a `?[]const u8` string).
    const routine_meta: ?http_response.RoutineMetaResponse = if (task.routine) |r| .{
        .schedule = r.schedule,
        .initial_prompt = r.initial_prompt,
        .enabled = r.enabled,
        .last_run_at = r.last_run_at,
        .next_run_at = r.next_run_at,
        .last_status = r.last_status.dbValue(),
        .last_error = r.last_error,
    } else null;

    const resp = http_response.WorkspaceItemTaskResponse{
        .id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .description = task.description,
        .task_type = task.task_type,
        .routine = routine_meta,
        .created_at = task.created_at,
        .updated_at = task.updated_at,
        .is_pinned = task.is_pinned,
        .pinned_position = task.pinned_position,
        .kanban_column_id = task.kanban_column_id,
        .kanban_position = task.kanban_position,
        .cwd = task.cwd,
        .is_auto_retry_until_stop = task.is_auto_retry_until_stop,
        .last_finish_reason = task.last_finish_reason,
        .needs_human_review = task.needs_human_review,
        .tags = task.tags,
        .image_urls = task.image_urls,
        .git_branch = git_branch,
    };

    // Wrap in `{ "task": {...} }` — the frontend's getTask() reads
    // data.task. Stringify deep-copies the borrowed slices into the
    // response JSON, so the outer task.deinit above is safe.
    return std.json.Stringify.valueAlloc(allocator, .{ .task = resp }, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    // Empty-slice-as-NULL binding rule: SqliteBackend binds "" as SQL
    // NULL, which would turn `WHERE t.id = ?` into `WHERE t.id IS
    // NULL` (always false, silently). Guard before any DB call.
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, io, item_id, task_id) catch |err| {
        const status: u16 = switch (err) {
            error.TaskNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskNotFound => "task not found",
            error.QueryFailed => "Failed to fetch task",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// =====================================================================
// Git branch resolution (kanban-task-git-branch plan, 2026-08-06)
// =====================================================================

/// Look up the parent workspace item's `path`. Used as the fallback
/// cwd for the git_branch lookup when a task has no worktree bound.
///
/// Single SQL query (1 row expected — workspace_item_id PKs are
/// unique). Returns the empty string when the row is missing or the
/// path column is NULL — caller treats empty as "no badge".
///
/// Documented duplication from tasks_list.zig (both helpers are
/// file-private there); the two handlers share the schema contract,
/// not the query shape.
fn fetchWorkspaceItemPath(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
) ![]u8 {
    var rows = db.query(
        allocator,
        "SELECT COALESCE(path, '') FROM workspace_items WHERE id = ?",
        &.{item_id},
    ) catch return "";
    defer rows.deinit();
    const row = (try rows.next()) orelse return "";
    defer row.deinit(allocator);
    return try allocator.dupe(u8, row.values[0]);
}

/// Run `git -C <path> symbolic-ref --short HEAD` and fall back to
/// `git -C <path> rev-parse --abbrev-ref HEAD` for detached HEAD.
/// Returns the trimmed branch name (e.g. "main", "feature/x") or
/// the empty string for: non-repo, detached HEAD ("HEAD" literal),
/// permission denied, spawn failure, etc. Caller maps empty → null.
///
/// Best-effort — git is not always available, and the path may not
/// be a repo. Any error returns ""; we never surface a 500 for git
/// failures because the branch badge is best-effort decoration.
fn resolveGitBranch(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) []const u8 {
    // Attempt 1: symbolic-ref --short HEAD. Fails on detached HEAD
    // (returns non-zero exit with a "not a symbolic ref" message).
    const sym_argv = [_][]const u8{ "git", "-C", path, "symbolic-ref", "--short", "HEAD" };
    if (std.process.run(allocator, io, .{ .argv = &sym_argv })) |sym_result| {
        if (sym_result.term.exited == 0) {
            return std.mem.trim(u8, sym_result.stdout, " \n\r\t");
        }
        // Fall through to attempt 2.
    } else |_| {
        // Spawn failure (e.g. git not on PATH) — give up silently.
        return "";
    }

    // Attempt 2: rev-parse --abbrev-ref HEAD. Works for detached HEAD
    // too (returns literal "HEAD"), which we map to "" so the
    // frontend omits the badge.
    const rev_argv = [_][]const u8{ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" };
    const rev_result = std.process.run(allocator, io, .{ .argv = &rev_argv }) catch return "";
    if (rev_result.term.exited != 0) return "";
    const branch = std.mem.trim(u8, rev_result.stdout, " \n\r\t");
    if (std.mem.eql(u8, branch, "HEAD")) return "";
    return branch;
}
