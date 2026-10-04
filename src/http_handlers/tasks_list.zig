//! `GET /api/workspaces/:workspace_id/items/:item_id/tasks`.
//!
//! Optional query params:
//!   - `limit`: u32, defaults to 20, max 100
//!   - `cursor`: string in the form `<sort_field_value>|<id>` from the
//!     previous page's `next_cursor`; pass undefined for the first page
//!   - `sort_by`: `"created_at" | "updated_at" | "name"`, default `"updated_at"`
//!   - `direction`: `"asc" | "desc"`, default `"desc"`
//!   - `column_id`: per-column pagination filter (kanban-per-column-
//!     pagination, 2026-08-06). When non-null, the SQL WHERE clause
//!     restricts the result to tasks where `kanban_column_id` matches
//!     the supplied id (or `IS NULL`, preserving legacy rows without a
//!     column). When null, the full board-wide result is returned (the
//!     original behavior; the first page of any kanban view still
//!     returns ALL columns so the columns can populate their cards).
//!   - `q`: case-insensitive substring filter on name/description/tags.
//!
//! Response: `{ tasks: [...], count, has_more, next_cursor }`.
//!
//! Layered as `useCase` (resolve singleton + parse query + DB
//! query + build response) and a thin handler that maps errors
//! to status codes / JSON.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = ai_mod.llm_history;

/// Default page size when the client doesn't pass `limit`.
const DEFAULT_PAGE_SIZE: u32 = 20;

/// Maximum page size (guards against a client asking for a million rows).
const MAX_PAGE_SIZE: u32 = 100;

/// Default sort field when the client doesn't pass `sort_by`.
/// `updated_at` is the default because that's what the user wants
/// to see (most recently renamed/updated task on top).
const DEFAULT_SORT_FIELD: llm_history.TaskSortField = .updated_at;

/// Default sort direction when the client doesn't pass `direction`.
/// `desc` matches the existing "newest first" behavior.
const DEFAULT_SORT_DIRECTION: llm_history.TaskSortDirection = .desc;

pub const TasksListError = error{
    ItemIdRequired,
    QueryFailed,
    /// `std.json.Stringify.valueAlloc` / `makeWorkspaceItemTaskListResponse`
    /// can fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const TasksListInput = struct {
    item_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: llm_history.TaskSortField,
    sort_direction: llm_history.TaskSortDirection,
    /// Per-column pagination filter (kanban-per-column-pagination,
    /// 2026-08-06). When non-null, the SQL restricts to tasks whose
    /// `kanban_column_id` matches this id (or IS NULL, so legacy
    /// rows without a column are also included — see the DB fn's
    /// WHERE clause). When null, no column filter is applied (the
    /// full board-wide result is returned).
    column_id: ?[]const u8,
    /// Optional case-insensitive substring filter applied at the SQL
    /// level against `name`, `description`, `tags`. Null / empty →
    /// no filter (matches the historical behaviour). The DB fn
    /// handles the LIKE escape clause + user-input wildcard escape.
    q: ?[]const u8,
};

pub const TasksListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

