const std = @import("std");
const json = std.json;
const bashTool = @import("tree1").bash_tool.bashTool;
const bashMod = @import("tree1").bash_tool;
const BashInput = @import("tree1").tool_models.BashInput;
const ToolProperty = @import("tree1").tool_models.ToolProperty;
const ToolParameters = @import("tree1").tool_models.ToolParameters;
const AgentToolFunction = @import("tree1").tool_models.AgentToolFunction;
const AgentTool = @import("tree1").tool_models.AgentTool;

const Agent = @import("tree1").agent.Agent;
const logger = @import("tree1").logger;
const AgentCall = @import("tree1").agent.AgentCall;
const AgentMessage = @import("tree1").agent.AgentMessage;
const ToolCall = @import("tree1").agent.ToolCall;

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

    var test_logger = logger.Logger.init(allocator, .{});
    var agent = try Agent.init(allocator, &test_logger);
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

    const json_body = try agent.buildJsonRequest(params, false);
    defer allocator.free(json_body);

    // expected JSON with tools array
    const expectedString =
        \\{"model":"glm-5","enable_thinking":true,"messages":[{"role":"system","content":"You are a helpful assistant"},{"role":"user","content":"Hello world"}],"temperature":0.4000000059604645,"max_tokens":4096,"tools":[{"type":"function","function":{"name":"read_file","description":"Read the contents of a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"The file path to read"}},"required":["path"]}}},{"type":"function","function":{"name":"write_file","description":"Write content to a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"The file path to write"},"content":{"type":"string","description":"The content to write"}},"required":["path","content"]}}}],"tool_choice":"auto"}
    ;

    try std.testing.expectEqualSlices(u8, json_body, expectedString);
}

test "agent call builds correct json with tool_calls in message" {
    const allocator = std.testing.allocator;

    var config = try AgentConfig.init(allocator);
    defer config.deinit();

    var test_logger = logger.Logger.init(allocator, .{});
    var agent = try Agent.init(allocator, &test_logger);
    agent.apiKey = config.apiKey;
    agent.model = config.model;
    agent.baseUrl = config.baseUrl;
    defer agent.deinit();

    // Message with tool_calls (assistant response with tool call)
    var tool_calls_list: std.ArrayList(ToolCall) = .empty;
    defer tool_calls_list.deinit(allocator);
    try tool_calls_list.append(allocator, .{
        .id = "call_123",
        .type = "function",
        .function = .{
            .name = "bash",
            .arguments = "{\"command\":\"ls -la\"}",
        },
    });
    const tool_calls_slice = try tool_calls_list.toOwnedSlice(allocator);
    defer allocator.free(tool_calls_slice);

    const msgAssistant = AgentMessage{
        .role = .assistant,
        .content = null,
        .tool_calls = tool_calls_slice,
    };
    const msgTool = AgentMessage{
        .role = .tool,
        .content = "file1.txt\nfile2.txt",
        .tool_call_id = "call_123",
    };

    const params = AgentCall{
        .messages = &.{ msgAssistant, msgTool },
        .tools = &.{},
    };

    const json_body = try agent.buildJsonRequest(params, false);
    defer allocator.free(json_body);

    // Verify the JSON is valid and contains the tool_calls array
    var parsed = try json.parseFromSlice(json.Value, allocator, json_body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root.object.get("messages") != null);
    const messages = root.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);

    // Check first message has tool_calls
    const first_msg = messages.items[0].object;
    try std.testing.expect(first_msg.get("tool_calls") != null);
    const tool_calls = first_msg.get("tool_calls").?.array;
    try std.testing.expectEqual(@as(usize, 1), tool_calls.items.len);

    const tc = tool_calls.items[0].object;
    try std.testing.expectEqualSlices(u8, "call_123", tc.get("id").?.string);
    try std.testing.expectEqualSlices(u8, "bash", tc.get("function").?.object.get("name").?.string);
}

// test "agent call http get response ok" {
//     const allocator = std.testing.allocator;
//
//     var config = try AgentConfig.init(allocator);
//     defer config.deinit();
//
// //     var test_logger = logger.Logger.init(allocator, .{});
//     var agent = try Agent.init(allocator, &test_logger);
//     agent.apiKey = config.apiKey;
//     agent.model = config.model;
//     agent.baseUrl = config.baseUrl;
//     defer agent.deinit();
//
//     const params = AgentCall{
//         .messages = &.{.{ .role = .user, .content = "this is just testing, just response ok" }},
//         .tools = &.{},
//     };
//
//     const response = try agent.call(params);
//     defer response.deinit();
//
//     std.debug.print("agent call http: response: {s}", .{response.content.?});
//
//     try std.testing.expect(std.ascii.eqlIgnoreCase(response.content.?, "ok"));
// }

// test "agent call http get tools" {
//     const allocator = std.testing.allocator;
//
//     var config = try AgentConfig.init(allocator);
//     defer config.deinit();
//
// //     var test_logger = logger.Logger.init(allocator, .{});
//     var agent = try Agent.init(allocator, &test_logger);
//     agent.apiKey = config.apiKey;
//     agent.model = config.model;
//     agent.baseUrl = config.baseUrl;
//     defer agent.deinit();
//
//     const msgSystem = AgentMessage{ .role = .system, .content = "You are a helpful assistant" };
//     const msgUser = AgentMessage{ .role = .user, .content = "try ls" };
//
//     const params = AgentCall{
//         .messages = &.{ msgSystem, msgUser },
//         .tools = &.{bashTool},
//     };
//
//     const response = try agent.call(params);
//     defer response.deinit();
//     try std.testing.expect(response.finish_reason.? == .tool_calls);
//
//     for (response.tool_calls.?) |tool_call| {
//         try std.testing.expect(std.mem.eql(u8, tool_call.function.name, "bash"));
//
//         // std.debug.print(" arguments {s}\n ", tool_call.function.arguments);
//
//         const args = tool_call.function.arguments;
//         var parsed = try std.json.parseFromSlice(BashInput, allocator, args, .{});
//         defer parsed.deinit();
//
//         const bInput = BashInput{
//             .command = parsed.value.command,
//             .cwd = parsed.value.cwd,
//             .max_output = parsed.value.max_output,
//             .timeout = parsed.value.timeout,
//         };
//         const r = try bashMod.executeBash(allocator, bInput);
//         defer allocator.free(r);
//
//         std.debug.print(" result {s}", .{r});
//     }
// }
