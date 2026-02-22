const std = @import("std");
const json = std.json;
const stringify = std.json.Stringify.value;

// https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

pub const Role = enum([]const u8) {
    system = "system",
    user = "user",
    assistant = "assistant",
    tool = "tool",
    developer = "developer",
};

pub const ContentPart = union(enum) {
    text_content: TextContent,
    image_url: ImageContent,
    input_audio: InputAudioContent,

    pub fn text(txt: []const u8) ContentPart {
        return .{ .text_content = .{ .text = txt } };
    }

    pub fn image(url: []const u8) ContentPart {
        return .{ .image_url = .{ .image_url = .{ .url = url, .detail = .auto } } };
    }
};

pub const TextContent = struct {
    text: []const u8,
    type: []const u8 = "text",
};

pub const ImageContentDetail = enum([]const u8) {
    auto = "auto",
    low = "low",
    high = "high",
};

pub const ImageContent = struct {
    image_url: ImageUrl,
    type: []const u8 = "image_url",
};

pub const ImageUrl = struct {
    url: []const u8,
    detail: ImageContentDetail = .auto,
};

pub const InputAudioContent = struct {
    input_audio: InputAudio,
    type: []const u8 = "input_audio",
};

pub const InputAudio = struct {
    data: []const u8,
    format: []const u8,
};

pub const Message = union(enum) {
    system: SystemMessage,
    user: UserMessage,
    assistant: AssistantMessage,
    tool: ToolMessage,
    developer: DeveloperMessage,

    pub fn systemMessage(content: []const u8) Message {
        return .{ .system = .{ .content = content, .role = .system } };
    }

    pub fn userMessage(content: []const u8) Message {
        return .{ .user = .{ .content = content, .role = .user } };
    }

    pub fn userMessageWithImages(content: []const u8, images: []const []const u8) Message {
        var parts: std.ArrayList(ContentPart) = .empty;
        parts.append(std.heap.page_allocator, ContentPart.text(content)) catch unreachable;
        for (images) |img| {
            parts.append(std.heap.page_allocator, ContentPart.image(img)) catch unreachable;
        }
        return .{ .user = .{ .content = parts.items, .role = .user } };
    }

    pub fn assistantMessage(content: []const u8) Message {
        return .{ .assistant = .{ .content = content, .role = .assistant } };
    }

    pub fn toolMessage(tool_call_id: []const u8, content: []const u8) Message {
        return .{ .tool = .{ .tool_call_id = tool_call_id, .content = content, .role = .tool } };
    }

    pub fn developerMessage(content: []const u8) Message {
        return .{ .developer = .{ .content = content, .role = .developer } };
    }
};

pub const SystemMessage = struct {
    content: union {
        text: []const u8,
        parts: []ContentPart,
    },
    role: Role = .system,
    name: ?[]const u8 = null,

    pub fn jsonStringify(self: SystemMessage, jws: anytype) !void {
        var map = std.StringArrayHashMap(json.Value).init(std.heap.page_allocator);
        defer map.deinit();
        map.put("role", json.Value{ .string = "system" }) catch unreachable;
        switch (self.content) {
            .text => |txt| map.put("content", json.Value{ .string = txt }),
            .parts => |parts| {
                var arr = json.Array.init(std.heap.page_allocator);
                for (parts) |p| {
                    switch (p) {
                        .text => |t| {
                            var part_map = std.StringArrayHashMap(json.Value).init(std.heap.page_allocator);
                            part_map.put("type", json.Value{ .string = "text" }) catch unreachable;
                            part_map.put("text", json.Value{ .string = t.text }) catch unreachable;
                            arr.append(json.Value{ .object = part_map }) catch unreachable;
                        },
                        else => {},
                    }
                }
                map.put("content", json.Value{ .array = arr }) catch unreachable;
            },
        }
        if (self.name) |n| map.put("name", json.Value{ .string = n });
        try jws.write(json.Value{ .object = map });
    }
};

pub const UserMessage = struct {
    content: union {
        text: []const u8,
        parts: []ContentPart,
    },
    role: Role = .user,
    name: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const AssistantMessage = struct {
    content: ?[]const u8 = null,
    role: Role = .assistant,
    name: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ToolMessage = struct {
    tool_call_id: []const u8,
    content: []const u8,
    role: Role = .tool,
    name: ?[]const u8 = null,
};

pub const DeveloperMessage = struct {
    content: union {
        text: []const u8,
        parts: []ContentPart,
    },
    role: Role = .developer,
    name: ?[]const u8 = null,
};

pub const FunctionDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: json.Value,
};

pub const Tool = struct {
    type: []const u8 = "function",
    function: FunctionDefinition,
};

pub const ToolChoice = union(enum) {
    auto,
    none,
    required: ToolChoiceRequired,
};

pub const ToolChoiceRequired = struct {
    type: []const u8 = "function",
    function: FunctionName,
};

pub const FunctionName = struct {
    name: []const u8,
};

pub const ResponseFormat = union(enum) {
    text,
    json_object: ResponseFormatJsonObject,
};

pub const ResponseFormatJsonObject = struct {
    type: []const u8 = "json_object",
};

pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []Message,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    n: ?usize = null,
    stream: bool = false,
    stop: ?[]const []const u8 = null,
    max_tokens: ?usize = null,
    presence_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    logit_bias: ?std.StringArrayHashMap(i64) = null,
    user: ?[]const u8 = null,
    tools: ?[]Tool = null,
    tool_choice: ?ToolChoice = null,
    response_format: ?ResponseFormat = null,
    seed: ?i64 = null,
    store: ?bool = null,
    metadata: ?std.StringArrayHashMap(json.Value) = null,
    parallel_tool_calls: bool = true,
};

