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

/// Get environment variable or return default value (caller owns the memory)
fn getEnvOrDefault(allocator: std.mem.Allocator, key: []const u8, default: []const u8) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, key)) |value| {
        return value;
    } else |_| {
        return allocator.dupe(u8, default);
    }
}

/// Container for agent config from environment
const AgentConfig = struct {
    apiKey: []const u8,
    model: []const u8,
    baseUrl: []const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !AgentConfig {
        return .{
            .apiKey = try getEnvOrDefault(allocator, "API_KEY", "sk-sp-6704e245f468421e9935e36c923c344f"),
            .model = try getEnvOrDefault(allocator, "MODEL", "glm-5"),
            .baseUrl = try getEnvOrDefault(allocator, "BASE_URL", "https://coding-intl.dashscope.aliyuncs.com/v1"),
            .allocator = allocator,
        };
    }

    fn deinit(self: *const AgentConfig) void {
        self.allocator.free(self.apiKey);
        self.allocator.free(self.model);
        self.allocator.free(self.baseUrl);
    }
};

test "agent call builds correct json with tools" {
    const allocator = std.testing.allocator;
    
    var config = try AgentConfig.init(allocator);
    defer config.deinit();
    
    var agent = try Agent.init(allocator);
    agent.apiKey = config.apiKey;
    agent.model = config.model;
    agent.baseUrl = config.baseUrl;
    defer agent.deinit();

    const msgSystem = AgentMessage{ .role = .system, .content = "You are a helpful assistant" };
    const msgUser = AgentMessage{ .role = .user, .content = "Hello world" };

    // define tools
    const readFileTool = AgentTool{
        .type = "function",
        .function = .{
            .name = "read_file",
            .description = "Read the contents of a file",
            .parameters = .{
                .type = "object",
                .properties = &.{
                    .{ .name = "path", .type = "string", .description = "The file path to read" },
                },
                .required = &.{"path"},
            },
        },
    };

    const writeFileTool = AgentTool{
        .type = "function",
        .function = .{
            .name = "write_file",
            .description = "Write content to a file",
            .parameters = .{
                .type = "object",
                .properties = &.{
                    .{ .name = "path", .type = "string", .description = "The file path to write" },
                    .{ .name = "content", .type = "string", .description = "The content to write" },
                },
                .required = &.{ "path", "content" },
            },
        },
    };

    const params = AgentCall{
        .messages = &.{ msgSystem, msgUser },
        .tools = &.{ readFileTool, writeFileTool },
    };

    const json_body = try agent.buildJsonRequest(params);
    defer allocator.free(json_body);

    // expected JSON with tools array
    const expectedString =
        \\{"model":"glm-5","messages":[{"role":"system","content":"You are a helpful assistant"},{"role":"user","content":"Hello world"}],"temperature":0.6000000238418579,"max_tokens":10000,"tools":[{"type":"function","function":{"name":"read_file","description":"Read the contents of a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"The file path to read"}},"required":["path"]}}},{"type":"function","function":{"name":"write_file","description":"Write content to a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"The file path to write"},"content":{"type":"string","description":"The content to write"}},"required":["path","content"]}}}],"tool_choice":"auto"}
    ;

    try std.testing.expectEqualSlices(u8, json_body, expectedString);
}

test "agent call http get response ok" {
    const allocator = std.testing.allocator;
    
    var config = try AgentConfig.init(allocator);
    defer config.deinit();
    
    var agent = try Agent.init(allocator);
    agent.apiKey = config.apiKey;
    agent.model = config.model;
    agent.baseUrl = config.baseUrl;
    defer agent.deinit();

    const params = AgentCall{
        .messages = &.{.{ .role = .user, .content = "this is just testing, just response ok" }},
        .tools = &.{},
    };

    const response = try agent.call(params);
    defer response.deinit();

    std.debug.print("agent call http: response: {s}", .{response.content.?});

    try std.testing.expect(std.ascii.eqlIgnoreCase(response.content.?, "ok"));
}

test "agent call http get tools" {
    const allocator = std.testing.allocator;
    
    var config = try AgentConfig.init(allocator);
    defer config.deinit();
    
    var agent = try Agent.init(allocator);
    agent.apiKey = config.apiKey;
    agent.model = config.model;
    agent.baseUrl = config.baseUrl;
    defer agent.deinit();

    const msgSystem = AgentMessage{ .role = .system, .content = "You are a helpful assistant" };
    const msgUser = AgentMessage{ .role = .user, .content = "try ls" };

    const params = AgentCall{
        .messages = &.{ msgSystem, msgUser },
        .tools = &.{bashTool},
    };

    const response = try agent.call(params);
    defer response.deinit();
    try std.testing.expect(response.finish_reason.? == .tool_calls);

    for (response.tool_calls.?) |tool_call| {
        try std.testing.expect(std.mem.eql(u8, tool_call.function.name, "bash"));

        // std.debug.print(" arguments {s}\n ", tool_call.function.arguments);

        const args = tool_call.function.arguments;
        var parsed = try std.json.parseFromSlice(BashInput, allocator, args, .{});
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
