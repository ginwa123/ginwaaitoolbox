const std = @import("std");
const json = std.json;
const bashTool = @import("tools/bash.zig").bashTool;
const bashMod = @import("tools/bash.zig");
const BashInput = @import("tools/models.zig").BashInput;
const ToolProperty = @import("tools/models.zig").ToolProperty;
const ToolParameters = @import("tools/models.zig").ToolParameters;
const AgentToolFunction = @import("tools/models.zig").AgentToolFunction;
const AgentTool = @import("tools/models.zig").AgentTool;

// https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const AgentResponse = struct {
    choices: []Choice,
};

pub const Choice = struct {
    index: usize = 0,
    message: Message,
    finish_reason: ?FinishReason = null,
};

pub const Message = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    reasoning_content: ?[]const u8 = null,
};

pub const Role = enum {
    /// System message
    system,
    /// User message
    user,
    /// Assistant message
    assistant,
    /// Tool result message
    tool,

    pub fn fromStr(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }

    pub fn toStr(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const AgentMessage = struct {
    role: Role,
    content: ?[]const u8,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn deinit(self: *const AgentMessage, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.reasoning_content) |rc| allocator.free(rc);
        if (self.tool_calls) |tc| {
            for (tc) |*tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.function.name);
                allocator.free(tool_call.function.arguments);
            }
            allocator.free(tc);
        }
    }
};

pub const FinishReason = enum {
    /// Model generated a complete message
    stop,
    /// Model hit max tokens limit
    length,
    /// Model triggered a tool call
    tool_calls,
    /// Content was filtered due to safety policies
    content_filter,
    /// No finish reason provided
    null,

    pub fn fromStr(s: ?[]const u8) ?FinishReason {
        if (s == null) return .null;
        const str = s.?;
        if (std.mem.eql(u8, str, "stop")) return .stop;
        if (std.mem.eql(u8, str, "length")) return .length;
        if (std.mem.eql(u8, str, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, str, "content_filter")) return .content_filter;
        return null;
    }

    pub fn toStr(self: FinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .tool_calls => "tool_calls",
            .content_filter => "content_filter",
            .null => "null",
        };
    }
};

/// Token usage information from the API
pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
};

pub const AgentCall = struct {
    tools: []const AgentTool,
    messages: []const AgentMessage,
    temperature: ?f32 = null,
    max_tokens: ?usize = null,
};

pub const AgentLogger = *const fn (level: std.log.Level, message: []const u8) void;

pub const HttpOptions = struct {
    read_timeout_ms: u32 = 60000,
    /// Buffer size for reading HTTP response body (default 64KB for large API responses)
    response_buffer_size: usize = 64 * 1024,
};

