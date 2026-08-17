//! `GET /api/agents/:agent_id/tools`.
//!
//! Returns `{tools: [string]}` — the enabled tool_names for the agent.
//! Mirrors the `agentsGetHandler.tools` field, but exposed as its
//! own endpoint so the frontend's Tools panel can refresh without
//! re-fetching knowledge.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

pub fn agentToolsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    if (agent_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "agent_id required" }),
        });
    }

    var q = sqlite_db.query(allocator,
        "SELECT tool_name FROM agent_tools WHERE agent_id = ? AND enabled = 1 ORDER BY tool_name ASC",
        &[_][]const u8{agent_id}) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "DB error" }),
        });
    };
    defer q.deinit();

    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |n| allocator.free(n);
        list.deinit(allocator);
    }

    while ((q.next() catch null)) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try allocator.dupe(u8, r.values[0]));
    }

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .tools = list.items }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}