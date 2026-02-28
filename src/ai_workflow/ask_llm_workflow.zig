const std = @import("std");
const json = std.json;
const agent = @import("../modules/agent/agent.zig");
const prompt = @import("../modules/agent/prompt.zig");
const context = @import("models.zig").ContextIPCTui;
const sqlite = @import("../modules/databases/sqlite/sqlite.zig");
const bash_tool = @import("../modules/agent/tools/bash.zig");
const tool_models = @import("../modules/agent/tools/models.zig");

pub const AskLLMHistory = struct {
    id: []const u8,
    session_id: []const u8,
    model: []const u8,
    created: []const u8,
    response_content: []const u8,
    finish_reason: []const u8,
    role: []const u8,
    tools: []const u8,
    reasoning_content: ?[]const u8 = null,

    pub fn deinit(self: *AskLLMHistory, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.model);
        allocator.free(self.created);
        allocator.free(self.response_content);
        allocator.free(self.finish_reason);
        allocator.free(self.role);
        allocator.free(self.tools);
        if (self.reasoning_content) |rc| allocator.free(rc);
    }
};

pub const AskLLMWorkflow = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,

    session_id: []const u8 = "",

    message: []const u8 = "",

    // current working directory
    cwd: []const u8 = "",

    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",

    conn_fd: std.posix.fd_t = -1,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) AskLLMWorkflow {
        return AskLLMWorkflow{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn sendResponse(self: *AskLLMWorkflow, response: agent.Agent.CallResponse, override_finish_reason: ?[]const u8) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.writeAll("<response><choices><choice><index>0</index><message><role>assistant</role>") catch return;

        if (response.content) |content| {
            w.writeAll("<content>") catch return;
            w.writeAll(content) catch return;
            w.writeAll("</content>") catch return;
        }

        if (response.reasoning_content) |rc| {
            w.writeAll("<reasoning_content>") catch return;
            w.writeAll(rc) catch return;
            w.writeAll("</reasoning_content>") catch return;
        }

        if (response.tool_calls) |tc| {
            w.writeAll("<tool_calls>") catch return;
            for (tc) |tci| {
                w.writeAll("<tool_call id=\"") catch return;
                w.writeAll(tci.id) catch return;
                w.writeAll("\" type=\"function\"><function><name>") catch return;
                w.writeAll(tci.function.name) catch return;
                w.writeAll("</name><arguments>") catch return;
                w.writeAll(tci.function.arguments) catch return;
                w.writeAll("</arguments></function></tool_call>") catch return;
            }
            w.writeAll("</tool_calls>") catch return;
        }

        w.writeAll("</message>") catch return;

        if (override_finish_reason) |fr| {
            if (fr.len > 0) {
                w.writeAll("<finish_reason>") catch return;
                w.writeAll(fr) catch return;
                w.writeAll("</finish_reason>") catch return;
            }
        } else if (response.finish_reason) |fr| {
            w.writeAll("<finish_reason>") catch return;
            w.writeAll(fr.toStr()) catch return;
            w.writeAll("</finish_reason>") catch return;
        }

        // Add usage information
        w.print("<usage><prompt_tokens>{}</prompt_tokens><completion_tokens>{}</completion_tokens><total_tokens>{}</total_tokens></usage>", .{ response.usage.prompt_tokens, response.usage.completion_tokens, response.usage.total_tokens }) catch return;

        w.writeAll("</choice></choices></response>") catch return;

        std.debug.print("SEND RESPONSE XML: {s}\n", .{buf.items});

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                std.debug.print("Send Response error {s}\n", .{@errorName(err)});
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    fn sendToolResult(self: *AskLLMWorkflow, result: []const u8, tool_call_id: []const u8, tool_name: []const u8) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.writeAll("<response><tool_result><tool_call_id>") catch return;
        w.writeAll(tool_call_id) catch return;
        w.writeAll("</tool_call_id><tool_name>") catch return;
        w.writeAll(tool_name) catch return;
        w.writeAll("</tool_name><result>") catch return;

        w.writeAll(result) catch return;

        // const esc = self.escapeXml(result) catch return;
        // defer self.allocator.free(esc);
        // w.writeAll(esc) catch return;

        w.writeAll("</result></tool_result></response>") catch return;

        std.debug.print("SEND TOOL RESULT XML: {s}\n", .{buf.items});

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                std.debug.print("Send Tool Result error {s}\n", .{@errorName(err)});
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    pub fn sendError(self: *AskLLMWorkflow, err_msg: []const u8, finish_reason: ?[]const u8) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.writeAll("<response><error>") catch return;
        w.writeAll(err_msg) catch return;
        w.writeAll("</error><finish_reason>") catch return;
        const fr = finish_reason orelse "stop";
        w.writeAll(fr) catch return;
        w.writeAll("</finish_reason></response>") catch return;

        std.debug.print("SEND ERROR XML: {s}\n", .{buf.items});

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                std.debug.print("Send Error response error {s}\n", .{@errorName(err)});
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    pub fn buildMessages(self: *AskLLMWorkflow) ![]agent.AgentMessage {
        const systemContent = try prompt.agenticCodingWithCwd(self.allocator, self.cwd);

        const systemMessage = agent.AgentMessage{
            .role = .system,
            .content = systemContent,
        };

        const historyMessages = try self.getMessages();
        defer {
            for (historyMessages) |*m| m.deinit(self.allocator);
            self.allocator.free(historyMessages);
        }

        var allMessages: std.ArrayList(agent.AgentMessage) = .empty;
        defer allMessages.deinit(self.allocator);

        try allMessages.append(self.allocator, systemMessage);

        for (historyMessages) |hist| {
            const agentMsgs = try self.transformMessageToAgentMessages(hist);
            for (agentMsgs) |msg| {
                try allMessages.append(self.allocator, msg);
            }
            self.allocator.free(agentMsgs);
        }

        return try allMessages.toOwnedSlice(self.allocator);
    }

    pub fn run(self: *AskLLMWorkflow) void {
        self.runInternal() catch |err| {
            const err_msg = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch return;
            defer self.allocator.free(err_msg);
            self.sendError(err_msg, null);
        };
    }

    fn runInternal(self: *AskLLMWorkflow) !void {
        self.saveMessageAsUser(self.message) catch |err| std.debug.print("saveMessageAsUser error: {s}\n", .{@errorName(err)});

        // Use ArrayList for dynamic message appending during tool execution
        var messages_list: std.ArrayList(agent.AgentMessage) = .empty;
        const initial_messages = try self.buildMessages();
        try messages_list.appendSlice(self.allocator, initial_messages);

        const tools: []const tool_models.AgentTool = &.{bash_tool.bashTool};

        var retryCount: usize = 0;
        while (true) {
            if (retryCount > 10) return error.TooManyRetries;
            var agenttt = try agent.Agent.init(self.allocator);
            defer agenttt.deinit();

            agenttt.apiKey = self.api_key;
            agenttt.model = self.model;
            agenttt.baseUrl = self.base_url;

            const agetntCall = agent.AgentCall{
                .tools = tools,
                .messages = messages_list.items,
            };
            const response = agenttt.call(agetntCall) catch |err| {
                retryCount += 1;
                std.debug.print("Error calling agent: {s}\n", .{@errorName(err)});
                self.sendError("Error calling agent", "retry");
                continue;
            };
            defer response.deinit();
            retryCount = 0;
            // std.debug.print("response: {s}\n", .{response.content.?});

            if (response.finish_reason) |finish_reason| {
                if (finish_reason == .stop) {
                    const content = response.content orelse "";

                    const has_unresolved = agenttt.hasUnresolvedIntent(content) catch false;

                    if (has_unresolved) {
                        std.debug.print("UNRESOLVED INTENT DETECTED - continuing loop\n", .{});
                        self.sendResponse(response, "");
                        try self.saveMessage(response, agent.Role.assistant.toStr(), null);

                        const user_msg = agent.AgentMessage{
                            .role = .user,
                            .content = "Please continue and execute the action you described.",
                        };
                        try messages_list.append(self.allocator, user_msg);
                        retryCount += 1;
                        continue;
                    }

                    self.sendResponse(response, null);
                    self.saveMessage(response, agent.Role.assistant.toStr(), null) catch |err| std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                    std.debug.print("FINISH REASON STOP", .{});
                    break;
                } else if (finish_reason == .length) {
                    std.debug.print("FINISH REASON LENGTH - continuing...\n", .{});

                    // Save partial response to history and send to client
                    self.sendResponse(response, "length");
                    self.saveMessage(response, agent.Role.assistant.toStr(), null) catch |err|
                        std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});

                    // Add assistant message to conversation for context
                    const content_copy = if (response.content) |c|
                        try self.allocator.dupe(u8, c)
                    else
                        null;

                    const assistant_msg = agent.AgentMessage{
                        .role = .assistant,
                        .content = content_copy,
                    };
                    try messages_list.append(self.allocator, assistant_msg);

                    // Add continuation prompt
                    const continue_msg = agent.AgentMessage{
                        .role = .user,
                        .content = "Please continue from where you left off.",
                    };
                    try messages_list.append(self.allocator, continue_msg);
                    continue;
                } else if (finish_reason == .tool_calls) {
                    self.sendResponse(response, null);
                    std.debug.print("FINISH REASON TOOL CALLS - executing tools\n", .{});

                    if (response.tool_calls) |tc| {
                        // Add assistant message with tool_calls to history
                        var assistant_tool_calls = try self.allocator.alloc(agent.ToolCall, tc.len);
                        for (tc, 0..) |tool_call, i| {
                            assistant_tool_calls[i] = .{
                                .id = try self.allocator.dupe(u8, tool_call.id),
                                .function = .{
                                    .name = try self.allocator.dupe(u8, tool_call.function.name),
                                    .arguments = try self.allocator.dupe(u8, tool_call.function.arguments),
                                },
                            };
                        }

                        // Merge reasoning_content into content of the tool call assistant message
                        const reasoningContent: ?[]u8 = if (response.reasoning_content) |rc|
                            try self.allocator.dupe(u8, rc)
                        else
                            null;

                        const contentNormal: ?[]u8 = if (response.content) |c|
                            try self.allocator.dupe(u8, c)
                        else
                            null;

                        const mergedContent: ?[]u8 = if (reasoningContent != null or contentNormal != null) blk: {
                            const r = reasoningContent orelse "";
                            const c = contentNormal orelse "";
                            break :blk try std.mem.concat(self.allocator, u8, &.{ r, c });
                        } else null;

                        if (mergedContent != null and mergedContent.?.len > 0) {
                            const assistant_msg = agent.AgentMessage{
                                .role = .assistant,
                                .content = mergedContent,
                                .tool_calls = assistant_tool_calls,
                            };

                            try messages_list.append(self.allocator, assistant_msg);

                            self.saveMessage(
                                response,
                                agent.Role.assistant.toStr(),
                                assistant_tool_calls,  // Pass actual tool_calls, not marker string
                            ) catch |err| {
                                std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                            };
                        }

                        // Execute each tool call and add tool result messages
                        for (tc) |tool_call| {
                            std.debug.print("Executing tool: {s}\n", .{tool_call.function.name});

                            // Parse arguments JSON to BashInput
                            const parsed = std.json.parseFromSlice(
                                tool_models.BashInput,
                                self.allocator,
                                tool_call.function.arguments,
                                .{ .allocate = .alloc_always },
                            ) catch |err| {
                                std.debug.print("Failed to parse tool arguments: {s}\n", .{@errorName(err)});
                                continue;
                            };
                            defer parsed.deinit();

                            // Execute bash command
                            const result = bash_tool.executeBash(self.allocator, parsed.value) catch |err| blk: {
                                std.debug.print("Error executing bash: {s}\n", .{@errorName(err)});
                                break :blk "Error executing command";
                            };

                            // Create tool result message
                            const tool_result_msg = agent.AgentMessage{
                                .role = .tool,
                                .content = result,
                                .tool_call_id = try self.allocator.dupe(u8, tool_call.id),
                            };
                            try messages_list.append(self.allocator, tool_result_msg);
                            self.saveMessageAsTool(result, tool_call.id) catch |err| std.debug.print("saveMessageAsTool error: {s}\n", .{@errorName(err)});
                            self.sendToolResult(result, tool_call.id, tool_call.function.name);
                            std.debug.print("Tool result added to messages\n", .{});
                        }
                    }
                    continue;
                } else if (finish_reason == .content_filter) {
                    std.debug.print("FINISH REASON CONTENT FILTER - content was filtered due to safety policies\n", .{});

                    // Save the filtered response to history
                    self.saveMessage(response, agent.Role.assistant.toStr(), null) catch |err|
                        std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});

                    // Send error response to client with content_filter finish reason
                    // The response content may be empty or contain partial filtered content
                    if (response.content) |c| {
                        if (c.len > 0) {
                            // Send the partial content with content_filter finish reason
                            self.sendResponse(response, "content_filter");
                        } else {
                            // No content, send error message
                            self.sendError("Content was filtered due to safety policies. Please rephrase your request.", "content_filter");
                        }
                    } else {
                        // No content, send error message
                        self.sendError("Content was filtered due to safety policies. Please rephrase your request.", "content_filter");
                    }
                    break;
                }
            } else {
                self.saveMessage(response, "assistant", null) catch |err| std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                std.debug.print("BREAK LLM", .{});
                break;
            }

            retryCount = 0;
        }
    }

    /// Serialize tool_calls array to JSON string
    fn serializeToolCalls(self: *AskLLMWorkflow, tool_calls: []agent.ToolCall) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        var w = buf.writer(self.allocator);
        try w.writeAll("[");

        for (tool_calls, 0..) |tc, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                \\{{"id":"{s}","function":{{"name":"{s}","arguments":"{s}"}}}}
            , .{ tc.id, tc.function.name, tc.function.arguments });
        }

        try w.writeAll("]");
        return try buf.toOwnedSlice(self.allocator);
    }

    pub fn saveMessage(self: *AskLLMWorkflow, response: agent.Agent.CallResponse, role: []const u8, tool_calls: ?[]agent.ToolCall) !void {
        const db = self.db;

        const id = try std.fmt.allocPrint(self.allocator, "{}-{}", .{ std.time.timestamp(), std.crypto.random.int(u64) });
        defer self.allocator.free(id);

        const createdStr = try std.fmt.allocPrint(self.allocator, "{}", .{std.time.timestamp()});
        defer self.allocator.free(createdStr);

        const finishReasonStr = if (response.finish_reason) |fr| fr.toStr() else "null";
        const contentStr = if (response.content) |c| c else "";
        const reasoningStr = if (response.reasoning_content) |rc| rc else "";

        // Serialize tool_calls to JSON if present
        var toolCallsJson: []const u8 = "";
        var toolCallsOwned: ?[]u8 = null;
        if (tool_calls) |tc| {
            toolCallsOwned = try self.serializeToolCalls(tc);
            toolCallsJson = toolCallsOwned.?;
        }
        defer if (toolCallsOwned) |tcj| self.allocator.free(tcj);

        const sql = "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, tool_calls_json, reasoning_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)";
        const sqlArgs = &.{ id, self.session_id, self.model, createdStr, contentStr, finishReasonStr, role, toolCallsJson, reasoningStr };
        try db.exec(self.allocator, sql, sqlArgs);
    }

    pub fn saveMessageAsUser(self: *AskLLMWorkflow, content: []const u8) !void {
        const db = self.db;

        const id = try std.fmt.allocPrint(self.allocator, "{}-{}", .{ std.time.timestamp(), std.crypto.random.int(u64) });
        defer self.allocator.free(id);

        const createdStr = try std.fmt.allocPrint(self.allocator, "{}", .{std.time.timestamp()});
        defer self.allocator.free(createdStr);

        const sql = "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, tool_calls_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
        const sqlArgs = &.{ id, self.session_id, self.model, createdStr, content, "null", "user", "" };
        try db.exec(self.allocator, sql, sqlArgs);
    }

    pub fn saveMessageAsTool(self: *AskLLMWorkflow, content: []const u8, tool_call_id: []const u8) !void {
        const db = self.db;

        const id = try std.fmt.allocPrint(self.allocator, "{}-{}", .{ std.time.timestamp(), std.crypto.random.int(u64) });
        defer self.allocator.free(id);

        const createdStr = try std.fmt.allocPrint(self.allocator, "{}", .{std.time.timestamp()});
        defer self.allocator.free(createdStr);

        const sql = "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, tool_calls_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
        const sqlArgs = &.{ id, self.session_id, self.model, createdStr, content, "tool", "tool", tool_call_id };
        try db.exec(self.allocator, sql, sqlArgs);
    }

    pub fn getMessages(self: *AskLLMWorkflow) ![]AskLLMHistory {
        var results: std.ArrayList(AskLLMHistory) = .empty;

        const sql = "SELECT id, session_id, model, created, response_content, finish_reason, COALESCE(role, 'assistant'), COALESCE(tool_calls_json, ''), COALESCE(reasoning_content, '') FROM llm_history WHERE session_id = ? ORDER BY created ASC";
        var rows = try self.db.query(self.allocator, sql, &.{self.session_id});
        defer rows.deinit();

        while (try rows.next()) |row| {
            const history = AskLLMHistory{
                .id = try self.allocator.dupe(u8, row.values[0]),
                .session_id = try self.allocator.dupe(u8, row.values[1]),
                .model = try self.allocator.dupe(u8, row.values[2]),
                .created = try self.allocator.dupe(u8, row.values[3]),
                .response_content = try self.allocator.dupe(u8, row.values[4]),
                .finish_reason = try self.allocator.dupe(u8, row.values[5]),
                .role = try self.allocator.dupe(u8, row.values[6]),
                .tools = try self.allocator.dupe(u8, row.values[7]),
                .reasoning_content = if (row.values[8].len > 0) try self.allocator.dupe(u8, row.values[8]) else null,
            };
            try results.append(self.allocator, history);
            row.deinit(self.allocator);
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn transformMessageToAgentMessages(self: *AskLLMWorkflow, message: AskLLMHistory) ![]agent.AgentMessage {
        var messages: std.ArrayList(agent.AgentMessage) = .empty;

        const finishReason = agent.FinishReason.fromStr(message.finish_reason);
        const isToolCalls = finishReason == .tool_calls;

        if (message.response_content.len > 0 or isToolCalls) {
            var tool_calls: ?[]agent.ToolCall = null;
            if (finishReason == .tool_calls) {
                const toolSource = if (message.tools.len > 0) message.tools else message.response_content;
                const tcParsed = json.parseFromSlice(json.Value, self.allocator, toolSource, .{}) catch null;
                if (tcParsed) |tcp| {
                    defer tcp.deinit();
                    if (tcp.value == .array and tcp.value.array.items.len > 0) {
                        var calls = try self.allocator.alloc(agent.ToolCall, tcp.value.array.items.len);
                        for (tcp.value.array.items, 0..) |tc_item, i| {
                            if (tc_item == .object) {
                                const id_raw = if (tc_item.object.get("id")) |id_val| id_val.string else "";
                                const func_obj = if (tc_item.object.get("function")) |f| f.object else null;
                                const name_raw = if (func_obj) |fo| if (fo.get("name")) |n| n.string else "" else "";
                                const args_raw = if (func_obj) |fo| if (fo.get("arguments")) |a| a.string else "" else "";
                                calls[i] = .{
                                    .id = try self.allocator.dupe(u8, id_raw),
                                    .function = .{
                                        .name = try self.allocator.dupe(u8, name_raw),
                                        .arguments = try self.allocator.dupe(u8, args_raw),
                                    },
                                };
                            } else {
                                calls[i] = .{
                                    .id = try self.allocator.dupe(u8, ""),
                                    .function = .{
                                        .name = try self.allocator.dupe(u8, ""),
                                        .arguments = try self.allocator.dupe(u8, ""),
                                    },
                                };
                            }
                        }
                        tool_calls = calls;
                    }
                }
            }

            const content: ?[]const u8 = if (isToolCalls)
                (if (message.reasoning_content) |rc| try self.allocator.dupe(u8, rc) else null)
            else
                try self.allocator.dupe(u8, message.response_content);

            const reasoning_content: ?[]const u8 = if (message.reasoning_content) |rc| try self.allocator.dupe(u8, rc) else null;

            const role = agent.Role.fromStr(message.role) orelse .assistant;

            const agentMessage = agent.AgentMessage{
                .role = role,
                .content = content,
                .tool_calls = tool_calls,
                .reasoning_content = reasoning_content,
            };
            try messages.append(self.allocator, agentMessage);
        }

        return messages.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *AskLLMWorkflow) void {
        _ = self;
    }
};
