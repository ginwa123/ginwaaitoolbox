//! `PATCH /api/agent-routines/:routine_id/system_prompt/:prompt_id`.
//!
//! Updates title and/or content of an existing system-prompt entry.
//! Body: `{title?, content?}` (both optional; at least one required).
//!
//! Mirrors `agent_system_prompt_update.zig` with substitutions:
//! table `agent_routine_system_prompt`, parent col `routine_id`.
//!
//! Memory: the per-request arena reaps all allocations at request end,
//! so neither layer needs explicit `free`s.
//!
//! Plan: Routine mode task_1789505553300_1 (option A, mirror agent_routine_*)
//! Task: task_1789505553300_1

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// HTTP request body.
const UpdateSystemPromptBody = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Subset of the system-prompt row returned by the use-case.
pub const SystemPrompt = struct {
    id: []const u8,
    routine_id: []const u8,
    title: []const u8,
    content: []const u8,
    position: i64,
};

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const SystemPromptUpdateError = error{
    /// `routine_id` or `prompt_id` path param was missing or empty.
    IdsRequired,
    /// Body had neither `title` nor `content` (nothing to update).
    NothingToUpdate,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed.
    RefetchFailed,
    /// Refetched row vanished (surfaces as 404).
    RowNotFound,
    /// `allocator.alloc` failed while building the dynamic SQL.
    OutOfMemory,
};

/// Inputs to the system-prompt-update use-case.
pub const SystemPromptUpdateInput = struct {
    routine_id: []const u8,
    prompt_id: []const u8,
    title: ?[]const u8,
    content: ?[]const u8,
};

/// Output of the system-prompt-update use-case.
pub const SystemPromptUpdateOutput = struct {
    system_prompt: SystemPrompt,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing system-prompt row. Validates that at least one of
/// `title` / `content` is provided, then UPDATE-with-dynamic-SQL the
/// requested fields and SELECT-refetch the row. Transport-agnostic.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: SystemPromptUpdateInput,
) SystemPromptUpdateError!SystemPromptUpdateOutput {
    if (input.routine_id.len == 0 or input.prompt_id.len == 0) {
        return error.IdsRequired;
    }
    if (input.title == null and input.content == null) {
        return error.NothingToUpdate;
    }

    // Build dynamic UPDATE SQL. COALESCE(?, '') so empty-slice binds
    // land as '' not NULL (NOT NULL columns).
    var sql_list: std.ArrayList(u8) = .empty;
    defer sql_list.deinit(allocator);
    try sql_list.appendSlice(allocator, "UPDATE agent_routine_system_prompt SET updated_at = datetime('now')");
    if (input.title != null) try sql_list.appendSlice(allocator, ", title = COALESCE(?, '')");
    if (input.content != null) try sql_list.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql_list.appendSlice(allocator, " WHERE id = ? AND routine_id = ?");

    // Bind args. Max 4 slots: title, content, prompt_id, routine_id.
    var args_buf: [4][]const u8 = undefined;
    var arg_idx: usize = 0;
    if (input.title) |t| {
        args_buf[arg_idx] = t;
        arg_idx += 1;
    }
    if (input.content) |c| {
        args_buf[arg_idx] = c;
        arg_idx += 1;
    }
    args_buf[arg_idx] = input.prompt_id;
    arg_idx += 1;
    args_buf[arg_idx] = input.routine_id;
    arg_idx += 1;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    for (args_buf[0..arg_idx]) |a| try argv_list.append(allocator, a);

    db.exec(allocator, sql_list.items, argv_list.items) catch return error.UpdateFailed;

    // Read back.
    var q = db.query(allocator,
        "SELECT id, routine_id, title, content, position FROM agent_routine_system_prompt WHERE id = ?",
        &[_][]const u8{input.prompt_id},
    ) catch return error.RefetchFailed;
    defer q.deinit();
    const r = (q.next() catch null) orelse return error.RowNotFound;
    defer r.deinit(allocator); // safe — we dupe the slices below
    const position = std.fmt.parseInt(i64, r.values[4], 10) catch 0;

    const id = try allocator.dupe(u8, r.values[0]);
    errdefer allocator.free(id);
    const routine_id = try allocator.dupe(u8, r.values[1]);
    errdefer allocator.free(routine_id);
    const title = try allocator.dupe(u8, r.values[2]);
    errdefer allocator.free(title);
    const content = try allocator.dupe(u8, r.values[3]);
    errdefer allocator.free(content);

    return .{
        .system_prompt = .{
            .id = id,
            .routine_id = routine_id,
            .title = title,
            .content = content,
            .position = position,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentRoutineSystemPromptUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const routine_id = req.params.get("routine_id") orelse "";
    const prompt_id = req.params.get("prompt_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(UpdateSystemPromptBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .routine_id = routine_id,
        .prompt_id = prompt_id,
        .title = parsed.title,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NothingToUpdate => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowNotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "routine_id and prompt_id required",
            error.NothingToUpdate => "title or content required",
            error.UpdateFailed => "Failed to update system prompt",
            error.RefetchFailed => "Failed to read row",
            error.RowNotFound => "system prompt row not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.system_prompt, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention). Behavioural coverage:
//
//   1. Validation: empty ids OR nothing-to-update → respective errors
//   2. Happy path: updates title AND content
//   3. title-only update keeps content

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration087CreateAgentRoutines = @import("../migrations/migration.zig").Migration087CreateAgentRoutines;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration087CreateAgentRoutines.up(&db, testing.allocator);

    // Seed: configured routine + 1 prompt row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'routine', 'My Routine')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_routines (id, workspace_item_id) VALUES ('ws_item_1', 'ws_item_1')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_routine_system_prompt (id, routine_id, title, content, position) VALUES ('sp_1', 'ws_item_1', 'Original', 'orig body', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty routine_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "", .prompt_id = "sp_1", .title = "T", .content = null }),
    );
}

test "useCase: nothing to update returns NothingToUpdate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NothingToUpdate,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .prompt_id = "sp_1", .title = null, .content = null }),
    );
}

test "useCase: happy path updates both title AND content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .routine_id = "ws_item_1",
        .prompt_id = "sp_1",
        .title = "New Title",
        .content = "new body",
    });
    defer {
        alloc.free(output.system_prompt.id);
        alloc.free(output.system_prompt.routine_id);
        alloc.free(output.system_prompt.title);
        alloc.free(output.system_prompt.content);
    }
    try testing.expectEqualStrings("sp_1", output.system_prompt.id);
    try testing.expectEqualStrings("New Title", output.system_prompt.title);
    try testing.expectEqualStrings("new body", output.system_prompt.content);
}

test "useCase: title-only update keeps content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .routine_id = "ws_item_1",
        .prompt_id = "sp_1",
        .title = "Only Title Changed",
        .content = null,
    });
    defer {
        alloc.free(output.system_prompt.id);
        alloc.free(output.system_prompt.routine_id);
        alloc.free(output.system_prompt.title);
        alloc.free(output.system_prompt.content);
    }
    try testing.expectEqualStrings("Only Title Changed", output.system_prompt.title);
    try testing.expectEqualStrings("orig body", output.system_prompt.content);
}
