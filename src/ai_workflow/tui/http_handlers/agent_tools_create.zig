//! `POST /api/agents/:agent_id/tools`.
//!
//! Enables a tool for an agent. Body: `{tool_name}`. Validates the
//! tool_name is in the canonical registry (400 if unknown). Maps
//! SQLite UNIQUE violation to HTTP 409 (duplicate).
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 8)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const helpers = nalarcore.helpers;

const CreateToolBody = struct {
    tool_name: []const u8,
};

/// Validate tool_name exists in UNIFIED_TOOL_REGISTRY.
fn isKnownTool(tool_name: []const u8) bool {
    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();
    for (registry) |entry| {
        if (std.mem.eql(u8, entry.name, tool_name)) return true;
    }
    return false;
}

pub fn agentToolsCreateHandler(
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

    const parsed = std.json.parseFromSliceLeaky(CreateToolBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.tool_name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "tool_name is required" }),
        });
    }

    if (!isKnownTool(parsed.tool_name)) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "tool_name is not in the registry" }),
        });
    }

    // Generate id + INSERT.
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "at_{d}", .{ts});

    // INSERT. Map UNIQUE violation (sqlite returns ExecuteFailed on
    // UNIQUE conflicts) to HTTP 409.
    sqlite_db.exec(allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
        &[_][]const u8{ id, agent_id, parsed.tool_name },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 409,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "tool already enabled for this agent" }),
        });
    };

    // Read back.
    var q = sqlite_db.query(allocator,
        "SELECT id, agent_id, tool_name, enabled FROM agent_tools WHERE id = ?",
        &.{id},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read row" }),
        });
    };
    defer q.deinit();
    const r = (q.next() catch null) orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Row missing after insert" }),
        });
    };
    defer r.deinit(allocator);

    const envelope = .{
        .id = r.values[0],
        .agent_id = r.values[1],
        .tool_name = r.values[2],
        .enabled = @as(u8, 1),
    };
    const data = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}