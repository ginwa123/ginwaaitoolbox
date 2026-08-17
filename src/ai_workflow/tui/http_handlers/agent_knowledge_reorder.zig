//! `PATCH /api/agents/:agent_id/knowledge/reorder`.
//!
//! Body: `{ordered_ids: string[]}`. Reorders the agent's knowledge rows
//! to match the supplied order. `ordered_ids[0]` becomes position N
//! (highest), `ordered_ids[N-1]` becomes position 0 (lowest).
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 6)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

const ReorderBody = struct {
    ordered_ids: []const []const u8 = &.{},
};

pub fn agentKnowledgeReorderHandler(
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

    const parsed = std.json.parseFromSliceLeaky(ReorderBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.ordered_ids.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }),
        });
    }

    // BEGIN/COMMIT so the reorders are atomic.
    sqlite_db.exec(allocator, "BEGIN", &[_][]const u8{}) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to begin transaction" }),
        });
    };
    errdefer {
        sqlite_db.exec(allocator, "ROLLBACK", &[_][]const u8{}) catch {};
    }

    // Assign positions: index 0 → highest position. Use
    // `len - i` so orderings with 1 row don't end up with position 0
    // (which would put the row at the bottom).
    for (parsed.ordered_ids, 0..) |id, i| {
        const position: i64 = @intCast(parsed.ordered_ids.len - 1 - @as(usize, @intCast(i)));
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
        sqlite_db.exec(allocator,
            "UPDATE agent_knowledge SET position = ?, updated_at = datetime('now') WHERE id = ? AND agent_id = ?",
            &[_][]const u8{ pos_str, id, agent_id },
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update position" }),
            });
        };
    }

    sqlite_db.exec(allocator, "COMMIT", &[_][]const u8{}) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to commit" }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

var default_buf: [16]u8 = undefined;