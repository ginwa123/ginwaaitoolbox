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

/// Execute the list_agents tool
/// Returns a JSON string with the list of available agents
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeListAgents(allocator: std.mem.Allocator) ![]const u8 {
    const agents_list = agents.listAgents(allocator);
    defer agents.freeAgentsList(allocator, agents_list);

    // Build JSON array
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"agents\":[");

    for (agents_list, 0..) |agent, i| {
        if (i > 0) {
            try result.appendSlice(allocator, ", ");
        }
        const escaped_name = escapeJsonString(allocator, agent.name);
        defer allocator.free(escaped_name);
        const escaped_desc = escapeJsonString(allocator, agent.description);
        defer allocator.free(escaped_desc);
        const entry = try std.fmt.allocPrint(allocator,
            \\{{"name":"{s}","description":"{s}"}}
        , .{ escaped_name, escaped_desc });
        defer allocator.free(entry);
        try result.appendSlice(allocator, entry);
    }

    try result.appendSlice(allocator, "]}");

    return allocator.dupe(u8, result.items) catch "";
}

/// Escape a string for JSON output
pub fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return "",
            '\\' => result.appendSlice(allocator, "\\\\") catch return "",
            '\n' => result.appendSlice(allocator, "\\n") catch return "",
            '\r' => result.appendSlice(allocator, "\\r") catch return "",
            '\t' => result.appendSlice(allocator, "\\t") catch return "",
            else => result.append(allocator, c) catch return "",
        }
    }

    return allocator.dupe(u8, result.items) catch "";
}

