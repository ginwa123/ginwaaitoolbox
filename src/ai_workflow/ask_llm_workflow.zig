const std = @import("std");
const json = std.json;
const agent = @import("../modules/agent/agent.zig");
const prompt = @import("../modules/agent/prompt.zig");
const context = @import("models.zig").ContextIPCTui;
const sqlite = @import("../modules/databases/sqlite/sqlite.zig");

pub const AskLLMHistory = struct {
    id: []const u8,
    session_id: []const u8,
    model: []const u8,
    created: []const u8,
    response_content: []const u8,
    finish_reason: []const u8,
    role: []const u8,
    tools: []const u8,

    pub fn deinit(self: *AskLLMHistory, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.model);
        allocator.free(self.created);
        allocator.free(self.response_content);
        allocator.free(self.finish_reason);
        allocator.free(self.role);
        allocator.free(self.tools);
    }
};

pub const AskLLMWorkflow = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,

    session_id: []const u8 = "",

    message: []const u8 = "",

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

    fn sendResponse(self: *AskLLMWorkflow, response: agent.Agent.CallResponse) void {
        if (self.conn_fd < 0) return;

        var choices = self.allocator.alloc(agent.Choice, 1) catch return;
        defer self.allocator.free(choices);

        choices[0] = agent.Choice{
            .index = 0,
            .message = agent.Message{
                .role = agent.Role.assistant.toStr(),
                .content = response.content,
                .tool_calls = response.tool_calls,
            },
            .finish_reason = response.finish_reason,
        };

        const agentResponse = agent.AgentResponse{
            .choices = choices,
        };

        var message_buffer_out = std.io.Writer.Allocating.init(self.allocator);
        var stringifier = json.Stringify{
            .writer = &message_buffer_out.writer,
            .options = .{},
        };

        stringifier.write(agentResponse) catch {
            message_buffer_out.deinit();
            return;
        };

        const json_slice = message_buffer_out.toOwnedSlice() catch return;
        defer self.allocator.free(json_slice);

        _ = std.posix.write(self.conn_fd, json_slice) catch |err| {
            if (err != error.BrokenPipe) {
                std.debug.print("Send Response error {s}\n", .{@errorName(err)});
            }
        };
    }

    pub fn buildMessages(self: *AskLLMWorkflow) ![]agent.AgentMessage {
        const systemMessage = agent.AgentMessage{
            .role = .system,
            .content = prompt.AgenticCoding,
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

    pub fn run(self: *AskLLMWorkflow) !void {
        self.saveMessageAsUser(self.message) catch |err| std.debug.print("saveMessageAsUser error: {s}\n", .{@errorName(err)});

        const messages = try self.buildMessages();

        var retryCount: usize = 0;
        while (true) {
            if (retryCount > 3) return error.TooManyRetries;
            var agenttt = try agent.Agent.init(self.allocator);
            defer agenttt.deinit();

            agenttt.apiKey = self.api_key;
            agenttt.model = self.model;
            agenttt.baseUrl = self.base_url;

            const agetntCall = agent.AgentCall{
                .tools = &.{},
                .messages = messages,
            };
            const response = agenttt.call(agetntCall) catch |err| {
                retryCount += 1;
                std.debug.print("Error calling agent: {s}\n", .{@errorName(err)});
                continue;
            };
            defer response.deinit();
            // std.debug.print("response: {s}\n", .{response.content.?});

            if (response.finish_reason) |finish_reason| {
                const toolsStr = if (response.tool_calls != null) "[tool_calls]" else "";

                if (finish_reason == .stop) {
                    self.sendResponse(response);
                    self.saveMessage(response, agent.Role.assistant.toStr(), toolsStr) catch |err| std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                    std.debug.print("FINISH REASON STOP", .{});
                    break;
                } else if (finish_reason == .length) { // still not implemented
                    // self.saveMessage(response, agent.Role.assistant.toStr(), toolsStr) catch |err| std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                    std.debug.print("FINISH REASON LENGTH", .{});
                    break;
                } else if (finish_reason == .tool_calls) {
                    self.sendResponse(response);
                    self.saveMessage(response, agent.Role.assistant.toStr(), toolsStr) catch |err| std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                    std.debug.print("FINISH REASON TOOL CALLS", .{});
                    break;
                } else if (finish_reason == .content_filter) {
                    self.saveMessage(response, "assistant", toolsStr) catch |err| std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                    std.debug.print("FINISH REASON CONTENT FILTER", .{});
                    break;
                }
            } else {
                self.saveMessage(response, "assistant", "") catch |err| std.debug.print("saveMessage error: {s}\n", .{@errorName(err)});
                std.debug.print("BREAK LLM", .{});
                break;
            }

            retryCount = 0;
        }
    }

    pub fn saveMessage(self: *AskLLMWorkflow, response: agent.Agent.CallResponse, role: []const u8, tools: []const u8) !void {
        const db = self.db;

        const id = try std.fmt.allocPrint(self.allocator, "{}-{}", .{ std.time.timestamp(), std.crypto.random.int(u64) });
        defer self.allocator.free(id);

        const createdStr = try std.fmt.allocPrint(self.allocator, "{}", .{std.time.timestamp()});
        defer self.allocator.free(createdStr);

        const finishReasonStr = if (response.finish_reason) |fr| fr.toStr() else "null";
        const contentStr = if (response.content) |c| c else "";

        const sql = "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, tool_calls_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
        const sqlArgs = &.{ id, self.session_id, self.model, createdStr, contentStr, finishReasonStr, role, tools };
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

    pub fn getMessages(self: *AskLLMWorkflow) ![]AskLLMHistory {
        var results: std.ArrayList(AskLLMHistory) = .empty;

        const sql = "SELECT id, session_id, model, created, response_content, finish_reason, COALESCE(role, 'assistant'), COALESCE(tool_calls_json, '') FROM llm_history WHERE session_id = ? ORDER BY created ASC";
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

            const content: ?[]const u8 = if (isToolCalls) null else try self.allocator.dupe(u8, message.response_content);

            const role = agent.Role.fromStr(message.role) orelse .assistant;
            const agentMessage = agent.AgentMessage{
                .role = role,
                .content = content,
                .tool_calls = tool_calls,
            };
            try messages.append(self.allocator, agentMessage);
        }

        return messages.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *AskLLMWorkflow) void {
        _ = self;
    }
};