/// Parse the query string into the typed input. Defaults +
/// clamping + enum-from-string parsing all happen here. Kept as a
/// free function so the use-case body stays focused on the DB
/// work.
fn parseInput(query: anytype) TasksListInput {
    const limit_str = query.get("limit") orelse "20";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_PAGE_SIZE;
    const limit: u32 = if (limit_parsed == 0)
        DEFAULT_PAGE_SIZE
    else if (limit_parsed > MAX_PAGE_SIZE)
        MAX_PAGE_SIZE
    else
        limit_parsed;

    const sort_by_str = query.get("sort_by") orelse "updated_at";
    const sort_field = llm_history.enumFromString(llm_history.TaskSortField, sort_by_str) catch DEFAULT_SORT_FIELD;

    const direction_str = query.get("direction") orelse "desc";
    const sort_direction = llm_history.enumFromString(llm_history.TaskSortDirection, direction_str) catch DEFAULT_SORT_DIRECTION;

    // Optional cursor — null when absent or empty. The cursor is the
    // "<sort_value>|<id>" pair from the previous page's next_cursor.
    // We forward it raw to the DB fn which knows how to split it.
    const cursor_raw = query.get("cursor");
    const cursor: ?[]const u8 = if (cursor_raw) |c| (if (c.len == 0) null else c) else null;

    // Optional q (search) — null when absent or empty. Empty string is
    // treated identically to "no q param" so the URL ?q= (empty value)
    // behaves the same as no q at all. The DB fn's WHERE clause is
    // gated on `q != null && q.len > 0`.
    const q_raw = query.get("q");
    const q: ?[]const u8 = if (q_raw) |q_val| (if (q_val.len == 0) null else q_val) else null;

    // Optional column_id (per-column pagination, 2026-08-06). Same
    // null-or-empty semantics as `q`: an empty `?column_id=` is
    // identical to omitting the param.
    const column_id_raw = query.get("column_id");
    const column_id: ?[]const u8 = if (column_id_raw) |c| (if (c.len == 0) null else c) else null;

    return .{
        .item_id = "", // set by the handler (path param)
        .limit = limit,
        .cursor = cursor,
        .sort_field = sort_field,
        .sort_direction = sort_direction,
        .column_id = column_id,
        .q = q,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    io: std.Io,
    input: TasksListInput,
) TasksListError!TasksListResult {
    const result = ai_mod.workspace_item_tasks.listWorkspaceItemTasksWithCursor(
        allocator,
        db,
        input.item_id,
        input.limit,
        input.cursor,
        input.sort_field,
        input.sort_direction,
        input.column_id,
        input.q,
    ) catch return error.QueryFailed;
    defer {
        for (result.tasks) |task| task.deinit(allocator);
        allocator.free(result.tasks);
    }

    // Kanban-task-git-branch (plan:
    // docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md).
    // Fetch the parent workspace item's `path` once — it's the
    // fallback cwd for tasks that don't have a worktree bound.
    // `path` is column 4 of `workspace_items` (id, workspace_id,
    // item_type, name, path, created_at, updated_at). Empty string
    // when no row exists or path is NULL.
    const item_path = fetchWorkspaceItemPath(allocator, db, input.item_id) catch "";
    defer if (item_path.len > 0) allocator.free(item_path);

    // Convert to response format.
    var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
    defer task_responses.deinit(allocator);

    for (result.tasks) |task| {
        // Compute git_branch for this task's cwd.
        // Prefer the task's worktree cwd; fall back to the item path.
        // Empty string when neither is set → no badge on the frontend.
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

        try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
            .id = task.id,
            .name = task.name,
            .workspace_item_id = task.workspace_item_id,
            .description = task.description,
            .task_type = task.task_type,
            .created_at = task.created_at,
            .updated_at = task.updated_at,
            .is_pinned = task.is_pinned,
            .pinned_position = task.pinned_position,
            .kanban_column_id = task.kanban_column_id,
            .kanban_position = task.kanban_position,
            // Migration 070 — per-task cwd override. Borrowed
            // from the per-request arena (owned by WorkspaceItemTaskInfo
            // .deinit, stays valid until the outer useCase defer
            // runs). Empty string is the canonical "no per-task
            // cwd" sentinel. The frontend reads this via
            // useCurrentMainView's task fetch + threads it into the
            // session_create 3-level fallback chain (per-task cwd →
            // kanban path → sandbox).
            .cwd = task.cwd,
            // Auto-retry-until-stop: slice borrow from `task` (owned
            // by WorkspaceItemTaskInfo.deinit, stays valid until the
            // outer defer at the top of useCase runs). The response
            // carries this to the frontend's KanbanTaskDetailDialog
            // toggle so it shows the live state on dialog open.
            .is_auto_retry_until_stop = task.is_auto_retry_until_stop,
            // Kanban notification icon (Migration 065 / plan
            // docs/plans/2026-07-26-kanban-task-notification-icon.md):
            // last_finish_reason comes from the LEFT JOIN on sessions,
            // COALESCE'd to '' in the SQL when no session row exists.
            // needs_human_review is the SQL CASE derived boolean.
            .last_finish_reason = task.last_finish_reason,
            .needs_human_review = task.needs_human_review,
            // Migration 067 — kanban task tags. JSON-encoded array
            // string borrowed from WorkspaceItemTaskInfo.tags (the
            // per-request arena reaps it on request teardown).
            .tags = task.tags,
            // Media-flags change — media-presence flags only. The full
            // base64 TEXT columns stay server-side for the lazy media
            // endpoint; the frontend fetches them when the flag is true.
            .is_have_image = task.is_have_image,
            .is_have_video = task.is_have_video,
            // Kanban-task-git-branch: computed on-demand per task
            // from the task's cwd (worktree or item path). The
            // borrowed slice is owned by the per-request arena (the
            // subprocess stdout is allocated into the arena) and
            // stays valid until the request ends.
            .git_branch = git_branch,
        });
    }

    // next_cursor: the encoded "<sort_value>|<id>" of the LAST task in
    // this page, when has_more is true. The DB fn will decode it.
    // Pick the sort field's value (not always created_at — that was
    // the bug in session_list.zig). null when there's no more.
    const next_cursor: ?[]const u8 = blk: {
        if (!result.has_more) break :blk null;
        if (result.tasks.len == 0) break :blk null;
        const last = result.tasks[result.tasks.len - 1];
        const sort_value: ?[]const u8 = switch (input.sort_field) {
            .created_at => last.created_at orelse null,
            .updated_at => last.updated_at orelse null,
            .name => last.name, // name is NOT NULL in the DB schema
        };
        const v = sort_value orelse break :blk null;
        // Encode as "<sort_value>|<id>". For DATETIME columns the
        // value never contains '|' (the format is "YYYY-MM-DD HH:MM:SS"),
        // so the split in the DB fn is unambiguous.
        break :blk try std.fmt.allocPrint(allocator, "{s}|{s}", .{ v, last.id });
    };
    // `next_cursor` is a freshly-allocated slice whose bytes are COPIED
    // into the JSON response by makeWorkspaceItemTaskListResponse, so
    // we can free it as soon as that call returns. Without this defer,
    // the allocPrint above leaks on every paginated request.
    defer if (next_cursor) |c| allocator.free(c);

    return try http_response.makeWorkspaceItemTaskListResponse(
        allocator,
        task_responses.items,
        result.has_more,
        next_cursor,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    var input = parseInput(req.query);
    input.item_id = item_id;

    const data = useCase(allocator, sqlite_db, io, input) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.QueryFailed => "Failed to fetch tasks",
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
fn fetchWorkspaceItemPath(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
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
/// Both attempts are best-effort — git is not always available, and
/// the path may not be a repo. Any error returns ""; we never surface
/// a 500 for git failures because the kanban card is best-effort
/// decoration.
///
/// Cross-platform: `git` is required on Linux/macOS/Windows;
/// the path argument goes through the OS's subprocess argv (no
/// manual `/` or `\\` joins).
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

// ===== Tests merged from tasks_list_test.zig (2026-09-11 flatten) =====
// Static regression checks for the paginated `tasks_list` handler.
// 
// Why this file exists
// ────────────────────
// The workspace-item task list is paginated with cursor-based "Load
// More" (see docs/plans/2026-06-10-workspace-item-task-pagination.md).
// The handler at `tasks_list.zig` parses `limit` and `cursor` query
// params and delegates to `llm_history.listWorkspaceItemTasksWithCursor`.
// The response struct at `http_response.zig` carries `has_more` and
// `next_cursor` so the frontend can decide whether to render the Load
// More button.
// 
// These contracts are enforced by static substring checks (matching
// the project's `task_update_test.zig` pattern), not by spinning up
// an in-memory DB — the project has no precedent for the latter
// (every test in `test_runner.zig` either covers a pure function or
// is a static source check). If the pagination plumbing is removed
// or routed to the old single-page path, these tests fail and the
// bug is caught at `zig build test:ai_workflow:tui` time.
// 
// Why a static check (not a behavioral DB test)?
// ───────────────────────────────────────────────
// Standing up an in-process sqlite DB + migrations + event bus to
// behavioural-test the handler would duplicate the migration setup
// and pull in `pabrikcore.getSingleton()` (which depends on a live
// `ContextIPCTui` with a server, logger, and event bus). The static
// checks below directly test the bug — they fail if and only if the
// pagination contract is removed or routed back to the old path.

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/tasks_list.zig";
const LLM_HISTORY_PATH = "src/agentic_loop/llm_history.zig";
const HTTP_RESPONSE_PATH = "src/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/migrations/migration.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler parses the `limit` query param ────────────────────

test "tasks_list handler parses the limit query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must read `query.get("limit")` (or a similar pattern
    // such as `query.get("limit") orelse "20"`) and clamp it. If this
    // is missing, the limit-parse plumbing was removed and a client
    // asking for `?limit=5` would get the full unpaginated result set.
    if (std.mem.indexOf(u8, source, "\"limit\"") == null and
        std.mem.indexOf(u8, source, "'limit'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `limit` query param !!\n" ++
                "   The pagination contract is broken: clients cannot request\n" ++
                "   a smaller page size. The frontend will always fetch the\n" ++
                "   full task list, defeating pagination.\n" ++
                "   Restore the limit parse:\n" ++
                "     const limit_str = query.get(\"limit\") orelse \"20\";\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HANDLER_PATH},
        );
        return error.LimitParamMissing;
    }
}

// ─── Contract 2: handler parses the `cursor` query param ──────────────────

test "tasks_list handler parses the cursor query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must read `query.get("cursor")` so the frontend can
    // pass the previous page's `next_cursor` to fetch the next page.
    // Without this, every call would return the first page regardless
    // of the cursor.
    if (std.mem.indexOf(u8, source, "\"cursor\"") == null and
        std.mem.indexOf(u8, source, "'cursor'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `cursor` query param !!\n" ++
                "   The pagination contract is broken: the frontend cannot\n" ++
                "   advance to the next page. Clicking 'Load more' would\n" ++
                "   re-fetch the first page.\n" ++
                "   Restore the cursor parse:\n" ++
                "     const cursor_raw = query.get(\"cursor\");\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HANDLER_PATH},
        );
        return error.CursorParamMissing;
    }
}

