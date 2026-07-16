//! `GET /api/workspaces/:workspace_id/items/:item_id/tasks`.
//!
//! Optional query params:
//!   - `limit`: u32, defaults to 20, max 100
//!   - `cursor`: string in the form `<sort_field_value>|<id>` from the
//!     previous page's `next_cursor`; pass undefined for the first page
//!   - `sort_by`: `"created_at" | "updated_at" | "name"`, default `"updated_at"`
//!   - `direction`: `"asc" | "desc"`, default `"desc"`
//!
//! Response: `{ tasks: [...], count, has_more, next_cursor }`.
//!
//! Layered as `useCase` (resolve singleton + parse query + DB
//! query + build response) and a thin handler that maps errors
//! to status codes / JSON.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
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

    return .{
        .item_id = "", // set by the handler (path param)
        .limit = limit,
        .cursor = cursor,
        .sort_field = sort_field,
        .sort_direction = sort_direction,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
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
    ) catch return error.QueryFailed;
    defer {
        for (result.tasks) |task| task.deinit(allocator);
        allocator.free(result.tasks);
    }

    // Convert to response format.
    var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
    defer task_responses.deinit(allocator);

    for (result.tasks) |task| {
        // Convert the DB-layer RoutineMeta (with a `routines_model.RoutineRunStatus`
        // enum for `last_status`) into the response-layer RoutineMetaResponse
        // (with a `?[]const u8` string for `last_status`). The slice fields
        // borrow from `task.routine`; the bytes are owned by
        // `WorkspaceItemTaskInfo.deinit` and stay valid for the duration of
        // `makeWorkspaceItemTaskListResponse` (which deep-copies them into
        // the response JSON), so the outer defer's `task.deinit` is safe.
        const routine_meta: ?http_response.RoutineMetaResponse = if (task.routine) |r| .{
            .schedule = r.schedule,
            .initial_prompt = r.initial_prompt,
            .enabled = r.enabled,
            .last_run_at = r.last_run_at,
            .next_run_at = r.next_run_at,
            // .dbValue() returns null for .idle, "success"/"failed"/"running"
            // for the rest — matches the response field's `?[]const u8`.
            .last_status = r.last_status.dbValue(),
            .last_error = r.last_error,
        } else null;

        try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
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

    const di = try nalarcore.getSingleton();
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

    const data = useCase(allocator, sqlite_db, input) catch |err| {
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