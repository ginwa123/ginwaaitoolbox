//! `GET /api/workers/:session_id` — fetch a worker by session_id.
//!
//! Layered as `useCase` (resolve singleton + DB query) and a thin
//! handler that maps the outcome + errors to status codes / JSON.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_workflow = nalarcore.ai_workflow;
const llm_history = nalarcore.llm_history;
const auth_common = @import("auth_common.zig");

pub const WorkerGetError = error{
    ServerNotInitialized,
    QueryFailed,
};

/// Tagged outcome of the worker-get use-case.
pub const WorkerGetResult = union(enum) {
    found: llm_history.Worker,
    not_found,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_user_id: []const u8,
) WorkerGetError!WorkerGetResult {
    const server = gserverz.global_server orelse return error.ServerNotInitialized;
    const server_ctx = server.ctx orelse return error.ServerNotInitialized;
    const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
    const sqlite_db = ctxTui.db;

    const worker = llm_history.getWorkerBySessionIdForUser(allocator, sqlite_db, session_id, request_user_id) catch return error.QueryFailed;
    if (worker) |w| return .{ .found = w };
    return .not_found;
}

// =====================================================================
// Handler
// =====================================================================

pub fn workerGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    _: *anyopaque,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = "{\"error\":\"Missing session_id\"}",
        });
    };

    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = "{\"error\":\"Server not initialized\"}",
        });
    };
    var request_user_id: []const u8 = undefined;
    var owns_user_id = true;
    request_user_id = auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch blk: {
        owns_user_id = false;
        break :blk "user_system";
    };
    defer if (owns_user_id) allocator.free(request_user_id);

    const outcome = useCase(allocator, session_id, request_user_id) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.QueryFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.QueryFailed => "Database query failed",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = "{\"error\":\"" ++ message ++ "\"}",
        });
    };

    switch (outcome) {
        .found => |w| {
            const response = try std.fmt.allocPrint(
                allocator,
                "{{\"sessionId\":\"{s}\",\"workingDirectory\":\"{s}\",\"lastActivity\":{},\"lastActivityDescription\":\"{s}\"}}",
                .{ w.session_id, w.working_directory, w.last_activity, w.last_activity_description },
            );
            w.deinit(allocator);
            return res.jsonResponse(.{ .status_code = 200, .data = response });
        },
        .not_found => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = "{\"error\":\"Worker not found\"}",
            });
        },
    }
}