pub const ChatCompletionChoice = struct {
    index: usize,
    message: ChatCompletionMessage,
    finish_reason: ?[]const u8,
};

pub const ChatCompletionMessage = struct {
    role: Role,
    content: ?[]const u8,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ChatCompletionUsage = struct {
    prompt_tokens: usize,
    completion_tokens: usize,
    total_tokens: usize,
};

pub const ChatCompletionResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []ChatCompletionChoice,
    usage: ChatCompletionUsage,
    service_tier: ?[]const u8 = null,
    system_fingerprint: ?[]const u8 = null,
};

pub const CallResponse = struct {
    content: ?[]const u8,
    tool_calls: ?[]ToolCall,
};

pub const ToolParameter = struct {
    name: []const u8,
    type_hint: []const u8,
    description: []const u8,
    default_value: ?[]const u8,
    required: bool,
};

pub const ToolProperty = struct {
    name: []const u8,
    type: []const u8,
    description: []const u8,
};

pub const ToolParameters = struct {
    type: []const u8,
    properties: []const ToolProperty,
    required: []const []const u8,
};

pub const AgentToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: ToolParameters,
};

pub const AgentTool = struct {
    type: []const u8,
    function: AgentToolFunction,
};

pub const AgentTools = struct {
    name: []const u8,
    description: []const u8,
    parameters: []ToolParameter,
    returns: []const u8,
    required_params: [][]const u8,
    timeout_ms: u32,
    is_async: bool,
    allocator: std.mem.Allocator,

    pub fn toXml(self: AgentTools) ![]const u8 {
        _ = self;
        return "";
    }
};

// "role": "assistant",
//     "content": "Hello! How can I assist you today?",

