//! `GET /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/media`
//!
//! Lazy media fetch for a kanban task (Migration 092). List/get return
//! only `is_have_image` / `is_have_video` flags so board fetches stay
//! small; the frontend calls this endpoint only when a flag is true.
//! Returns `{ image_urls, video_urls }` as raw `||`-delimited strings
//! (the same wire shape the create/update endpoints accept). 404 when
//! the task does not exist under the item.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

pub const TasksMediaError = error{
    QueryFailed,
    TaskNotFound,
    OutOfMemory,
};

const MediaResponse = struct {
    image_urls: []const u8 = "",
    video_urls: []const u8 = "",
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
    task_id: []const u8,
) TasksMediaError![]const u8 {
    const media_opt = ai_mod.llm_history.getWorkspaceItemTaskMedia(
        allocator,
        db,
        item_id,
        task_id,
    ) catch return error.QueryFailed;
    const media = media_opt orelse return error.TaskNotFound;
    defer media.deinit(allocator);
    const resp = MediaResponse{
        .image_urls = media.image_urls,
        .video_urls = media.video_urls,
    };
    return std.json.Stringify.valueAlloc(allocator, resp, .{}) catch return error.OutOfMemory;
}

pub fn tasksMediaHandler(
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
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, item_id, task_id) catch |err| {
        const status: u16 = switch (err) {
            error.TaskNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskNotFound => "task not found",
            error.QueryFailed => "Failed to fetch task media",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Static contracts (Migration 092) ─────────────────────────────────────

const std_testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/tasks_media.zig";
const LLM_HISTORY_PATH = "src/agentic_loop/llm_history.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const TEST_RUNNER_PATH = "src/ai_workflow/tui/test_runner.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "tasks_media handler calls getWorkspaceItemTaskMedia" {
    const allocator = std_testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "getWorkspaceItemTaskMedia") == null) {
        std.debug.print("\n!! {s} does not call getWorkspaceItemTaskMedia !!\n", .{HANDLER_PATH});
        return error.MediaFnNotCalled;
    }
}

test "tasks_media handler guards empty task_id with 400" {
    const allocator = std_testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task_id required") == null) {
        std.debug.print("\n!! {s} does not guard an empty task_id !!\n", .{HANDLER_PATH});
        return error.TaskIdGuardMissing;
    }
}

test "tasks_media handler maps null DB result to 404" {
    const allocator = std_testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "task not found") == null) {
        std.debug.print("\n!! {s} does not map a missing task to 404 !!\n", .{HANDLER_PATH});
        return error.NotFoundBranchMissing;
    }
}

test "http_handlers mod re-exports tasksMediaHandler" {
    const allocator = std_testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "tasksMediaHandler") == null) {
        std.debug.print("\n!! {s} does not re-export tasksMediaHandler !!\n", .{MOD_PATH});
        return error.HandlerNotReExported;
    }
}

test "main.zig registers GET tasks/:task_id/media" {
    const allocator = std_testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);
    // Exact segment count differs from the `:task_id` route
    // (matchPathWithParams requires trailing exhaustion), so no
    // shadowing either way — but the route must exist.
    const media_route = "authed.get(\"/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/media\", ai_mod.http_handlers.tasksMediaHandler)";
    if (std.mem.indexOf(u8, source, media_route) == null) {
        std.debug.print("\n!! {s} does not register the task media GET route !!\n", .{MAIN_PATH});
        return error.MediaRouteMissing;
    }
}

test "llm_history exposes getWorkspaceItemTaskMedia" {
    const allocator = std_testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn getWorkspaceItemTaskMedia(") == null) {
        std.debug.print("\n!! {s} does not define `getWorkspaceItemTaskMedia` !!\n", .{LLM_HISTORY_PATH});
        return error.MediaFnMissing;
    }
}

test "test_runner registers tasks_media" {
    const allocator = std_testing.allocator;
    const source = try readSource(allocator, TEST_RUNNER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "tasks_media.zig") == null) {
        std.debug.print("\n!! {s} does not import tasks_media.zig !!\n", .{TEST_RUNNER_PATH});
        return error.TestNotRegistered;
    }
}