// ─── Contract 3: handler delegates to the cursor DB function ──────────────

test "tasks_list handler calls listWorkspaceItemTasksWithCursor" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call the new cursor-aware DB function. If the
    // call was reverted to the old `listWorkspaceItemTasks`, the
    // `limit` and `cursor` params would be silently ignored and every
    // page would return all tasks.
    if (std.mem.indexOf(u8, source, "listWorkspaceItemTasksWithCursor") == null) {
        std.debug.print(
            "\n!! {s} does not call listWorkspaceItemTasksWithCursor !!\n" ++
                "   The pagination contract is broken: the handler is using\n" ++
                "   the old single-page `listWorkspaceItemTasks` function,\n" ++
                "   which ignores limit/cursor and returns the full list.\n" ++
                "   Restore the cursor-aware call:\n" ++
                "     const result = ai_mod.workspace_item_tasks\n" ++
                "         .listWorkspaceItemTasksWithCursor(allocator, sqlite_db, item_id, limit, cursor) catch ...;\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HANDLER_PATH},
        );
        return error.CursorFunctionNotCalled;
    }
}

// ─── Contract 4: response struct has the `has_more` field ─────────────────

test "WorkspaceItemTaskListResponse has the has_more field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    // The frontend reads `data.has_more` to decide whether to render
    // the "Load more" button. If the field is missing, the button
    // either never appears (data.has_more undefined) or always appears
    // (data.has_more is some other field).
    if (std.mem.indexOf(u8, source, "has_more") == null) {
        std.debug.print(
            "\n!! {s} does not contain a `has_more` field !!\n" ++
                "   The pagination contract is broken: the frontend cannot\n" ++
                "   tell whether more pages exist, so the 'Load more' button\n" ++
                "   will never appear.\n" ++
                "   Restore the field on WorkspaceItemTaskListResponse:\n" ++
                "     pub const WorkspaceItemTaskListResponse = struct {{\n" ++
                "         tasks: ...,\n" ++
                "         count: u32,\n" ++
                "         has_more: bool = false,\n" ++
                "         next_cursor: ?[]const u8 = null,\n" ++
                "     }};\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.HasMoreFieldMissing;
    }
}