pub const Agent = struct {
    name: []const u8 = "",
    apiKey: []const u8 = "",
    baseUrl: []const u8 = "",
    model: []const u8 = "",
    temperature: f32 = 0.6,
    maxTokens: usize = 10000,
    httpClient: std.http.Client,
    thinkingEnabled: bool = true,
    allocator: std.mem.Allocator,
    logger: ?AgentLogger = null,
    httpOptions: HttpOptions = .{},

    pub const CallResponse = struct {
        allocator: std.mem.Allocator,
        content: ?[]const u8,
        tool_calls: ?[]ToolCall,
        finish_reason: ?FinishReason,
        reasoning_content: ?[]const u8 = null,
        usage: Usage = .{},

        pub fn deinit(self: *const CallResponse) void {
            if (self.content) |c| self.allocator.free(c);
            if (self.reasoning_content) |rc| self.allocator.free(rc);
            if (self.tool_calls) |tc| self.allocator.free(tc);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Agent {
        return Agent{ .allocator = allocator, .httpClient = std.http.Client{ .allocator = allocator } };
    }

    pub fn logMsg(self: Agent, level: std.log.Level, message: []const u8) void {
        if (self.logger) |logger| {
            logger(level, message);
        } else {
            switch (level) {
                .err => std.debug.print("[ERROR] {s}\n", .{message}),
                .warn => std.debug.print("[WARN] {s}\n", .{message}),
                .info => std.debug.print("[INFO] {s}\n", .{message}),
                .debug => std.debug.print("[DEBUG] {s}\n", .{message}),
            }
        }
    }

    pub fn buildJsonRequest(self: Agent, params: AgentCall) ![]const u8 {
        var messages_arr = std.array_list.Managed(json.Value).init(self.allocator);

        var user_msgs: []std.StringArrayHashMap(json.Value) = try self.allocator.alloc(std.StringArrayHashMap(json.Value), params.messages.len);

        for (params.messages, 0..) |msg, i| {
            user_msgs[i] = std.StringArrayHashMap(json.Value).init(self.allocator);
            try user_msgs[i].put("role", .{ .string = msg.role.toStr() });
            if (msg.content) |c| {
                try user_msgs[i].put("content", .{ .string = c });
            }
            // Add reasoning_content for assistant messages
            if (msg.reasoning_content) |rc| {
                try user_msgs[i].put("reasoning_content", .{ .string = rc });
            }
            // Add tool_call_id for tool result messages
            if (msg.tool_call_id) |id| {
                try user_msgs[i].put("tool_call_id", .{ .string = id });
            }
            if (msg.tool_calls) |tcs| {
                var tc_arr = std.array_list.Managed(json.Value).init(self.allocator);
                for (tcs) |tc| {
                    var tc_obj = std.StringArrayHashMap(json.Value).init(self.allocator);
                    try tc_obj.put("id", .{ .string = tc.id });
                    try tc_obj.put("type", .{ .string = tc.type });
                    var func_obj = std.StringArrayHashMap(json.Value).init(self.allocator);
                    try func_obj.put("name", .{ .string = tc.function.name });
                    try func_obj.put("arguments", .{ .string = tc.function.arguments });
                    try tc_obj.put("function", .{ .object = func_obj });
                    try tc_arr.append(.{ .object = tc_obj });
                }
                try user_msgs[i].put("tool_calls", .{ .array = tc_arr });
            }
            try messages_arr.append(.{ .object = user_msgs[i] });
        }

        var root = std.StringArrayHashMap(json.Value).init(self.allocator);
        try root.put("model", .{ .string = self.model });

        // Add thinking configuration for Kimi K2.5 models
        if (!self.thinkingEnabled) {
            var thinking = std.StringArrayHashMap(json.Value).init(self.allocator);
            try thinking.put("type", .{ .string = "disabled" });
            try root.put("thinking", .{ .object = thinking });
        }

        try root.put("messages", .{ .array = messages_arr });
        const temp = params.temperature orelse self.temperature;
        try root.put("temperature", .{ .float = temp });
        const max_tokens = params.max_tokens orelse self.maxTokens;
        try root.put("max_tokens", .{ .integer = @intCast(max_tokens) });

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

    pub const CallError = error{
        BuildRequestFailed,
        InvalidUri,
        AuthFailed,
        HttpRequestFailed,
        SendBodyFailed,
        ReceiveFailed,
        ParseJsonFailed,
        ApiError,
        NoChoices,
        AllocFailed,
        WriteFailed,
        OutOfMemory,
    };

    pub fn call(self: *Agent, params: AgentCall) CallError!CallResponse {
        self.logMsg(.info, "Building JSON request...");
        const json_body = try self.buildJsonRequest(params);
        self.logMsg(.info, "JSON request built, sending...");
        defer self.allocator.free(json_body);

        self.logMsg(.debug, json_body);

        const uri_str = try std.mem.concat(self.allocator, u8, &.{ self.baseUrl, "/chat/completions" });
        defer self.allocator.free(uri_str);
        const uri = std.Uri.parse(uri_str) catch {
            self.logMsg(.err, "Invalid URI");
            return error.InvalidUri;
        };
        const auth_value = try std.mem.concat(self.allocator, u8, &.{ "Bearer ", self.apiKey });
        defer self.allocator.free(auth_value);
        var req = self.httpClient.request(.POST, uri, .{
            .version = .@"HTTP/1.1",
            .headers = .{
                .authorization = .{ .override = auth_value },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| {
            self.logMsg(.err, @errorName(err));
            return error.HttpRequestFailed;
        };
        defer req.deinit();

        if (req.connection) |conn| {
            const stream = conn.stream_reader.getStream();
            const handle = stream.handle;
            const timeout = std.posix.timeval{
                .sec = @intCast(self.httpOptions.read_timeout_ms / 1000),
                .usec = @intCast((self.httpOptions.read_timeout_ms % 1000) * 1000),
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
        }

        req.sendBodyComplete(@constCast(json_body)) catch |err| {
            self.logMsg(.err, @errorName(err));
            return error.SendBodyFailed;
        };
        var redirect_buffer: [4096]u8 = undefined;
        // Use heap-allocated buffer for response body to handle large API responses
        const transfer_buffer = try self.allocator.alloc(u8, self.httpOptions.response_buffer_size);
        defer self.allocator.free(transfer_buffer);
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            self.logMsg(.err, @errorName(err));
            return error.ReceiveFailed;
        };

        const body = response.reader(transfer_buffer[0..]).allocRemaining(self.allocator, .unlimited) catch |err| {
            self.logMsg(.err, @errorName(err));
            return error.ReceiveFailed;
        };
        defer self.allocator.free(body);
        self.logMsg(.info, "Response received, parsing JSON...");
        self.logMsg(.debug, body);

        const parsed = json.parseFromSlice(json.Value, self.allocator, body, .{}) catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "Failed to parse JSON response: {s}\nBody: {s}", .{ @errorName(err), body }) catch "error";
            self.logMsg(.err, msg);
            return error.ParseJsonFailed;
        };
        defer parsed.deinit();
        self.logMsg(.debug, body);

        const root = parsed.value;
        if (root.object.get("error")) |_| {
            const msg = std.fmt.allocPrint(self.allocator, "API error: {s}", .{body}) catch "error";
            self.logMsg(.err, msg);
            return error.ApiError;
        }
        const choices = root.object.get("choices") orelse {
            const msg = std.fmt.allocPrint(self.allocator, "No choices in response: {s}", .{body}) catch "error";
            self.logMsg(.err, msg);
            return error.NoChoices;
        };
        const first_choice = choices.array.items[0];
        const message = first_choice.object.get("message").?;
        const content = message.object.get("content");
        const tool_calls_val = message.object.get("tool_calls");
        const finish_reason_val = first_choice.object.get("finish_reason");
        const reasoning_content_val = message.object.get("reasoning_content");

        if (content != null) {
            self.logMsg(.info, "Response content received");
        } else if (tool_calls_val != null) {
            self.logMsg(.info, "Response contains tool_calls");
        }

        if (reasoning_content_val) |rc| {
            self.logMsg(.debug, rc.string);
        }

        var tool_calls: ?[]ToolCall = null;
        if (tool_calls_val) |tc| {
            var calls = try self.allocator.alloc(ToolCall, tc.array.items.len);
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

        const finish_reason = FinishReason.fromStr(if (finish_reason_val) |fr| fr.string else null);

        var content_copy: ?[]const u8 = null;
        if (content) |c| {
            content_copy = try self.allocator.dupe(u8, c.string);
        }

        var reasoning_content_copy: ?[]const u8 = null;
        if (reasoning_content_val) |rc| {
            reasoning_content_copy = try self.allocator.dupe(u8, rc.string);
        }

        // Parse usage information
        var usage: Usage = .{};
        if (root.object.get("usage")) |usage_val| {
            if (usage_val.object.get("prompt_tokens")) |pt| {
                usage.prompt_tokens = @intCast(pt.integer);
            }
            if (usage_val.object.get("completion_tokens")) |ct| {
                usage.completion_tokens = @intCast(ct.integer);
            }
            if (usage_val.object.get("total_tokens")) |tt| {
                usage.total_tokens = @intCast(tt.integer);
            }
        }

        return .{
            .allocator = self.allocator,
            .content = content_copy,
            .tool_calls = tool_calls,
            .finish_reason = finish_reason,
            .reasoning_content = reasoning_content_copy,
            .usage = usage,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.httpClient.deinit();
    }

    pub const INTENT_JUDGE_SYSTEM =
        \\You are an intent classifier for an AI agent loop.
        \\
        \\Your job is to determine if an assistant message contains UNRESOLVED intent —
        \\meaning the assistant described or planned an action but did NOT actually perform it.
        \\
        \\UNRESOLVED intent examples (answer YES):
        \\- "Let me check the file..." (but no tool was called)
        \\- "Now I'll verify the backend can start..."
        \\- "I need to run the tests first"
        \\- "Let me look at the directory structure"
        \\- "I should verify this works"
        \\- "Next, I will install the dependencies"
        \\- "Good, all the files are in place. Now let me check..."
        \\
        \\RESOLVED intent examples (answer NO):
        \\- The assistant summarized results of something already done
        \\- The assistant asked the user a question
        \\- The assistant explained a concept or gave instructions
        \\- The assistant said the task is complete
        \\- The assistant listed what was accomplished
        \\
        \\Answer ONLY with YES or NO. No explanation.
    ;

    pub fn hasUnresolvedIntent(self: *Agent, assistant_message: []const u8) !bool {
        const user_content = try std.fmt.allocPrint(self.allocator,
            \\Assistant message to classify:
            \\
            \\<message>
            \\{s}
            \\</message>
            \\
            \\Does this message contain unresolved intent (planned but not yet executed action)?
            \\Answer YES or NO only.
        , .{assistant_message});
        defer self.allocator.free(user_content);

        const messages = &.{
            AgentMessage{ .role = .system, .content = Agent.INTENT_JUDGE_SYSTEM },
            AgentMessage{ .role = .user, .content = user_content },
        };

        const call_response = try self.call(.{
            .tools = &.{},
            .messages = messages,
            .temperature = 0.0,
        });
        defer call_response.deinit();

        const answer = call_response.content orelse "";
        var upper = try self.allocator.alloc(u8, answer.len);
        for (answer, 0..) |c, i| {
            upper[i] = std.ascii.toUpper(c);
        }

        return std.mem.startsWith(u8, upper, "YES");
    }
};
