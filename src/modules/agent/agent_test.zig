const std = @import("std");
const json = std.json;
const bashTool = @import("tools/bash.zig").bashTool;
const bashMod = @import("tools/bash.zig");
const BashInput = @import("tools/models.zig").BashInput;
const ToolProperty = @import("tools/models.zig").ToolProperty;
const ToolParameters = @import("tools/models.zig").ToolParameters;
const AgentToolFunction = @import("tools/models.zig").AgentToolFunction;
const AgentTool = @import("tools/models.zig").AgentTool;

const Agent = @import("agent.zig").Agent;
const AgentCall = @import("agent.zig").AgentCall;
const AgentMessage = @import("agent.zig").AgentMessage;


test "agent call http get response ok" {
    const allocator = std.testing.allocator;
    var agent = try Agent.init(allocator);
    agent.apiKey = "551857def24c42b4a751b60ea76bf37b.19BLI68KYxq3Y5Vg";
    agent.model = "glm-5";
    agent.baseUrl = "https://api.z.ai/api/coding/paas/v4";
    defer agent.deinit();

    const params = AgentCall{
        .messages = &.{.{ .role = "user", .content = "this is just testing, just response ok" }},
        .tools = &.{},
    };

    const response = try agent.call(params);
    defer response.deinit();

    std.debug.print("agent call http: response: {s}", .{response.content.?});

    try std.testing.expect(std.ascii.eqlIgnoreCase(response.content.?, "ok"));
}

test "agent call http get tools" {
    const allocator = std.testing.allocator;
    var agent = try Agent.init(allocator);
    agent.apiKey = "551857def24c42b4a751b60ea76bf37b.19BLI68KYxq3Y5Vg";
    agent.model = "glm-5";
    agent.baseUrl = "https://api.z.ai/api/coding/paas/v4";
    defer agent.deinit();

    const msgSystem = AgentMessage{ .role = "system", .content = "You are a helpful assistant" };
    const msgUser = AgentMessage{ .role = "user", .content = "try ls" };

    const params = AgentCall{
        .messages = &.{ msgSystem, msgUser },
        .tools = &.{bashTool},
    };

    const response = try agent.call(params);
    defer response.deinit();
    try std.testing.expect(std.mem.eql(u8, response.finish_reason.?, "tool_calls"));

    for (response.tool_calls.?) |tool_call| {
        try std.testing.expect(std.mem.eql(u8, tool_call.function.name, "bash"));

        // std.debug.print(" arguments {s}\n ", tool_call.function.arguments);

        const args = tool_call.function.arguments;
        var parsed = try std.json.parseFromSlice(BashInput, allocator, args , .{});
        defer parsed.deinit();

        const bInput = BashInput{
            .command = parsed.value.command,
            .cwd = parsed.value.cwd,
            .max_output = parsed.value.max_output,
            .timeout = parsed.value.timeout,
        };
        const r = try bashMod.executeBash(allocator, bInput);
        defer allocator.free(r);

        std.debug.print(" result {s}", .{r});
    }
}