pub const AgentMessage = struct {
    role: []const u8,
    content: ?[]const u8,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const AgentCall = struct {
    tools: []const AgentTool,
    messages: []const AgentMessage,
};

pub const Agent = struct {
    name: []const u8 = "",
    apiKey: []const u8 = "",
    baseUrl: []const u8 = "",
    model: []const u8 = "",
    temperature: f32 = 0.6,
    maxTokens: usize = 10000,
    httpClient: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Agent {
        return Agent{ .allocator = allocator, .httpClient = std.http.Client{ .allocator = allocator } };
    }

    fn buildJsonRequest(self: Agent, params: AgentCall) ![]const u8 {
        var messages_arr = std.array_list.Managed(json.Value).init(self.allocator);

        var user_msgs: []std.StringArrayHashMap(json.Value) = try self.allocator.alloc(std.StringArrayHashMap(json.Value), params.messages.len);

        for (params.messages, 0..) |msg, i| {
            user_msgs[i] = std.StringArrayHashMap(json.Value).init(self.allocator);
            try user_msgs[i].put("role", .{ .string = msg.role });
            if (msg.content) |c| {
                try user_msgs[i].put("content", .{ .string = c });
            }
            try messages_arr.append(.{ .object = user_msgs[i] });
        }

        var root = std.StringArrayHashMap(json.Value).init(self.allocator);
        try root.put("model", .{ .string = self.model });
        try root.put("messages", .{ .array = messages_arr });
        try root.put("temperature", .{ .float = self.temperature });
        try root.put("max_tokens", .{ .integer = @intCast(self.maxTokens) });

        var message_buffer_out = std.io.Writer.Allocating.init(self.allocator);
        var stringifier = json.Stringify{
            .writer = &message_buffer_out.writer,
            .options = .{},
        };

        try stringifier.write(json.Value{ .object = root });

        const result = try message_buffer_out.toOwnedSlice();

        messages_arr.deinit();
        for (user_msgs) |*m| m.deinit();
        self.allocator.free(user_msgs);
        root.deinit();

        if (params.tools.len > 0) {
            var tools_json_parts = try std.ArrayList([]const u8).initCapacity(self.allocator, params.tools.len);
            defer tools_json_parts.deinit(self.allocator);

            for (params.tools) |tool| {
                var props_json_parts: std.ArrayList([]const u8) = .empty;
                defer {
                    for (props_json_parts.items) |item| self.allocator.free(item);
                    props_json_parts.deinit(self.allocator);
                }

                for (tool.function.parameters.properties) |prop| {
                    const prop_json = try std.fmt.allocPrint(self.allocator, "\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{ prop.name, prop.type, prop.description });
                    try props_json_parts.append(self.allocator, prop_json);
                }

                const props_str = try std.mem.join(self.allocator, ",", props_json_parts.items);
                defer self.allocator.free(props_str);

                var required_parts: std.ArrayList([]const u8) = .empty;
                defer {
                    for (required_parts.items) |item| self.allocator.free(item);
                    required_parts.deinit(self.allocator);
                }

                for (tool.function.parameters.required) |req| {
                    const req_json = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{req});
                    try required_parts.append(self.allocator, req_json);
                }

                const required_str = try std.mem.join(self.allocator, ",", required_parts.items);
                defer self.allocator.free(required_str);

                const tool_json = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{{\"type\":\"object\",\"properties\":{{{s}}},\"required\":[{s}]}}}}}}", .{ tool.type, tool.function.name, tool.function.description, props_str, required_str });
                try tools_json_parts.append(self.allocator, tool_json);
            }

            const tools_str = try std.mem.join(self.allocator, ",", tools_json_parts.items);
            defer self.allocator.free(tools_str);

            defer {
                for (tools_json_parts.items) |item| self.allocator.free(item);
            }

            const full_tools_json = try std.fmt.allocPrint(self.allocator, ",\"tools\":[{s}],\"tool_choice\":\"auto\"}}", .{tools_str});
            defer self.allocator.free(full_tools_json);

            const json_str = try std.mem.concat(self.allocator, u8, &.{ result[0 .. result.len - 1], full_tools_json });
            self.allocator.free(result);
            return json_str;
        }

        return result;
    }

    pub fn call(self: *Agent, params: AgentCall) !CallResponse {
        const json_body = try self.buildJsonRequest(params);
        defer self.allocator.free(json_body);

        const uri_str = try std.mem.concat(self.allocator, u8, &.{ self.baseUrl, "/chat/completions" });
        defer self.allocator.free(uri_str);
        const uri = try std.Uri.parse(uri_str);
        const auth_value = try std.mem.concat(self.allocator, u8, &.{ "Bearer ", self.apiKey });
        defer self.allocator.free(auth_value);
        var req = try self.httpClient.request(.POST, uri, .{
            .version = .@"HTTP/1.1",
            .headers = .{
                .authorization = .{ .override = auth_value },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer req.deinit();

        try req.sendBodyComplete(@constCast(json_body));
        var redirect_buffer: [1024]u8 = undefined;
        var transfer_buffer: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        const body = try response.reader(transfer_buffer[0..]).allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(body);

        const parsed = json.parseFromSlice(json.Value, self.allocator, body, .{}) catch |err| {
            std.log.err("Failed to parse JSON response: {s}\nBody: {s}", .{ @errorName(err), body });
            return err;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root.object.get("error")) |_| {
            std.log.err("API error: {s}", .{body});
            return error.ApiError;
        }
        const choices = root.object.get("choices") orelse {
            std.log.err("No choices in response: {s}", .{body});
            return error.NoChoices;
        };
        const first_choice = choices.array.items[0];
        const message = first_choice.object.get("message").?;
        const content = message.object.get("content");
        const tool_calls_val = message.object.get("tool_calls");

        var tool_calls: ?[]ToolCall = null;
        if (tool_calls_val) |tc| {
            var calls: []ToolCall = try self.allocator.alloc(ToolCall, tc.array.items.len);
            for (tc.array.items, 0..) |tc_item, i| {
                const tc_obj = tc_item.object;
                const id = tc_obj.get("id").?.string;
                const func_obj = tc_obj.get("function").?.object;
                const name = func_obj.get("name").?.string;
                const arguments = func_obj.get("arguments").?.string;
                calls[i] = .{ .id = id, .function = .{ .name = name, .arguments = arguments } };
            }
            tool_calls = calls;
        }

        return .{
            .content = if (content) |c| c.string else null,
            .tool_calls = tool_calls,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.httpClient.deinit();
    }
};

test "agent call builds correct json with tools" {
    const allocator = std.testing.allocator;
    var agent = try Agent.init(allocator);
    agent.apiKey = "551857def24c42b4a751b60ea76bf37b.19BLI68KYxq3Y5Vg";
    agent.model = "glm-5";
    agent.baseUrl = "https://api.z.ai/api/coding/paas/v4";
    defer agent.deinit();

    const msgSystem = AgentMessage{ .role = "system", .content = "You are a helpful assistant" };
    const msgUser = AgentMessage{ .role = "user", .content = "Hello world" };

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

    const params = AgentCall{
        .messages = &.{.{ .role = "user", .content = "this is just testing, just response ok" }},
        .tools = &.{},
    };
    _ = params;

    // const response = try agent.call(params);
    //
    // std.debug.print("agent call http: response: {s}", .{response.content.?});

}
