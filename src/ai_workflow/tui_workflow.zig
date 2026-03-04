const logger = @import("../modules/logger/logger.zig");
const std = @import("std");
const json = std.json;
const tree1_mod = @import("tree1");
const agent = tree1_mod.agent;
const prompt = tree1_mod.prompt;
const context = @import("models.zig").ContextIPCTui;
const sqlite = tree1_mod.sqlite;
const bash_tool = tree1_mod.bash_tool;
const tool_models = tree1_mod.tool_models;
const change_agent_tool = tree1_mod.change_agent_tool;
const loop_detector = tree1_mod.loop_detector;

/// Compaction configuration constants
const COMPACTION_CONFIG = struct {
    pub const target_body_size: usize = 50 * 1024; // 50KB target
    pub const max_body_size: usize = 700 * 1024; // 150kb threshold to trigger
};

pub const TUIHistory = struct {
    id: []const u8,
    session_id: []const u8,
    model: []const u8,
    created: []const u8,
    response_content: []const u8,
    finish_reason: []const u8,
    role: []const u8,
    tools: []const u8,
    reasoning_content: ?[]const u8 = null,
    agent: []const u8 = "GeneralAgent",

    pub fn deinit(self: *TUIHistory, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.model);
        allocator.free(self.created);
        allocator.free(self.response_content);
        allocator.free(self.finish_reason);
        allocator.free(self.role);
        allocator.free(self.tools);
        if (self.reasoning_content) |rc| allocator.free(rc);
        allocator.free(self.agent);
    }
};

pub const SessionInfo = struct {
    session_id: []const u8,
    session_dir: []const u8,
    created: []const u8,

    pub fn deinit(self: *SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_dir);
        allocator.free(self.created);
    }
};

/// Context for streaming callbacks
pub const StreamingContext = struct {
    workflow: *TUIWorkflow,
    chunk_index: usize = 0,
};

/// Callback for streaming chunks - sends each chunk to the client
pub fn streamCallback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    const stream_ctx = @as(?*StreamingContext, @ptrCast(@alignCast(ctx))) orelse return;
    const workflow = stream_ctx.workflow;

    if (chunk.done) {
        // Send final chunk with finish reason and usage
        workflow.sendStreamChunkFinal(stream_ctx.chunk_index, chunk.finish_reason, chunk.usage);
        return;
    }

    // Send content chunk
    if (chunk.content) |content| {
        workflow.sendStreamChunkContent(stream_ctx.chunk_index, content);
        stream_ctx.chunk_index += 1;
    }

    // Send reasoning content chunk
    if (chunk.reasoning_content) |rc| {
        workflow.sendStreamChunkReasoning(stream_ctx.chunk_index, rc);
        stream_ctx.chunk_index += 1;
    }

    // Handle tool calls delta - we'll aggregate these
    if (chunk.tool_calls_delta) |deltas| {
        workflow.sendStreamChunkToolCallDelta(stream_ctx.chunk_index, deltas);
        stream_ctx.chunk_index += 1;
    }
}