// ─── Contract 5: response struct has the `next_cursor` field ─────────────

test "WorkspaceItemTaskListResponse has the next_cursor field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    // The frontend reads `data.next_cursor` to advance the cursor when
    // the user clicks "Load more". If the field is missing, the
    // cursor cannot advance and pagination stops after the first page.
    if (std.mem.indexOf(u8, source, "next_cursor") == null) {
        std.debug.print(
            "\n!! {s} does not contain a `next_cursor` field !!\n" ++
                "   The pagination contract is broken: the frontend cannot\n" ++
                "   advance the cursor, so 'Load more' would re-fetch the\n" ++
                "   first page indefinitely.\n" ++
                "   Restore the field on WorkspaceItemTaskListResponse:\n" ++
                "     pub const WorkspaceItemTaskListResponse = struct {{\n" ++
                "         tasks: ...,\n" ++
                "         count: u32,\n" ++
                "         has_more: bool = false,\n" ++
                "         next_cursor: ?[]const u8 = null,\n" ++
                "     }};\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.NextCursorFieldMissing;
    }
}

// ─── Contract 6: cursor DB function exists in llm_history ────────────────

test "llm_history exposes listWorkspaceItemTasksWithCursor" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The new function must be defined with the expected signature.
    // If it's missing, the handler's call site won't compile and
    // pagination is impossible to wire up.
    const sig = "pub fn listWorkspaceItemTasksWithCursor(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `listWorkspaceItemTasksWithCursor` !!\n" ++
                "   The pagination contract is broken: the cursor-aware DB\n" ++
                "   function is missing, so the handler has no way to fetch\n" ++
                "   a paginated subset of tasks.\n" ++
                "   Restore the function:\n" ++
                "     pub fn listWorkspaceItemTasksWithCursor(\n" ++
                "         allocator, db, workspace_item_id, limit, cursor,\n" ++
                "     ) !struct {{ tasks: []WorkspaceItemTaskInfo, has_more: bool }} {{ ... }}\n" ++
                "   See docs/plans/2026-06-10-workspace-item-task-pagination.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.CursorFunctionMissing;
    }
}

