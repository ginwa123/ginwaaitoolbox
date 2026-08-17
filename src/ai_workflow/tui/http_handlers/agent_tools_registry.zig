//! `GET /api/agent-tools/registry`.
//!
//! Returns the canonical tool registry as `{tools: [{name, description}]}`.
//! Sourced from `tools_equipped.UNIFIED_TOOL_REGISTRY()` — the same
//! source of truth the runtime tool filter reads. When a tool is added
//! or removed in that function, the registry endpoint automatically
//! reflects it (no drift, no second list to maintain).
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 7)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");

pub fn agentToolsRegistryHandler(
    ctx: gserverz.HttpContext,
    _: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();

    // Build [{name, description}, ...] from the runtime registry.
    var list: std.ArrayList(struct {
        name: []const u8,
        description: []const u8,
    }) = .empty;
    defer {
        for (list.items) |t| allocator.free(t.description);
        list.deinit(allocator);
    }

    for (registry) |entry| {
        const desc = entry.tool_def.function.description;
        try list.append(allocator, .{
            .name = entry.name,
            .description = try allocator.dupe(u8, desc),
        });
    }

    const envelope = .{ .tools = list.items };
    const data = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}