pub const TUIWorkflow = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger.Logger,

    session_id: []const u8 = "",

    message: []const u8 = "",

    // current working directory
    cwd: []const u8 = "",

    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",

    conn_fd: std.posix.fd_t = -1,

    loop_detector: loop_detector.LoopDetector = .{},

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !TUIWorkflow {
        const log_ptr = try allocator.create(logger.Logger);
        log_ptr.* = logger.Logger.initColor(allocator, .{ .min_level = .debug });
        return .{
            .allocator = allocator,
            .db = db,
            .logger = log_ptr,
            .session_id = "",
            .message = "",
            .cwd = "",
            .api_key = "",
            .model = "",
            .base_url = "",
            .conn_fd = -1,
        };
    }

    pub fn deinit(self: *TUIWorkflow) void {
        self.logger.deinit();
        self.allocator.destroy(self.logger);
    }

    /// Get the current agent from the last message in the database.
    /// Returns "GeneralAgent" if no messages exist for this session.
    pub fn getCurrentAgent(self: *TUIWorkflow) ![]const u8 {
        const sql = "SELECT COALESCE(agent, 'GeneralAgent') FROM llm_history WHERE session_id = ? ORDER BY created DESC LIMIT 1";
        var rows = try self.db.query(self.allocator, sql, &.{self.session_id});
        defer rows.deinit();

        if (try rows.next()) |row| {
            return try self.allocator.dupe(u8, row.values[0]);
        } else {
            return try self.allocator.dupe(u8, "GeneralAgent");
        }
    }

    pub fn sendResponse(self: *TUIWorkflow, response: agent.Agent.CallResponse, override_finish_reason: ?[]const u8) void {
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

        self.logger.infoFmt("SEND RESPONSE XML: {s}", .{buf.items}) catch {};

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                self.logger.errFmt("Send Response error {s}", .{@errorName(err)}) catch {};
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    fn sendToolResult(self: *TUIWorkflow, result: []const u8, tool_call_id: []const u8, tool_name: []const u8) void {
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

        w.writeAll("</result></tool_result></response>") catch return;

        self.logger.traceFmt("SEND TOOL RESULT XML: {s}", .{buf.items}) catch {};

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                self.logger.errFmt("Send Tool Result error {s}", .{@errorName(err)}) catch {};
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    pub fn sendError(self: *TUIWorkflow, err_msg: []const u8, finish_reason: ?[]const u8) void {
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

        self.logger.traceFmt("SEND ERROR XML: {s}", .{buf.items}) catch {};

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                self.logger.errFmt("Send Error response error {s}", .{@errorName(err)}) catch {};
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    pub fn sendSessionsResponse(self: *TUIWorkflow, sessions: []SessionInfo) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.writeAll("<response><type>sessions</type><sessions>") catch return;
        for (sessions) |session| {
            w.writeAll("<session><id>") catch return;
            w.writeAll(session.session_id) catch return;
            w.writeAll("</id><dir>") catch return;
            w.writeAll(session.session_dir) catch return;
            w.writeAll("</dir><created>") catch return;
            w.writeAll(session.created) catch return;
            w.writeAll("</created></session>") catch return;
        }
        w.writeAll("</sessions></response>") catch return;

        self.logger.traceFmt("SEND SESSIONS XML: {s}", .{buf.items}) catch {};

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                self.logger.errFmt("Send Sessions response error {s}", .{@errorName(err)}) catch {};
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    pub fn sendUserChoice(self: *TUIWorkflow) !void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.writeAll("<response><finish_reason>user_choice</finish_reason>") catch return;
        w.writeAll("</response>") catch return;

        self.logger.traceFmt("SEND SESSIONS XML: {s}", .{buf.items}) catch {};

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                self.logger.errFmt("Send Sessions response error {s}", .{@errorName(err)}) catch {};
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    /// Send a streaming content chunk
    fn sendStreamChunkContent(self: *TUIWorkflow, index: usize, content: []const u8) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.print("<response><chunk index=\"{}\"><content>", .{index}) catch return;
        w.writeAll(content) catch return;
        w.writeAll("</content></chunk></response>") catch return;

        _ = std.posix.write(self.conn_fd, buf.items) catch {};
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    /// Send a streaming reasoning content chunk
    fn sendStreamChunkReasoning(self: *TUIWorkflow, index: usize, reasoning: []const u8) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.print("<response><chunk index=\"{}\"><reasoning_content>", .{index}) catch return;
        w.writeAll(reasoning) catch return;
        w.writeAll("</reasoning_content></chunk></response>") catch return;

        _ = std.posix.write(self.conn_fd, buf.items) catch {};
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    /// Send a streaming tool call delta chunk
    fn sendStreamChunkToolCallDelta(self: *TUIWorkflow, index: usize, deltas: []const agent.ToolCallDelta) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.print("<response><chunk index=\"{}\"><tool_calls_delta>", .{index}) catch return;
        for (deltas) |delta| {
            w.print("<delta index=\"{}\">", .{delta.index}) catch return;
            if (delta.id) |id| {
                w.print("<id>{s}</id>", .{id}) catch return;
            }
            if (delta.function_name) |name| {
                w.print("<function_name>{s}</function_name>", .{name}) catch return;
            }
            if (delta.function_arguments) |args| {
                w.print("<function_arguments>{s}</function_arguments>", .{args}) catch return;
            }
            w.writeAll("</delta>") catch return;
        }
        w.writeAll("</tool_calls_delta></chunk></response>") catch return;

        _ = std.posix.write(self.conn_fd, buf.items) catch {};
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    /// Send the final streaming chunk with usage info (finish_reason is sent by sendResponse)
    fn sendStreamChunkFinal(self: *TUIWorkflow, index: usize, finish_reason: ?agent.FinishReason, usage: ?agent.Usage) void {
        _ = finish_reason; // unused - finish_reason comes from sendResponse
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);

        w.print("<response><chunk index=\"{}\" final=\"true\">", .{index}) catch return;
        // Removed: <finish_reason> - this is sent by sendResponse() as the terminal signal
        if (usage) |u| {
            w.print("<usage><prompt_tokens>{}</prompt_tokens><completion_tokens>{}</completion_tokens><total_tokens>{}</total_tokens></usage>", .{ u.prompt_tokens, u.completion_tokens, u.total_tokens }) catch return;
        }
        w.writeAll("</chunk></response>") catch return;

        _ = std.posix.write(self.conn_fd, buf.items) catch {};
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }

    pub fn buildMessages(self: *TUIWorkflow) ![]agent.AgentMessage {
        const historyMessages = try self.getMessages();
        defer {
            for (historyMessages) |*hist| {
                hist.deinit(self.allocator);
            }
            self.allocator.free(historyMessages);
        }

        // Determine the agent to use from the latest message in history
        var agent_to_use: []const u8 = "GeneralAgent";
        if (historyMessages.len > 0) {
            // Get the agent from the last message
            const last_msg = historyMessages[historyMessages.len - 1];
            agent_to_use = last_msg.agent;
        }

        // Get the appropriate prompt for the agent
        const agent_prompt: []const u8 = if (std.mem.eql(u8, agent_to_use, "GeneralAgent"))
            prompt.GeneralAgent
        else if (std.mem.eql(u8, agent_to_use, "ExplorationAgent"))
            prompt.ExplorationAgent
        else if (std.mem.eql(u8, agent_to_use, "PlanningAgent"))
            prompt.PlanningAgent
        else if (std.mem.eql(u8, agent_to_use, "ExecutingAgent"))
            prompt.ExecutingAgent
        else if (std.mem.eql(u8, agent_to_use, "KnowledgeAgent"))
            prompt.KnowledgeAgent
        else
            prompt.GeneralAgent;

        const systemContent = try prompt.agenticCodingWithCwd(self.allocator, self.cwd, agent_prompt);

        const systemMessage = agent.AgentMessage{
            .role = .system,
            .content = systemContent,
        };

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

    pub fn run(self: *TUIWorkflow) void {
        self.runInternal() catch |err| {
            const err_msg = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch return;
            defer self.allocator.free(err_msg);
            self.sendError(err_msg, "user_choice");
        };
    }

    fn runInternal(self: *TUIWorkflow) !void {
        const current_agent = try self.getCurrentAgent();
        defer self.allocator.free(current_agent);
        self.saveMessageUnified(self.message, null, "user", "null", null, null, current_agent) catch |err| {
            self.logger.errFmt("saveMessageAsUser error: {s}", .{@errorName(err)}) catch {};
        };

        // Use ArrayList for dynamic message appending during tool execution
        var messages_list: std.ArrayList(agent.AgentMessage) = .empty;
        const initial_messages = try self.buildMessages();
        try messages_list.appendSlice(self.allocator, initial_messages);

        const tools: []const tool_models.AgentTool = &.{ bash_tool.bashTool, change_agent_tool.ChangeAgentTool };

        var retryCount: usize = 0;
        var agent_temperature: f32 = 0.2;
        var isThinking: bool = false;
        var current_max_tokens: usize = 2000;
        while (true) {
            if (retryCount > 10) return error.TooManyRetries;

            const body_size = self.estimateBodySize(messages_list.items);
            self.logger.debugFmt("[COMPACTION] Body size: {} bytes", .{body_size}) catch {};

            if (body_size > COMPACTION_CONFIG.max_body_size) {
                self.logger.debugFmt("[COMPACTION] Threshold exceeded, triggering compaction", .{}) catch {};

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                if (try self.callCompactionAgent(messages_list.items, arena.allocator())) |compacted_xml| {
                    try self.compactMessagesInMemory(&messages_list, compacted_xml);
                }
            }

            var arena_allocator_agent = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_allocator_agent.deinit();
            const allocator_agent = arena_allocator_agent.allocator();
            var dynamic_agent = try agent.Agent.init(allocator_agent, self.logger);
            defer dynamic_agent.deinit();
            dynamic_agent.apiKey = self.api_key;
            dynamic_agent.model = self.model;
            dynamic_agent.baseUrl = self.base_url;
            const dynamic_agent_params = agent.AgentCall{ .tools = tools, .messages = messages_list.items, .temperature = agent_temperature, .max_tokens = current_max_tokens };
            dynamic_agent.thinkingEnabled = isThinking;
            dynamic_agent.httpOptions.read_timeout_ms = 600_000; // 10 minutes
            var stream_ctx = StreamingContext{
                .workflow = self,
                .chunk_index = 0,
            };
            const res_dynamic_agent = dynamic_agent.callStreaming(dynamic_agent_params, &stream_ctx, streamCallback) catch |err| {
                retryCount += 1;
                self.logger.errFmt("Error calling agent: {s}", .{@errorName(err)}) catch {};
                self.sendError(@errorName(err), "notification_error");
                continue;
            };
            defer res_dynamic_agent.deinit();
            retryCount = 0;

            if (res_dynamic_agent.finish_reason) |finish_reason| {
                if (finish_reason == .stop) {
                    const intent_result = dynamic_agent.hasUnresolvedIntent(messages_list.items) catch |err| blk: {
                        self.logger.errFmt("hasUnresolvedIntent error: {s}", .{@errorName(err)}) catch {};
                        break :blk agent.UnresolvedIntentResult{ .has_unresolved = false, .reason = null };
                    };

                    if (intent_result.has_unresolved) {
                        self.logger.infoFmt("UNRESOLVED INTENT DETECTED - continuing loop", .{}) catch {};
                        if (intent_result.reason) |r| {
                            self.logger.infoFmt("Reason: {s}", .{r}) catch {};
                        }
                        self.sendResponse(res_dynamic_agent, "");
                        const current_agent_2 = try self.getCurrentAgent();
                        defer self.allocator.free(current_agent_2);
                        try self.saveMessageUnified(null, res_dynamic_agent, agent.Role.assistant.toStr(), null, null, null, current_agent_2);

                        const continuation_msg = if (intent_result.reason) |r|
                            try std.fmt.allocPrint(self.allocator, "Please continue: {s}", .{r})
                        else
                            try self.allocator.dupe(u8, "Please continue and execute the action you described.");

                        const user_msg = agent.AgentMessage{
                            .role = .user,
                            .content = continuation_msg,
                        };
                        try messages_list.append(self.allocator, user_msg);
                        retryCount += 1;
                        continue;
                    }

                    self.sendResponse(res_dynamic_agent, "user_choice");
                    const current_agent_3 = try self.getCurrentAgent();
                    defer self.allocator.free(current_agent_3);
                    self.saveMessageUnified(null, res_dynamic_agent, agent.Role.assistant.toStr(), null, null, null, current_agent_3) catch |err| {
                        self.logger.errFmt("saveMessage error: {s}", .{@errorName(err)}) catch {};
                    };

                    // _ = try self.sendUserChoice();
                    self.logger.infoFmt("FINISH REASON STOPPP", .{}) catch {};
                    break;
                } else if (finish_reason == .length) {
                    self.logger.infoFmt("FINISH REASON LENGTH - continuing...", .{}) catch {};
                    current_max_tokens += 1000;
                    self.logger.infoFmt("FINISH REASON LENGTH - increasing max_tokens to {}", .{current_max_tokens}) catch {};
                    continue;
                } else if (finish_reason == .tool_calls) {
                    self.sendResponse(res_dynamic_agent, null);
                    self.logger.infoFmt("FINISH REASON TOOL CALLS - executing tools", .{}) catch {};

                    if (res_dynamic_agent.tool_calls) |tc| {
                        if (tc.len == 0) {
                            self.logger.warnFmt("WARNING: tool_calls array is empty!", .{}) catch {};
                        }
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
                        const reasoningContent: ?[]u8 = if (res_dynamic_agent.reasoning_content) |rc|
                            try self.allocator.dupe(u8, rc)
                        else
                            null;

                        const contentNormal: ?[]u8 = if (res_dynamic_agent.content) |c|
                            try self.allocator.dupe(u8, c)
                        else
                            null;

                        const mergedContent: ?[]u8 = if (reasoningContent != null or contentNormal != null) blk: {
                            const r = reasoningContent orelse "";
                            const c = contentNormal orelse "";
                            break :blk try std.mem.concat(self.allocator, u8, &.{ r, c });
                        } else null;

                        // ALWAYS add assistant message with tool_calls - required by API
                        // even if there's no content
                        const assistant_msg = agent.AgentMessage{
                            .role = .assistant,
                            .content = mergedContent,
                            .tool_calls = assistant_tool_calls,
                        };

                        try messages_list.append(self.allocator, assistant_msg);

                        const current_agent_4 = try self.getCurrentAgent();
                        defer self.allocator.free(current_agent_4);
                        self.saveMessageUnified(null, res_dynamic_agent, agent.Role.assistant.toStr(), null, assistant_tool_calls, null, current_agent_4) catch |err| {
                            self.logger.errFmt("saveMessage error: {s}", .{@errorName(err)}) catch {};
                        };

                        // Execute each tool call and add tool result messages
                        for (tc) |tool_call| {
                            self.logger.debugFmt("Executing tool: {s}   {s}", .{ tool_call.function.name, tool_call.function.arguments }) catch {};

                            if (self.loop_detector.check(tool_call.function.arguments)) {
                                const warning = try std.fmt.allocPrint(
                                    self.allocator,
                                    "WARNING: Identical command repeated: {s}\n" ++
                                        "Empty output means no results found — do NOT retry. Proceed with what you know.",
                                    .{tool_call.function.arguments},
                                );
                                const tool_result_msg = agent.AgentMessage{
                                    .role = .tool,
                                    .content = warning,
                                    .tool_call_id = try self.allocator.dupe(u8, tool_call.id),
                                };
                                try messages_list.append(self.allocator, tool_result_msg);
                                continue;
                            }

                            if (std.mem.eql(u8, tool_call.function.name, "change_agent_tool")) {
                                const parsed = try std.json.parseFromSlice(
                                    change_agent_tool.ChangeAgentToolResult,
                                    self.allocator,
                                    tool_call.function.arguments,
                                    .{},
                                );
                                defer parsed.deinit();

                                const agent_name = parsed.value.agent;
                                const agent_message = parsed.value.message;
                                const new_agent_temperature = parsed.value.temperature;
                                if (new_agent_temperature) |temperature| {
                                    agent_temperature = temperature;
                                }

                                const new_is_thinking = parsed.value.is_thinking;
                                if (new_is_thinking) |thinking| {
                                    isThinking = thinking;
                                }

                                var agent_prompt: []const u8 = if (std.mem.eql(u8, agent_name, "GeneralAgent"))
                                    prompt.GeneralAgent
                                else if (std.mem.eql(u8, agent_name, "ExplorationAgent"))
                                    prompt.ExplorationAgent
                                else if (std.mem.eql(u8, agent_name, "PlanningAgent"))
                                    prompt.PlanningAgent
                                else if (std.mem.eql(u8, agent_name, "ExecutingAgent"))
                                    prompt.ExecutingAgent
                                else if (std.mem.eql(u8, agent_name, "KnowledgeAgent"))
                                    prompt.KnowledgeAgent
                                else if (std.mem.eql(u8, agent_name, "ReviewAgent"))
                                    prompt.ReviewAgent
                                else {
                                    self.logger.warnFmt("change_agent_tool: unknown agent '{s}'", .{agent_name}) catch {};
                                    continue;
                                };

                                agent_prompt = prompt.agenticCodingWithCwd(self.allocator, self.cwd, agent_prompt) catch |err| {
                                    self.logger.errFmt("Failed to format agent prompt: {s}", .{@errorName(err)}) catch {};
                                    continue;
                                };

                                const msgPrompt = try std.fmt.allocPrint(
                                    self.allocator,
                                    "{s}\n\n{s}",
                                    .{ agent_prompt, agent_message },
                                );

                                const contentChangeAgent = try std.fmt.allocPrint(
                                    self.allocator,
                                    "<change_agent_tool>\n{s}\n<change_agent_tool>",
                                    .{tool_call.function.arguments},
                                );

                                // 1. Create tool result message and add to messages_list (required for API)
                                const tool_result_msg = agent.AgentMessage{
                                    .role = .tool,
                                    .content = contentChangeAgent,
                                    .tool_call_id = try self.allocator.dupe(u8, tool_call.id),
                                };
                                try messages_list.append(self.allocator, tool_result_msg);

                                // 2. Save tool result to database
                                const current_agent_5 = agent_name;
                                defer self.allocator.free(current_agent_5);
                                self.saveMessageUnified(contentChangeAgent, null, "tool", "tool", null, tool_call.id, current_agent_5) catch |err| {
                                    self.logger.errFmt("saveMessageAsTool error: {s}", .{@errorName(err)}) catch {};
                                };
                                self.sendToolResult(contentChangeAgent, tool_call.id, tool_call.function.name);

                                // 3. Replace system message only, keep all history
                                var system_replaced = false;
                                for (messages_list.items) |*msg| {
                                    if (msg.role == .system) {
                                        msg.content = msgPrompt;
                                        system_replaced = true;
                                        break;
                                    }
                                }
                                if (!system_replaced) {
                                    try messages_list.insert(self.allocator, 0, agent.AgentMessage{
                                        .role = .system,
                                        .content = msgPrompt,
                                    });
                                }

                                self.logger.infoFmt("Switched to agent: {s}", .{agent_name}) catch {};
                            }

                            if (std.mem.eql(u8, tool_call.function.name, "bash")) {

                                // Parse arguments JSON to BashInput
                                const parsed = std.json.parseFromSlice(
                                    tool_models.BashInput,
                                    self.allocator,
                                    tool_call.function.arguments,
                                    .{ .allocate = .alloc_always },
                                ) catch |err| {
                                    self.logger.errFmt("Failed to parse tool arguments: {s}", .{@errorName(err)}) catch {};
                                    continue;
                                };
                                defer parsed.deinit();

                                const res_bash = bash_tool.executeBash(self.allocator, parsed.value) catch |err| blk: {
                                    self.logger.errFmt("Error executing bash: {s}", .{@errorName(err)}) catch {};
                                    break :blk "Error executing command";
                                };
                                self.logger.debugFmt("RESPONSE TOOLS: {s}", .{res_bash}) catch |err| {
                                    self.logger.errFmt("RESPONSE TOOLS error: {s}", .{@errorName(err)}) catch {};
                                };

                                const tool_result_msg = agent.AgentMessage{
                                    .role = .tool,
                                    .content = res_bash,
                                    .tool_call_id = try self.allocator.dupe(u8, tool_call.id),
                                };
                                try messages_list.append(self.allocator, tool_result_msg);
                                const current_agent_6 = try self.getCurrentAgent();
                                defer self.allocator.free(current_agent_6);
                                try self.saveMessageUnified(res_bash, null, "tool", "tool", null, tool_call.id, current_agent_6);
                                self.sendToolResult(res_bash, tool_call.id, tool_call.function.name);
                                self.logger.debugFmt("Tool result added to messages", .{}) catch {};
                            }
                        }
                        self.logger.debugFmt("All tools executed, continuing to next LLM call. Message count: {}", .{messages_list.items.len}) catch {};
                    } else {
                        self.logger.warnFmt("Tool function not found", .{}) catch {};
                    }
                    // Continue to next LLM call - no break, loop continues naturally
                    self.logger.debugFmt("Tool calls processing complete, looping back for next API call...", .{}) catch {};
                } else if (finish_reason == .content_filter) {
                    self.logger.infoFmt("FINISH REASON CONTENT FILTER - content was filtered due to safety policies", .{}) catch {};

                    // Save the filtered response to history
                    const current_agent_7 = try self.getCurrentAgent();
                    defer self.allocator.free(current_agent_7);
                    self.saveMessageUnified(null, res_dynamic_agent, agent.Role.assistant.toStr(), null, null, null, current_agent_7) catch |err| {
                        self.logger.errFmt("saveMessage error: {s}", .{@errorName(err)}) catch {};
                    };

                    // Send error response to client with content_filter finish reason
                    // The response content may be empty or contain partial filtered content
                    if (res_dynamic_agent.content) |c| {
                        if (c.len > 0) {
                            // Send the partial content with content_filter finish reason
                            self.sendResponse(res_dynamic_agent, "content_filter");
                        } else {
                            // No content, send error message
                            self.sendError("Content was filtered due to safety policies. Please rephrase your request.", "user_choice");
                        }
                    } else {
                        // No content, send error message
                        self.sendError("Content was filtered due to safety policies. Please rephrase your request.", "user_choice");
                    }
                    break;
                }
            } else {
                retryCount += 1;
                self.logger.errFmt("Error calling agent: maybe streaming failed", .{}) catch {};
                _ = try self.sendUserChoice();
                break;
                // continue;
            }

            retryCount = 0;
        }
    }

    /// Serialize tool_calls array to JSON string
    pub fn serializeToolCalls(self: *TUIWorkflow, tool_calls: []agent.ToolCall) ![]u8 {
        var aw: std.io.Writer.Allocating = .init(self.allocator);
        try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
        return try aw.toOwnedSlice();
    }

    /// Unified method to save messages to llm_history table.
    pub fn saveMessageUnified(
        self: *TUIWorkflow,
        content: ?[]const u8,
        response: ?agent.Agent.CallResponse,
        role: ?[]const u8,
        finish_reason: ?[]const u8,
        tool_calls: ?[]agent.ToolCall,
        tool_call_id: ?[]const u8,
        agent_name: ?[]const u8,
    ) !void {
        const db = self.db;

        const id = try std.fmt.allocPrint(self.allocator, "{}-{}", .{ std.time.timestamp(), std.crypto.random.int(u64) });
        defer self.allocator.free(id);

        const createdStr = try std.fmt.allocPrint(self.allocator, "{}", .{std.time.timestamp()});
        defer self.allocator.free(createdStr);

        var contentStr = content orelse "";
        const finishReasonStr = finish_reason orelse
            (if (response) |r| (if (r.finish_reason) |fr| fr.toStr() else "null") else "null");
        const roleStr = role orelse "assistant";
        const reasoningStr = if (response) |r| (r.reasoning_content orelse "") else "";
        const agentStr = agent_name orelse "GeneralAgent";

        if (response) |r| {
            if (r.content) |c| {
                contentStr = c;
            }
        }

        std.debug.print("saveMessage aa role={s} content={s}", .{ roleStr, contentStr });

        // Determine tool_calls_json: prefer serialized tool_calls, fall back to tool_call_id, then empty string
        var toolCallsJson: []const u8 = "";
        var toolCallsOwned: ?[]u8 = null;
        if (tool_calls) |tc| {
            toolCallsOwned = try self.serializeToolCalls(tc);
            toolCallsJson = toolCallsOwned.?;
        } else if (tool_call_id) |tcid| {
            toolCallsJson = tcid;
        }
        defer if (toolCallsOwned) |tcj| self.allocator.free(tcj);

        const sql = "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)";

        const copy_session_id = try self.allocator.dupe(u8, self.session_id);
        defer self.allocator.free(copy_session_id);
        const copy_model = try self.allocator.dupe(u8, self.model);
        defer self.allocator.free(copy_model);
        const copy_content = try self.allocator.dupe(u8, contentStr);
        defer self.allocator.free(copy_content);
        const copy_finish_reason = try self.allocator.dupe(u8, finishReasonStr);
        defer self.allocator.free(copy_finish_reason);
        const copy_role = try self.allocator.dupe(u8, roleStr);
        defer self.allocator.free(copy_role);
        const copy_tool_calls = try self.allocator.dupe(u8, toolCallsJson);
        defer self.allocator.free(copy_tool_calls);
        const copy_reasoning = try self.allocator.dupe(u8, reasoningStr);
        defer self.allocator.free(copy_reasoning);
        const copy_cwd = try self.allocator.dupe(u8, self.cwd);
        defer self.allocator.free(copy_cwd);
        const copy_agent = try self.allocator.dupe(u8, agentStr);
        defer self.allocator.free(copy_agent);
        const sqlArgs = &.{ id, copy_session_id, copy_model, createdStr, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_reasoning, copy_cwd, copy_agent };

        std.debug.print("saveMessage content={s}", .{contentStr});
        try db.exec(self.allocator, sql, sqlArgs);
    }

    pub fn getMessages(self: *TUIWorkflow) ![]TUIHistory {
        var results: std.ArrayList(TUIHistory) = .empty;

        const sql = "SELECT id, session_id, model, created, response_content, finish_reason, COALESCE(role, 'assistant'), COALESCE(tool_calls_json, ''), COALESCE(reasoning_content, ''), COALESCE(agent, 'GeneralAgent') FROM llm_history WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL) ORDER BY created ASC";
        var rows = try self.db.query(self.allocator, sql, &.{self.session_id});
        defer rows.deinit();

        while (try rows.next()) |row| {
            const history = TUIHistory{
                .id = try self.allocator.dupe(u8, row.values[0]),
                .session_id = try self.allocator.dupe(u8, row.values[1]),
                .model = try self.allocator.dupe(u8, row.values[2]),
                .created = try self.allocator.dupe(u8, row.values[3]),
                .response_content = try self.allocator.dupe(u8, row.values[4]),
                .finish_reason = try self.allocator.dupe(u8, row.values[5]),
                .role = try self.allocator.dupe(u8, row.values[6]),
                .tools = try self.allocator.dupe(u8, row.values[7]),
                .reasoning_content = if (row.values[8].len > 0) try self.allocator.dupe(u8, row.values[8]) else null,
                .agent = try self.allocator.dupe(u8, row.values[9]),
            };
            try results.append(self.allocator, history);
            row.deinit(self.allocator);
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Mark all messages in the current session as not for LLM (soft-delete for compaction)
    pub fn markMessagesNotForLLM(self: *TUIWorkflow) !void {
        const sql = "UPDATE llm_history SET is_feed_to_llm = 0 WHERE session_id = ?";
        try self.db.exec(self.allocator, sql, &.{self.session_id});
    }

    pub fn get_session_by_dir(self: *TUIWorkflow) ![]SessionInfo {
        var results: std.ArrayList(SessionInfo) = .empty;

        const sql = "SELECT session_id, COALESCE(session_dir, '') as session_dir, COALESCE(datetime(CAST(MAX(created) AS INTEGER), 'unixepoch', 'localtime'), MAX(created)) as created FROM llm_history GROUP BY session_id ORDER BY CAST(MAX(created) AS INTEGER) DESC LIMIT 10";
        var rows = try self.db.query(self.allocator, sql, &[_][]const u8{});
        defer rows.deinit();

        while (try rows.next()) |row| {
            const session = SessionInfo{
                .session_id = try self.allocator.dupe(u8, row.values[0]),
                .session_dir = try self.allocator.dupe(u8, row.values[1]),
                .created = try self.allocator.dupe(u8, row.values[2]),
            };
            try results.append(self.allocator, session);
            row.deinit(self.allocator);
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn transformMessageToAgentMessages(self: *TUIWorkflow, message: TUIHistory) ![]agent.AgentMessage {
        var messages: std.ArrayList(agent.AgentMessage) = .empty;

        const role = agent.Role.fromStr(message.role) orelse .assistant;

        // Handle tool result messages (role == "tool")
        // For tool messages, the tools column contains the tool_call_id string directly
        if (role == .tool) {
            const agentMessage = agent.AgentMessage{
                .role = .tool,
                .content = try self.allocator.dupe(u8, message.response_content),
                .tool_call_id = try self.allocator.dupe(u8, message.tools),
            };
            try messages.append(self.allocator, agentMessage);
            return messages.toOwnedSlice(self.allocator);
        }

        // Handle assistant/user/system messages
        const finishReason = agent.FinishReason.fromStr(message.finish_reason);
        const isToolCalls = finishReason == .tool_calls;

        if (message.response_content.len > 0 or isToolCalls) {
            var tool_calls: ?[]agent.ToolCall = null;
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

            const content: ?[]const u8 = if (isToolCalls)
                (if (message.reasoning_content) |rc| try self.allocator.dupe(u8, rc) else null)
            else
                try self.allocator.dupe(u8, message.response_content);

            const reasoning_content: ?[]const u8 = if (message.reasoning_content) |rc| try self.allocator.dupe(u8, rc) else null;

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

    /// Estimate the body size of messages for compaction threshold check
    fn estimateBodySize(self: *TUIWorkflow, messages: []agent.AgentMessage) usize {
        _ = self;
        var total: usize = 0;
        for (messages) |msg| {
            total += 50; // JSON overhead per message
            if (msg.content) |c| total += c.len;
            if (msg.reasoning_content) |rc| total += rc.len;
            if (msg.tool_call_id) |id| total += id.len + 20;
            if (msg.tool_calls) |tcs| {
                for (tcs) |tc| {
                    total += tc.id.len + tc.function.name.len + tc.function.arguments.len + 50;
                }
            }
        }
        return total;
    }

    /// Call CompactionAgent to compress conversation history
    /// Call CompactionAgent to compress conversation history
    fn callCompactionAgent(
        self: *TUIWorkflow,
        messages: []agent.AgentMessage,
        arena: std.mem.Allocator,
    ) !?[]const u8 {
        // Serialize messages as-is for CompactionAgent to reason over
        var history_buf: std.ArrayList(u8) = .empty;
        defer history_buf.deinit(arena);
        var w = history_buf.writer(arena);

        try w.print("Current context size: approximately {} bytes\n\n", .{self.estimateBodySize(messages)});
        try w.writeAll("Conversation history to compact:\n\n");

        for (messages, 0..) |msg, i| {
            if (i == 0) continue; // Skip system prompt

            if (msg.role == .tool) {
                try w.print("--- Message {} (tool_result id:{s}) ---\n", .{ i, msg.tool_call_id orelse "unknown" });
                if (msg.content) |c| try w.writeAll(c);
            } else if (msg.reasoning_content) |rc| {
                try w.print("--- Message {} ({s}) ---\n", .{ i, msg.role.toStr() });
                try w.writeAll("[REASONING]\n");
                try w.writeAll(rc);
                if (msg.content) |c| {
                    try w.writeAll("\n[RESPONSE]\n");
                    try w.writeAll(c);
                }
            } else if (msg.tool_calls) |tcs| {
                try w.print("--- Message {} ({s}) ---\n", .{ i, msg.role.toStr() });
                try w.writeAll("[TOOL CALLS]\n");
                for (tcs) |tc| {
                    try w.print("  - {s}({s})\n", .{ tc.function.name, tc.function.arguments });
                }
            } else if (msg.content) |c| {
                try w.print("--- Message {} ({s}) ---\n", .{ i, msg.role.toStr() });
                try w.writeAll(c);
            }

            try w.writeAll("\n");
        }

        const compaction_messages = try arena.alloc(agent.AgentMessage, 2);
        compaction_messages[0] = .{ .role = .system, .content = prompt.CompactionAgent };
        compaction_messages[1] = .{ .role = .user, .content = try history_buf.toOwnedSlice(arena) };

        var compaction_agent = try agent.Agent.init(arena, self.logger);
        defer compaction_agent.deinit();
        compaction_agent.apiKey = self.api_key;
        compaction_agent.model = self.model;
        compaction_agent.baseUrl = self.base_url;

        const params = agent.AgentCall{
            .tools = &.{},
            .messages = compaction_messages,
            .temperature = 0.0,
            .max_tokens = 8000,
        };

        self.logger.debugFmt("[COMPACTION] Calling CompactionAgent ({} messages, ~{} bytes)", .{
            messages.len,
            self.estimateBodySize(messages),
        }) catch {};

        const response = compaction_agent.call(params) catch |err| {
            self.logger.errFmt("[COMPACTION] Failed: {s}", .{@errorName(err)}) catch {};
            return null;
        };
        defer response.deinit();

        if (response.content) |content| {
            self.logger.debugFmt("[COMPACTION] Done: {} bytes -> {} bytes", .{
                self.estimateBodySize(messages),
                content.len,
            }) catch {};
            return try arena.dupe(u8, content);
        }
        return null;
    }

    /// Compact messages in memory based on CompactionAgent output
    /// Also persists to database: marks old messages as not for LLM, saves new compacted message
    fn compactMessagesInMemory(
        self: *TUIWorkflow,
        messages: *std.ArrayList(agent.AgentMessage),
        compacted_xml: []const u8,
    ) !void {
        const total = messages.items.len;
        if (total <= 4) return;

        // Mark all existing messages in this session as not for LLM (soft-delete)
        try self.markMessagesNotForLLM();

        // Build the compacted summary content
        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(self.allocator);
        var w = summary.writer(self.allocator);
        try w.writeAll("[CONTEXT SUMMARY]\n\n");
        try w.writeAll(compacted_xml);
        const summary_content = try summary.toOwnedSlice(self.allocator);

        // Save the compacted summary to the database with is_feed_to_llm = 1
        const id = try std.fmt.allocPrint(self.allocator, "{}-{}", .{ std.time.timestamp(), std.crypto.random.int(u64) });
        defer self.allocator.free(id);
        const createdStr = try std.fmt.allocPrint(self.allocator, "{}", .{std.time.timestamp()});
        defer self.allocator.free(createdStr);

        const sql = "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)";
        try self.db.exec(self.allocator, sql, &.{ id, self.session_id, self.model, createdStr, summary_content, "stop", "user", "", "", self.cwd, "GeneralAgent" });

        // Build new in-memory message list: system message + compacted summary
        var new_messages: std.ArrayList(agent.AgentMessage) = .empty;

        // Keep system message - duplicate content to be safe
        const system_content = if (messages.items[0].content) |c|
            try self.allocator.dupe(u8, c)
        else
            null;
        try new_messages.append(self.allocator, .{
            .role = .system,
            .content = system_content,
        });

        // Add compacted summary as user message
        try new_messages.append(self.allocator, .{
            .role = .user,
            .content = summary_content,
        });

        // Free ALL old messages (including ones we "kept" - we have copies now)
        for (messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        messages.deinit(self.allocator);
        messages.* = new_messages;

        self.logger.debugFmt("[COMPACTION] Compacted: {} -> {} messages (persisted to DB)", .{ total, messages.items.len }) catch {};
    }
};
