//! `PATCH /api/workspaces/:workspace_id/items/:item_id/agent`.
//!
//! Body: `{description}`. Updates the description of the agent
//! bound to this workspace_item. Returns 200 with the updated agent
//! row, or 400/404 for validation errors (same as `agents_get.zig`).
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 5)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

const UpdateAgentBody = struct {
    description: []const u8 = "",
};

pub fn agentsUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateAgentBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // Validate item exists + is an agent.
    var q = sqlite_db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{item_id},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to query workspace_item" }),
        });
    };
    defer q.deinit();
    const row = (q.next() catch null) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_item not found" }),
        });
    };
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "agent")) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_item is not an agent" }),
        });
    }

    // UPDATE description.
    sqlite_db.exec(allocator,
        "UPDATE agents SET description = ?, updated_at = datetime('now') WHERE id = ?",
        &[_][]const u8{ parsed.description, item_id },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update agent" }),
        });
    };

    // Read back the updated row.
    var q2 = sqlite_db.query(allocator,
        "SELECT id, workspace_item_id, description, IFNULL(created_at, ''), IFNULL(updated_at, '') FROM agents WHERE id = ?",
        &[_][]const u8{item_id},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read updated agent" }),
        });
    };
    defer q2.deinit();
    const updated_row = (q2.next() catch null) orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Agent row vanished after UPDATE" }),
        });
    };

    const envelope = struct {
        agent: struct {
            id: []const u8,
            workspace_item_id: []const u8,
            description: []const u8,
            created_at: []const u8,
            updated_at: []const u8,
        },
    }{
        .agent = .{
            .id = updated_row.values[0],
            .workspace_item_id = updated_row.values[1],
            .description = updated_row.values[2],
            .created_at = updated_row.values[3],
            .updated_at = updated_row.values[4],
        },
    };
    const data = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}