// ─── Contract 7: llm_history exposes the TaskSortField enum ──────────────

test "llm_history exposes TaskSortField enum" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const sig = "pub const TaskSortField = enum";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `TaskSortField` enum !!\n" ++
                "   The tasks-list sort plumbing is missing the sort-field\n" ++
                "   enum that maps `sort_by=...` query strings to SQL columns.\n" ++
                "   Add the enum near SessionSortField (around line 44):\n" ++
                "     pub const TaskSortField = enum {{ created_at, updated_at, name }};\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.TaskSortFieldMissing;
    }
}

// ─── Contract 8: listWorkspaceItemTasksWithCursor is sort-aware ──────────

test "listWorkspaceItemTasksWithCursor takes sort_field and sort_direction" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The function must take sort_field and sort_direction. Use a
    // substring search for the parameter names since the exact
    // signature will vary.
    const has_sort_field = std.mem.indexOf(u8, source, "sort_field: TaskSortField") != null;
    const has_sort_direction = std.mem.indexOf(u8, source, "sort_direction: TaskSortDirection") != null;
    if (!has_sort_field or !has_sort_direction) {
        std.debug.print(
            "\n!! {s} does not thread sort_field/sort_direction into listWorkspaceItemTasksWithCursor !!\n" ++
                "   The sort plumbing was added at the handler but not threaded\n" ++
                "   into the DB function — the sort_by query param would be ignored.\n" ++
                "   Update the signature:\n" ++
                "     pub fn listWorkspaceItemTasksWithCursor(\n" ++
                "         allocator: std.mem.Allocator,\n" ++
                "         db: *sqlite.SqliteBackend,\n" ++
                "         workspace_item_id: []const u8,\n" ++
                "         limit: u32,\n" ++
                "         cursor: ?[]const u8,\n" ++
                "         sort_field: TaskSortField,\n" ++
                "         sort_direction: TaskSortDirection,\n" ++
                "     ) !struct {{ tasks: []WorkspaceItemTaskInfo, has_more: bool }} {{ ... }}\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.SortParamsMissing;
    }
}

