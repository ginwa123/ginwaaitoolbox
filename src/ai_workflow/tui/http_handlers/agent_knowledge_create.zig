//! `POST /api/agents/:agent_id/knowledge`.
//!
//! Adds a markdown knowledge file to an Agent. Body: `{file_path, label?, position?}`.
//! `file_path` MUST be absolute (`std.fs.path.isAbsolute`) — relative
//! paths return 400.
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 6)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = nalarcore.helpers;

const CreateKnowledgeBody = struct {
    file_path: []const u8,
    label: []const u8 = "",
};

pub fn agentKnowledgeCreateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.file_path.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "file_path is required" }),
        });
    }

    // Absolute path validation.
    if (!std.fs.path.isAbsolute(parsed.file_path)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "file_path must be absolute" }),
        });
    }

    // Validate agent exists + is an agent.
    {
        var q = sqlite_db.query(allocator,
            "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'agent'",
            &[_][]const u8{agent_id},
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "DB error" }),
            });
        };
        defer q.deinit();
        const row = q.next() catch null;
        if (row == null) {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "agent not found" }),
            });
        }
    }

    // Generate id + compute position.
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "know_{d}", .{ts});

    // INSERT with COALESCE for position (mirrors kanban_column_create).
    sqlite_db.exec(allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position, created_at, updated_at) VALUES (?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM agent_knowledge WHERE agent_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ id, agent_id, parsed.file_path, parsed.label, agent_id },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to insert knowledge" }),
        });
    };

    // Read back position.
    var q2 = sqlite_db.query(allocator,
        "SELECT position FROM agent_knowledge WHERE id = ?",
        &.{id},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read position" }),
        });
    };
    defer q2.deinit();
    const r = (q2.next() catch null) orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Row missing after insert" }),
        });
    };
    defer r.deinit(allocator);
    const position = std.fmt.parseInt(i64, r.values[0], 10) catch 0;

    const envelope = .{
        .id = id,
        .agent_id = agent_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
        .position = position,
    };
    const data = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}