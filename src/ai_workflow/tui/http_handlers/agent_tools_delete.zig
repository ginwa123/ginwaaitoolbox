//! `DELETE /api/agents/:agent_id/tools/:tool_id`.
//! Removes a tool from the agent's allowlist.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

pub fn agentToolsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const tool_id = req.params.get("tool_id") orelse "";
    if (agent_id.len == 0 or tool_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "agent_id and tool_id required" }),
        });
    }

    sqlite_db.exec(allocator,
        "DELETE FROM agent_tools WHERE id = ? AND agent_id = ?",
        &[_][]const u8{ tool_id, agent_id },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete" }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}