// ─── Contract 9: handler parses the sort_by query param ───────────────────

test "tasks_list handler parses the sort_by query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"sort_by\"") == null and
        std.mem.indexOf(u8, source, "'sort_by'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `sort_by` query param !!\n" ++
                "   The sort plumbing is missing at the handler level — the\n" ++
                "   frontend cannot request a different sort order.\n" ++
                "   Restore the sort_by parse:\n" ++
                "     const sort_by_str = query.get(\"sort_by\") orelse \"updated_at\";\n" ++
                "     const sort_field = llm_history.enumFromString(llm_history.TaskSortField, sort_by_str) catch .updated_at;\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{HANDLER_PATH},
        );
        return error.SortByParamMissing;
    }
}

// ─── Contract 10: handler parses the direction query param ────────────────

test "tasks_list handler parses the direction query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"direction\"") == null and
        std.mem.indexOf(u8, source, "'direction'") == null)
    {
        std.debug.print(
            "\n!! {s} does not reference the `direction` query param !!\n" ++
                "   The sort plumbing is missing the direction toggle — the\n" ++
                "   user can never sort ascending.\n" ++
                "   Restore the direction parse:\n" ++
                "     const direction_str = query.get(\"direction\") orelse \"desc\";\n" ++
                "     const sort_direction = llm_history.enumFromString(llm_history.TaskSortDirection, direction_str) catch .desc;\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{HANDLER_PATH},
        );
        return error.DirectionParamMissing;
    }
}

// ─── Contract 11: handler passes sort_field and sort_direction to the DB fn

test "tasks_list handler passes sort_field and sort_direction to the DB fn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler's call to listWorkspaceItemTasksWithCursor must
    // include sort_field and sort_direction args. We look for the
    // substring "sort_field," and "sort_direction" in the handler.
    if (std.mem.indexOf(u8, source, "sort_field,") == null or
        std.mem.indexOf(u8, source, "sort_direction") == null)
    {
        std.debug.print(
            "\n!! {s} does not pass sort_field/sort_direction to the DB fn !!\n" ++
                "   The handler parses the sort params but doesn't forward\n" ++
                "   them — the SQL still hardcodes the original ORDER BY.\n" ++
                "   Update the call site:\n" ++
                "     .listWorkspaceItemTasksWithCursor(allocator, sqlite_db, item_id, limit, cursor, sort_field, sort_direction) catch ...;\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{HANDLER_PATH},
        );
        return error.SortParamsNotForwarded;
    }
}

// ─── Contracts 13-14: routine field deleted (Migration 084) ─────────────
// Per-task routines are gone — routines are first-class workspace
// items now (plan 2026-09-10-workspace-items-routines). These are
// deletion proofs: they fail if anyone resurrects the inline
// `routine` field on the task response.

test "WorkspaceItemTaskResponse has task_type and no routine field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task_type") == null) return error.TaskTypeFieldMissing;
    // Scope to the WorkspaceItemTaskResponse struct window — the
    // deletion NOTE comments elsewhere in the file mention "routines"
    // (plural) and must not satisfy this check.
    const struct_start = std.mem.indexOf(u8, source, "pub const WorkspaceItemTaskResponse = struct") orelse {
        return error.ResponseStructMissing;
    };
    const window = source[struct_start..];
    const window_end = std.mem.indexOf(u8, window, "\npub const ") orelse window.len;
    const struct_body = window[0..window_end];
    if (std.mem.indexOf(u8, struct_body, "routine") != null) return error.RoutineFieldResurrected;
}

