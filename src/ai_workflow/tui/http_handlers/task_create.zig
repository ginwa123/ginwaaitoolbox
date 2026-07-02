//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks`.
//!
//! Body: `{ name, session_id?, task_type? ('standard'|'routine'|'memory'),
//!         schedule?, initial_prompt?, enabled?,
//!         memory_name?, memory_content? }`.
//!
//! Three task types are supported:
//!
//!   - **standard** (default): existing `createWorkspaceItemTask` path;
//!     the migration's `task_type` column default is 'standard'.
//!     If the parent item is a kanban, the new task is auto-assigned
//!     to the first column at MAX(kanban_position) + 1.
//!
//!   - **routine**: inlines both the workspace_item_tasks INSERT (so we
//!     can set task_type='routine' explicitly) and the routines INSERT.
//!     The scheduler polls `routines` so the routines row is what
//!     makes the task fire.
//!
//!   - **memory**: a local memory file scoped to the parent
//!     workspace_item's directory. The .md file is created at
//!     `<workspace_item.path>/.nalar/memories/<memory_name>` (the
//!     directory is created if missing) so `loadLocalKnowledge` picks
//!     it up on the next chat. The task row has `task_type='memory'`
//!     and no `session_id` — the file is the content. Requires
//!     `memory_name` (must pass `isValidMemoryName`) and `memory_content`
//!     in the body.
//!
//! Layered as `useCase` (validate + generate id + branch by
//! `task_type` + DB/file work + return tagged result with kanban
//! fields) and a thin handler that maps the outcome + errors to
//! status codes / JSON.
//!
//! Plans:
//!   - docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md (routine)
//!   - docs/plans/2026-06-20-add-markdown-memory.md (memory)

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const memories_mod = nalarcore.memories;
const cron = @import("../routines/cron.zig");
const fire = @import("../routines/fire.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code in the handler (see the handler's
/// `switch (err)` below).
pub const TaskCreateError = error{
    // 400 — path params / body validation
    ItemIdRequired,
    MissingBody,
    InvalidJson,
    // 400 — routine-task validation
    RoutineScheduleRequired,
    RoutineInitialPromptRequired,
    InvalidCronExpression,
    FailedToComputeNextFireTime,
    // 500 — routine-task DB ops
    TaskInsertFailed,
    RoutineCreateFailed,
    // 400 — memory-task validation
    MemoryNameRequired,
    InvalidMemoryName,
    MemoryContentRequired,
    // 400 / 404 — memory-task workspace_item checks
    WorkspaceItemNotFound,
    NotAFolderItem,
    NoPathForMemory,
    // 500 — memory-task file/DB ops
    FailedToBuildMemoriesPath,
    FailedToWriteMemoryFile,
    MemoryTaskInsertFailed,
    // 500 — standard-task DB ops
    StandardTaskCreateFailed,
    // Underlying I/O / alloc errors (required by the type system
    // even though they're unreachable on the per-request arena)
    OutOfMemory,
    Canceled,
};

pub const TaskCreateInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    io: std.Io,
    body: http_response.TaskCreateRequest,
};

/// Tagged outcome of the use-case. The fields are the data needed
/// to build the response for each task type.
pub const TaskCreateResult = union(enum) {
    routine: RoutineResult,
    memory: MemoryResult,
    standard: StandardResult,
};

pub const RoutineResult = struct {
    task_id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
};

pub const MemoryResult = struct {
    task_id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
};

pub const StandardResult = struct {
    task_id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    kanban_column_id: ?[]const u8,
    kanban_position: i64,
    /// Caller-supplied session_id (if any). When null the JSON response
    /// emits "session_id":null. The standard-task path no longer accepts
    /// a caller-supplied session_id per the task.id == session.id
    /// convention; the field is preserved for backward compatibility.
    session_id: ?[]const u8,
};

// Typed response structs. Serialized via std.json.Stringify.valueAlloc
// (NOT hand-rolled JSON via the std.fmt formatting helpers) for two
// reasons:
//
// 1. Aliasing safety: chaining two per-arena fmt.allocPrint calls
//    (one as a format arg of the other) lets Writer.Allocating land
//    the inner result in the same chunk the outer ensureTotalCapacity
//    just reallocated from, and Zig 0.16's @memcpy safety check aborts
//    with "@memcpy arguments alias" (user-reported crash on 2026-07-01).
//
// 2. JSON escaping: hand-rolled JSON via the fmt helpers does NOT
//    escape quotes / backslashes / control chars in user-provided
//    fields like r.name. A task name containing a quote would produce
//    malformed JSON and break the frontend. valueAlloc delegates to
//    std.json.Stringify which handles all escaping per RFC 8259.

const RoutineResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8 = "routine",
    session_id: []const u8,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

const MemoryResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8 = "memory",
    session_id: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

const StandardResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8 = "standard",
    session_id: ?[]const u8,
    kanban_column_id: ?[]const u8 = null,
    kanban_position: i64 = 0,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

// =====================================================================
// Use case
// =====================================================================

/// Generate a unique `task_<unix_milliseconds>` id.
fn generateTaskId(allocator: std.mem.Allocator, io: std.Io) TaskCreateError![]u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    return std.fmt.allocPrint(allocator, "task_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)}) catch return error.OutOfMemory;
}

/// Routine branch. Inserts task row + routines row.
fn createRoutineTask(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
    task_id: []const u8,
) TaskCreateError!RoutineResult {
    const schedule = input.body.schedule orelse return error.RoutineScheduleRequired;
    const initial_prompt = input.body.initial_prompt orelse return error.RoutineInitialPromptRequired;
    cron.validate(schedule) catch return error.InvalidCronExpression;
    const ts = std.Io.Timestamp.now(input.io, .real);
    const next_ns = cron.nextFireTime(schedule, ts.nanoseconds) catch return error.FailedToComputeNextFireTime;
    const next_run_at = fire.formatSqliteDatetime(allocator, next_ns) catch return error.OutOfMemory;
    defer allocator.free(next_run_at);

    // Routine task — task.id == session_id, so we never need to
    // store a separate session_id column. The session_id field in
    // the request body is accepted for backward compatibility but
    // is intentionally ignored.
    db.exec(allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES (?, ?, ?, 'routine')",
        &[_][]const u8{ task_id, input.body.name, input.item_id },
    ) catch return error.TaskInsertFailed;

    const routine_id = std.fmt.allocPrint(allocator, "routine_{s}", .{task_id}) catch return error.OutOfMemory;
    defer allocator.free(routine_id);
    const enabled_str = if (input.body.enabled) "1" else "0";
    db.exec(allocator,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, enabled, next_run_at) VALUES (?, ?, ?, ?, ?, ?)",
        &[_][]const u8{ routine_id, task_id, schedule, initial_prompt, enabled_str, next_run_at },
    ) catch return error.RoutineCreateFailed;

    return .{ .task_id = task_id, .name = input.body.name, .workspace_item_id = input.item_id };
}

/// Memory branch. Writes the .md file + inserts the task row.
fn createMemoryTask(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
    task_id: []const u8,
) TaskCreateError!MemoryResult {
    const memory_name = input.body.memory_name orelse return error.MemoryNameRequired;
    if (!memories_mod.isValidMemoryName(memory_name)) return error.InvalidMemoryName;
    const memory_content = input.body.memory_content orelse return error.MemoryContentRequired;

    // Look up the parent workspace_item to get its `path` (the project
    // root — the .md file is scoped to `<path>/.nalar/memories/<name>.md`).
    const item_opt = ai_mod.workspace_item_tasks.getWorkspaceItem(allocator, db, input.item_id) catch return error.WorkspaceItemNotFound;
    const item = item_opt orelse return error.WorkspaceItemNotFound;
    defer item.deinit(allocator);

    // Refuse non-folder items — `loadLocalKnowledge` reads from
    // `<cwd>/.nalar/memories/`, so the cwd must be a real directory
    // (which is what a 'folder' item's path is).
    if (!std.mem.eql(u8, item.item_type, "folder")) return error.NotAFolderItem;
    const cwd = item.path orelse return error.NoPathForMemory;

    const dir_path = memories_mod.get_local_memories_path_for_dir(allocator, cwd) orelse return error.FailedToBuildMemoriesPath;
    defer allocator.free(dir_path);

    if (!memories_mod.writeLocalMemoryFile(allocator, input.io, dir_path, memory_name, memory_content)) {
        return error.FailedToWriteMemoryFile;
    }

    db.exec(allocator,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES (?, ?, ?, 'memory')",
        &[_][]const u8{ task_id, input.body.name, input.item_id },
    ) catch {
        // Roll back the file on task-row failure so we don't leave
        // an orphan .md with no task pointing at it. The helper is
        // idempotent (returns true on already-missing), so this is
        // safe even if the file disappeared in the meantime.
        _ = memories_mod.deleteLocalMemoryFile(allocator, input.io, dir_path, memory_name);
        return error.MemoryTaskInsertFailed;
    };

    return .{ .task_id = task_id, .name = input.body.name, .workspace_item_id = input.item_id };
}

