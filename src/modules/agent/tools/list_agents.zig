const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const agents = @import("agents.zig");

/// Result structure for list_agents tool
pub const ListAgentsResult = struct {
    agents: []agents.AgentInfo,
};

/// Tool definition for list_agents
pub const list_agents_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_agents",
        .description = "List all available agents with brief descriptions. Use this to discover what agents are available for use.",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

/// JSON payload for list_agents results, mirroring AgentInfo fields 1:1.
pub const AgentJSON = struct {
    name: []const u8,
    description: []const u8,
};

pub const ListAgentsJSON = struct {
    agents: []AgentJSON,
};

pub const ListAgentsErrorJSON = struct {
    @"error": []const u8,
    agents: []AgentJSON,
};

/// Execute the list_agents tool
/// Returns an owned JSON string with the list of available agents
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeListAgents(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) ![]const u8 {
    const agents_list = agents.listAgents(allocator, io, environment);
    defer agents.freeAgentsList(allocator, agents_list);

    var entries = try allocator.alloc(AgentJSON, agents_list.len);
    defer allocator.free(entries);
    for (agents_list, 0..) |agent, i| {
        entries[i] = .{ .name = agent.name, .description = agent.description };
    }

    return try std.json.Stringify.valueAlloc(allocator, ListAgentsJSON{
        .agents = entries,
    }, .{});
}

/// Generate error JSON response (owned; caller frees)
pub fn jsonError(allocator: std.mem.Allocator, error_msg: []const u8) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, ListAgentsErrorJSON{
        .@"error" = error_msg,
        .agents = &.{},
    }, .{});
}

test "list_agents executeListAgents returns JSON agents array" {
    const allocator = std.testing.allocator;
    const out = try executeListAgents(allocator, std.testing.io, null);
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("agents").? == .array);
}

test "list_agents jsonError emits JSON error shape" {
    const allocator = std.testing.allocator;
    const out = try jsonError(allocator, "boom");
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("boom", obj.get("error").?.string);
    try std.testing.expectEqual(@as(usize, 0), obj.get("agents").?.array.items.len);
}