test "tasks_list handler threads task_type and no routine into the response" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    const impl_end = std.mem.indexOf(u8, source, "// ===== Tests merged from") orelse source.len;
    const impl_source = source[0..impl_end];
    if (std.mem.indexOf(u8, impl_source, "task_type") == null) return error.TaskTypeNotThreaded;
    if (std.mem.indexOf(u8, impl_source, ".routine") != null) return error.RoutineResurrected;
}

// ─── Contract: pin fields propagate from DB to wire response ──────────
//
// Regression: the `WorkspaceItemTaskResponse` shape originally lacked
// `is_pinned` + `pinned_position`, so the frontend could never render
// the pin icon even after `pinTask` updated the DB. Both fields must
// be present on the wire type AND threaded into the handler's
// response struct.

test "WorkspaceItemTaskResponse has is_pinned + pinned_position fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "is_pinned") == null) return error.IsPinnedFieldMissing;
    if (std.mem.indexOf(u8, source, "pinned_position") == null) return error.PinnedPositionFieldMissing;
}

test "tasks_list handler threads is_pinned + pinned_position into the response" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".is_pinned") == null) return error.IsPinnedNotThreaded;
    if (std.mem.indexOf(u8, source, ".pinned_position") == null) return error.PinnedPositionNotThreaded;
}

// ─── Contract 12: migration declares idx_workspace_item_tasks_item_updated ─

test "migration declares idx_workspace_item_tasks_item_updated" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    const idx = "idx_workspace_item_tasks_item_updated";
    if (std.mem.indexOf(u8, source, idx) == null) {
        std.debug.print(
            "\n!! {s} does not declare `{s}` index !!\n" ++
                "   The sort_by=updated_at hot path is unindexed — every page\n" ++
                "   fetch will full-scan workspace_item_tasks. As task counts\n" ++
                "   grow this becomes O(n) per page.\n" ++
                "   Add a migration that creates the index:\n" ++
                "     try db.exec(allocator, \"CREATE INDEX IF NOT EXISTS\n" ++
                "       {s} ON workspace_item_tasks(workspace_item_id, updated_at DESC)\", ...);\n" ++
                "   See docs/superpowers/plans/2026-06-11-workspace-item-tasks-sort-by-updated-at.md.\n",
            .{ MIGRATION_PATH, idx, idx },
        );
        return error.UpdatedAtIndexMissing;
    }
}

// ─── Contract 15: list SELECT includes is_pinned and pinned_position ────
//
// Added for the pinned-tasks feature. The list must surface both
// columns so the frontend can render pinned rows first and apply the
// pin indicator on `WorkspaceItemTask.vue`.

test "tasks_list llm_history SELECT includes is_pinned and pinned_position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "t.is_pinned") == null) {
        std.debug.print(
            "\n!! {s} does not include `t.is_pinned` in any SELECT !!\n" ++
                "   The pinned-tasks feature won't work — the frontend won't\n" ++
                "   know which rows are pinned.\n" ++
                "   See docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.IsPinnedColumnNotInSelect;
    }
    if (std.mem.indexOf(u8, source, "t.pinned_position") == null) {
        std.debug.print(
            "\n!! {s} does not include `t.pinned_position` in any SELECT !!\n" ++
                "   The frontend won't know the pinned-row order.\n" ++
                "   See docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.PinnedPositionColumnNotInSelect;
    }
}

test "tasks_list llm_history ORDER BY puts pinned rows first" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The list ORDER BY must start with is_pinned DESC so pinned
    // rows surface at the top of the per-item task list. Look for
    // the substring "is_pinned DESC" (not "ORDER BY is_pinned DESC"
    // — same rationale as the position-DESC test above).
    if (std.mem.indexOf(u8, source, "is_pinned DESC") == null) {
        std.debug.print(
            "\n!! {s} does not ORDER BY is_pinned DESC !!\n" ++
                "   Pinned tasks will not surface first in the task list.\n" ++
                "   Add: ORDER BY t.is_pinned DESC, t.pinned_position DESC, ...\n" ++
                "   See docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.OrderByIsPinnedMissing;
    }
}