/// Standard branch. Creates the task row and, if the parent is a
/// kanban, auto-assigns it to the first column at
/// MAX(kanban_position) + 1.
fn createStandardTask(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
    task_id: []const u8,
) TaskCreateError!StandardResult {
    const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(
        allocator,
        db,
        task_id,
        input.body.name,
        input.item_id,
        "standard",
    ) catch return error.StandardTaskCreateFailed;
    // NOTE: do NOT `defer task.deinit(allocator)` here. The slices
    // task.id, task.name, task.workspace_item_id, and task.task_type
    // are duped by createWorkspaceItemTask on the per-request arena
    // and then BORROWED into the returned StandardResult below. The
    // handler reads them after this function returns, so freeing
    // here would be a use-after-free (Zig arena free-fill = 0xAA bytes
    // end up as field values). The arena reaps everything when
    // GinwaServer.handle tears down the request arena, so the duped
    // slices need no explicit cleanup.

    // Kanban auto-assign: if the parent is a kanban, append the new
    // task to the bottom of the first column. Errors here are
    // non-fatal — the task row is already created.
    var kanban_column_id: ?[]u8 = null;
    var kanban_position: i64 = 0;
    // NOTE: do NOT `defer allocator.free(kanban_column_id)` here.
    // kanban_column_id (when set) is a dupe on the per-request arena
    // that is BORROWED into the returned StandardResult. Same use-
    // after-free reasoning as above.

    {
        const parent_is_kanban = blk: {
            var q = db.query(allocator,
                "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'",
                &[_][]const u8{input.item_id}) catch break :blk false;
            defer q.deinit();
            const row = (q.next() catch break :blk false) orelse break :blk false;
            defer row.deinit(allocator);
            break :blk true;
        };

        if (parent_is_kanban) {
            const first_col_id = blk: {
                var q = db.query(allocator,
                    "SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
                    &[_][]const u8{input.item_id}) catch break :blk null;
                defer q.deinit();
                const row = (q.next() catch break :blk null) orelse break :blk null;
                defer row.deinit(allocator);
                break :blk allocator.dupe(u8, row.values[0]) catch break :blk null;
            };
            if (first_col_id) |col_id| {
                defer allocator.free(col_id);
                db.exec(allocator,
                    "UPDATE workspace_item_tasks SET kanban_column_id = ?, kanban_position = (SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM workspace_item_tasks WHERE kanban_column_id = ?) WHERE id = ?",
                    &[_][]const u8{ col_id, col_id, task_id },
                ) catch |err| {
                    std.log.warn("task_create: kanban auto-assign failed (non-fatal): {s}", .{@errorName(err)});
                };
                // Emit SSE event so other connected clients refresh
                // their kanban view. action="assigned" matches the
                // frontend's KanbanTaskEvent union variant.
                const assigned_pos: i64 = blk: {
                    var q = db.query(allocator,
                        "SELECT COALESCE(kanban_position, 0) FROM workspace_item_tasks WHERE id = ?",
                        &[_][]const u8{task_id}) catch break :blk 0;
                    defer q.deinit();
                    const row = (q.next() catch break :blk 0) orelse break :blk 0;
                    defer row.deinit(allocator);
                    break :blk std.fmt.parseInt(i64, row.values[0], 10) catch 0;
                };
                on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
                    .action = "assigned",
                    .workspace_id = input.workspace_id,
                    .item_id = input.item_id,
                    .task_id = task_id,
                    .new_column_id = col_id,
                    .new_position = assigned_pos,
                }) catch |err| {
                    std.log.warn("task_create: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
                };
                // Re-read kanban fields after the UPDATE so the
                // response carries the assigned values.
                var q2 = db.query(allocator,
                    "SELECT kanban_column_id, COALESCE(kanban_position, 0) FROM workspace_item_tasks WHERE id = ?",
                    &[_][]const u8{task_id}) catch return .{
                    .task_id = task_id,
                    .name = task.name,
                    .workspace_item_id = task.workspace_item_id,
                    .kanban_column_id = null,
                    .kanban_position = 0,
                    .session_id = input.body.session_id,
                };
                defer q2.deinit();
                blk: {
                    const row_opt = q2.next() catch break :blk {};
                    if (row_opt) |row| {
                        defer row.deinit(allocator);
                        if (row.values[0].len > 0) {
                            kanban_column_id = allocator.dupe(u8, row.values[0]) catch null;
                        }
                        kanban_position = std.fmt.parseInt(i64, row.values[1], 10) catch 0;
                    }
                }
            }
        }
    }

    // session_id is preserved for backward compatibility with the v1
    // wire format. The standard-task path no longer accepts a caller-
    // supplied session_id (the task's own id is the session per the
    // task.id == session.id convention), so input.body.session_id is
    // typically null. Pass it through as-is — valueAlloc handles the
    // optional → "session_id":<id-or-null> serialization.
    return .{
        .task_id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .kanban_column_id = kanban_column_id,
        .kanban_position = kanban_position,
        .session_id = input.body.session_id,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
) TaskCreateError!TaskCreateResult {
    if (input.item_id.len == 0) return error.ItemIdRequired;

    const task_id = try generateTaskId(allocator, input.io);
    // NOTE: do NOT `defer allocator.free(task_id)` here. `task_id` is
    // passed to `createRoutineTask` / `createMemoryTask` /
    // `createStandardTask`, which return it as `*.task_id` in their
    // `*Result` structs. The handler then reads it after this
    // function returns — freeing here is a use-after-free. The
    // per-request arena reaps `task_id` on request teardown, so no
    // explicit cleanup is needed.

    if (std.mem.eql(u8, input.body.task_type, "routine")) {
        const result = try createRoutineTask(allocator, db, input, task_id);
        return .{ .routine = result };
    }
    if (std.mem.eql(u8, input.body.task_type, "memory")) {
        const result = try createMemoryTask(allocator, db, input, task_id);
        return .{ .memory = result };
    }
    const result = try createStandardTask(allocator, db, input, task_id);
    return .{ .standard = result };
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksCreateHandler(
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
    // workspace_id is required for the SSE payload (the frontend
    // filters events for the active workspace). Empty is fine.
    const ws_id = req.params.get("workspace_id") orelse "";

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, allocator, body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const outcome = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .io = ctx.io,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired, error.MissingBody, error.InvalidJson => 400,
            error.RoutineScheduleRequired, error.RoutineInitialPromptRequired,
            error.InvalidCronExpression, error.FailedToComputeNextFireTime => 400,
            error.MemoryNameRequired, error.InvalidMemoryName,
            error.MemoryContentRequired => 400,
            error.WorkspaceItemNotFound => 404,
            error.NotAFolderItem, error.NoPathForMemory => 400,
            error.TaskInsertFailed, error.RoutineCreateFailed,
            error.MemoryTaskInsertFailed, error.StandardTaskCreateFailed,
            error.FailedToBuildMemoriesPath, error.FailedToWriteMemoryFile => 500,
            error.OutOfMemory, error.Canceled => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON",
            error.RoutineScheduleRequired => "schedule is required for routine tasks",
            error.RoutineInitialPromptRequired => "initial_prompt is required for routine tasks",
            error.InvalidCronExpression => "Invalid cron expression",
            error.FailedToComputeNextFireTime => "Failed to compute next fire time",
            error.MemoryNameRequired => "memory_name is required for memory tasks",
            error.InvalidMemoryName => "Invalid memory name (must end in .md, no /, no ..)",
            error.MemoryContentRequired => "memory_content is required for memory tasks",
            error.WorkspaceItemNotFound => "Workspace item not found",
            error.NotAFolderItem => "Memory tasks can only be added to folder-type workspace items",
            error.NoPathForMemory => "Workspace item has no path; the folder must have been created with a real path",
            error.TaskInsertFailed => "Failed to create task",
            error.RoutineCreateFailed => "Failed to create routine row",
            error.MemoryTaskInsertFailed => "Failed to create task row",
            error.StandardTaskCreateFailed => "Failed to create task",
            error.FailedToBuildMemoriesPath => "Failed to build local memories path",
            error.FailedToWriteMemoryFile => "Failed to write memory file",
            error.OutOfMemory => "Out of memory",
            error.Canceled => "Io operation canceled",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Serialize the response based on the tagged outcome. Each branch
    // uses a typed struct + std.json.Stringify.valueAlloc (not hand-
    // rolled std.fmt.allocPrint) — see the doc comment above the
    // response struct definitions for the rationale.
    return switch (outcome) {
        .routine => |r| res.jsonResponse(.{
            .status_code = 201,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                RoutineResponse{
                    .id = r.task_id,
                    .name = r.name,
                    .workspace_item_id = r.workspace_item_id,
                    .session_id = r.task_id, // task.id == session.id
                },
                .{},
            ),
        }),
        .memory => |r| res.jsonResponse(.{
            .status_code = 201,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                MemoryResponse{
                    .id = r.task_id,
                    .name = r.name,
                    .workspace_item_id = r.workspace_item_id,
                },
                .{},
            ),
        }),
        .standard => |r| res.jsonResponse(.{
            .status_code = 201,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                StandardResponse{
                    .id = r.task_id,
                    .name = r.name,
                    .workspace_item_id = r.workspace_item_id,
                    .session_id = r.session_id,
                    .kanban_column_id = r.kanban_column_id,
                    .kanban_position = r.kanban_position,
                },
                .{},
            ),
        }),
    };
}