// ─── Contract 16: image_urls read path (Migration 069) ────────────────────
//
// Plan: docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
// The persist path INSERTs `workspace_item_tasks.image_urls` (the
// ||-delimited base64 data URL string) but the paginated lister never
// SELECTed it — so the frontend's task detail dialog gallery and the
// kanban card thumbnails always saw an empty array. Three contracts
// lock the full read path: SELECT column → struct field → wire field.

test "tasks_list llm_history SELECT includes t.image_urls" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Scope the check to the cursor lister's function body (the only
    // live read path — tasks_list.zig:137 calls it). The legacy
    // non-cursor `listWorkspaceItemTasks` has no production callers
    // and is intentionally left untouched.
    const fn_start = std.mem.indexOf(u8, source, "pub fn listWorkspaceItemTasksWithCursor(") orelse {
        std.debug.print(
            "\n!! {s} does not define listWorkspaceItemTasksWithCursor !!\n",
            .{LLM_HISTORY_PATH},
        );
        return error.CursorListerMissing;
    };
    const body = source[fn_start..];
    const body_end = std.mem.indexOf(u8, body, "\npub fn ") orelse body.len;
    const fn_body = body[0..body_end];

    if (std.mem.indexOf(u8, fn_body, "CASE WHEN COALESCE(t.image_urls, '') != '' THEN 1 ELSE 0 END") == null) {
        std.debug.print(
            "\n!! {s} listWorkspaceItemTasksWithCursor SELECT does not derive the image flag !!\n" ++
                "   List/get return only derived media-presence flags;\n" ++
                "   the full base64 TEXT stays server-side for the lazy media endpoint.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.ImageUrlsColumnNotInSelect;
    }
}

test "tasks_list llm_history struct literal sets is_have_image from row" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const fn_start = std.mem.indexOf(u8, source, "pub fn listWorkspaceItemTasksWithCursor(") orelse {
        std.debug.print(
            "\n!! {s} does not define listWorkspaceItemTasksWithCursor !!\n",
            .{LLM_HISTORY_PATH},
        );
        return error.CursorListerMissing;
    };
    const body = source[fn_start..];
    const body_end = std.mem.indexOf(u8, body, "\npub fn ") orelse body.len;
    const fn_body = body[0..body_end];

    // The struct literal must populate .image_urls from the new SELECT
    // column (index 17 post-Migration-084 — the routines JOIN dropped
    // columns 11-17, shifting everything down by 7). Without this the
    // field stays the default empty slice even when the DB row has images.
    if (std.mem.indexOf(u8, fn_body, ".is_have_image") == null) {
        std.debug.print(
            "\n!! {s} listWorkspaceItemTasksWithCursor does not set .is_have_image !!\n" ++
                "   Add to the WorkspaceItemTaskInfo literal:\n" ++
                "     .is_have_image = std.mem.eql(u8, row.values[17], \"1\"),\n",
            .{LLM_HISTORY_PATH},
        );
        return error.ImageUrlsFieldNotPopulated;
    }
}

test "tasks_list response forwards is_have_image" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".is_have_image = task.is_have_image") == null) {
        std.debug.print(
            "\n!! {s} does not forward .is_have_image into the response !!\n" ++
                "   Add next to the .tags forwarding:\n" ++
                "     .is_have_image = task.is_have_image,\n",
            .{HANDLER_PATH},
        );
        return error.ImageUrlsNotForwarded;
    }
}

test "WorkspaceItemTaskResponse declares is_have_image" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    // Scope to the WorkspaceItemTaskResponse struct window.
    const struct_start = std.mem.indexOf(u8, source, "pub const WorkspaceItemTaskResponse = struct") orelse {
        std.debug.print(
            "\n!! {s} does not define WorkspaceItemTaskResponse !!\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.ResponseStructMissing;
    };
    const window = source[struct_start..];
    const window_end = std.mem.indexOf(u8, window, "\npub const ") orelse window.len;
    const struct_body = window[0..window_end];

    if (std.mem.indexOf(u8, struct_body, "is_have_image: bool") == null) {
        std.debug.print(
            "\n!! {s} WorkspaceItemTaskResponse does not declare is_have_image !!\n" ++
                "   Add: is_have_image: bool = false,\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.ImageUrlsFieldMissing;
    }
}
