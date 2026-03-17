const std = @import("std");
const json = std.json;
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const prompt = root_mod.prompt;
const context = @import("models.zig").ContextIPCTui;
const sqlite = root_mod.sqlite;
const BashTool = root_mod.bash_tool;
const ReadFileTool = root_mod.read_file;
const tool_models = root_mod.tool_models;
const SetAgentProperties = root_mod.set_agent_properties;
const ListSkillsTool = root_mod.list_skills_tool;
const GetSkillTool = root_mod.get_skill_tool;
const RemoveSkillTool = root_mod.remove_skill_tool;
const skills = root_mod.skills;
const loop_detector = root_mod.loop_detector;
const bash_helper = root_mod.helperTool;
const get_tree_dir = @import("get_tree_dir.zig");
const logger_mod = root_mod.logger;
const GetCurrentAgentBySessionId = @import("get_current_agent_by_session_id.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_message = @import("transform_llm_history_to_agent_messages.zig");
const send_tool_result = @import("send_tool_result.zig");
const SendUserChoice = @import("send_user_choice.zig").SendUserChoice;
const SendResponse = @import("send_response.zig").SendResponse;
const send_error = @import("send_error.zig");
const SaveMessage = @import("save_message.zig").SaveMessage;
const BuildMessages = @import("build_messages_for_agent_prompt.zig").BuildMessages;
const GetMessages = @import("get_messages.zig").GetMessages;
const mark_messages_not_for_llm = @import("mark_message_not_for_llm.zig");
const send_stream_chunk_final = @import("send_stream_chunk_final.zig");
const send_steam_chunk_content = @import("send_stream_chunk_content.zig");
const send_stream_chunk_reasoning = @import("send_stream_chunk_reasoning.zig");
const send_stream_to_chunk_tool_call_delta = @import("send_stream_to_chunk_tool_call_delta.zig");
const handle_set_agent_properties = @import("handle_set_agent_properties.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const BuildMemoryForAgent = @import("build_memory_for_agent_prompt.zig").BuildMemoryForAgent;
const WriteFileTool = root_mod.write_file;
const SearchTool = root_mod.search_tool;
const TextReplaceTool = root_mod.text_replace_tool;

const handle_content_filter = @import("handle_content_filter.zig");
const BuildSkillContent = @import("build_skill_for_agent_prompt.zig").BuildSkillContent;
const BuildDynamicAgentContent = @import("build_dynamic_agent_for_agent_prompt.zig").BuildDynamicAgentContent;
const BuildBackgroundProcessContent = @import("build_background_process_for_agent_prompt.zig").BuildBackgroundProcessPrompt;
const save_skill_mod = @import("save_skill.zig");
const send_skill_mod = @import("send_skill.zig");
const buildMcpTools = @import("build_messages_tools_mcp_for_agent_prompt.zig");
const config_mod = @import("../../modules/config/config.zig");
pub const cancellation_registry = root_mod.session.cancellation_registry;
const HandleTool = @import("handle_tool.zig").HandleTool;
const SpawnSubAgentTool = @import("../../modules/agent/tools/spawn_sub_agent.zig");
const AllAgentTools = @import("all_agent_tools.zig").AllAgentTools;
/// Compaction configuration constants
const COMPACTION_CONFIG = struct {
    pub const target_body_size: usize = 50 * 1024; // 50KB target
    pub const max_body_size: usize = 700 * 1024; // 150kb threshold to trigger
};

pub const SessionInfo = struct {
    session_id: []const u8,
    session_dir: []const u8,
    created_at: []const u8,

    pub fn deinit(self: *SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_dir);
        allocator.free(self.created_at);
    }
};

pub const StreamingContext = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8 = "",
    chunk_index: usize = 0,
};

/// Callback for streaming chunks - sends each chunk to the client
pub fn stream_callback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    const stream_ctx = @as(?*StreamingContext, @ptrCast(@alignCast(ctx))) orelse return;
    const allocator = stream_ctx.allocator;
    const session_id = stream_ctx.session_id;

    // Send final chunk with usage when done
    if (chunk.done) {
        send_stream_chunk_final.run(allocator, session_id, stream_ctx.chunk_index, chunk.usage);
        return;
    }

    // Send content chunk
    if (chunk.content) |content| {
        send_steam_chunk_content.run(allocator, session_id, stream_ctx.chunk_index, content);
        stream_ctx.chunk_index += 1;
    }

    // Send reasoning content chunk
    if (chunk.reasoning_content) |rc| {
        send_stream_chunk_reasoning.run(allocator, session_id, stream_ctx.chunk_index, rc);
        stream_ctx.chunk_index += 1;
    }

    // we disable tool calls delta for now
    // Handle tool calls delta - we'll aggregate these
    // if (chunk.tool_calls_delta) |deltas| {
    //     send_stream_to_chunk_tool_call_delta.run(allocator, session_id, stream_ctx.chunk_index, deltas);
    //     stream_ctx.chunk_index += 1;
    // }
}
pub const TUIWorkflow = struct {
    // allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,

    loop_detector: loop_detector.LoopDetector = .{},

    pub fn init(db: *sqlite.SqliteBackend, logger: *logger_mod.Logger) TUIWorkflow {
        return .{
            .db = db,
            .logger = logger,
        };
    }

    pub fn run(self: *TUIWorkflow, allocator: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd: []const u8, api_key: []const u8, model: []const u8, base_url: []const u8, config: *const config_mod.LlmConfig) void {
        self.runInternal(allocator, session_id, message, cwd, api_key, model, base_url, config) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch return;
            send_error.run(allocator, session_id, self.logger, err_msg, "user_choice");
        };
    }

    fn runInternal(self: *TUIWorkflow, parent_allocator: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd: []const u8, api_key: []const u8, model: []const u8, base_url: []const u8, config: *const config_mod.LlmConfig) !void {
        defer {
            if (cancellation_registry.getGlobalRegistry()) |registry| {
                registry.unregister(session_id);
            }
        }
        // Register this session for cancellation tracking
        if (cancellation_registry.getGlobalRegistry()) |registry| {
            try registry.register(session_id);
        }

        const session_name = message;
        const initial_agent_state = try GetCurrentAgentBySessionId.run(
            parent_allocator,
            self.db,
            session_id,
        );
        const initial_agent = initial_agent_state.agent;

        SaveMessage(parent_allocator, self.db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = message,
            .response_content = null,
            .response_finish_reason = null,
            .response_reasoning_content = null,
            .role = agent.Role.user.toStr(),
            .finish_reason = "null",
            .tool_calls = null,
            .tool_call_id = null,
            .agent_name = initial_agent,
            .session_name = session_name,
            .loop_index = 0,
            .temperature = initial_agent_state.temperature,
            .is_thinking = initial_agent_state.is_thinking,
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .total_tokens = 0,
        }) catch |err| {
            self.logger.errFmt("saveMessageAsUser error: {s}", .{@errorName(err)}) catch {};
        };

        var retryCount: usize = 0;
        var current_max_tokens: usize = 8000;
        var loopCounter: u32 = 0;
        const base_tools: []const tool_models.AgentTool = AllAgentTools;

        while (true) {
            if (cancellation_registry.getGlobalRegistry()) |registry| {
                if (registry.isCancelled(session_id)) {
                    self.logger.infoFmt("WORKFLOW CANCELLED: session_id={s}", .{session_id}) catch {};
                    break;
                }
            }

            var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(parent_allocator);
            defer arenaAllocatorWhileLoop.deinit();
            const allocator = arenaAllocatorWhileLoop.allocator();

            loopCounter += 1;
            if (retryCount > 10) return error.TooManyRetries;

            // Fetch current agent fresh from DB each iteration
            const currentAgentState = try GetCurrentAgentBySessionId.run(
                allocator,
                self.db,
                session_id,
            );
            const current_agent = currentAgentState.agent;
            var agent_temperature = currentAgentState.temperature;
            var isThinking = currentAgentState.is_thinking;

            var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;

            const initialMessages = try BuildMessages(allocator, cwd, try GetMessages(allocator, self.db, session_id), try BuildSkillContent(allocator, self.db, session_id), try BuildMemoryForAgent(allocator, cwd), try BuildBackgroundProcessContent(allocator, self.db, session_id), try BuildDynamicAgentContent(allocator, self.db, session_id));

            try messagesLists.appendSlice(allocator, initialMessages);

            const body_size = self.estimateBodySize(messagesLists.items);
            self.logger.debugFmt("[COMPACTION] Body size: {} bytes", .{body_size}) catch {};
            if (body_size > COMPACTION_CONFIG.max_body_size) {
                self.logger.debugFmt("[COMPACTION] Threshold exceeded, triggering compaction", .{}) catch {};
                if (try self.callCompactAgent(messagesLists.items, allocator, api_key, model, base_url)) |compacted_xml| {
                    try self.compactMessagesInMemory(allocator, &messagesLists, compacted_xml, session_id, model, cwd);
                }
            }

            const resDynmicAgent = self.callDynamicAgent(allocator, &messagesLists, agent_temperature, current_max_tokens, isThinking, api_key, model, base_url, session_id, config, base_tools) catch |err| {
                if (err == error.Cancelled) {
                    self.logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{session_id}) catch {};
                    break;
                }
                retryCount += 1;
                self.logger.errFmt("Error calling dynamic agent: {s} now retrying", .{@errorName(err)}) catch {};
                continue;
            };

            retryCount = 0;

            if (resDynmicAgent.finish_reason) |finish_reason| {
                self.logger.infoFmt("WORKFLOW: finish_reason = {s}", .{finish_reason.toStr()}) catch {};
                if (finish_reason == .stop) {
                    self.logger.infoFmt("FINISH REASON STOP - calling send_response", .{}) catch {};
                    _ = SendResponse(allocator, session_id, self.logger, resDynmicAgent, "user_choice");
                    _ = try SaveMessage(allocator, self.db, .{
                        .session_id = session_id,
                        .model = model,
                        .cwd = cwd,
                        .content = null,
                        .response_content = resDynmicAgent.content,
                        .response_finish_reason = if (resDynmicAgent.finish_reason) |fr| fr.toStr() else null,
                        .response_reasoning_content = resDynmicAgent.reasoning_content,
                        .role = agent.Role.assistant.toStr(),
                        .finish_reason = null,
                        .tool_calls = null,
                        .tool_call_id = null,
                        .agent_name = current_agent,
                        .session_name = session_name,
                        .loop_index = loopCounter,
                        .temperature = agent_temperature,
                        .is_thinking = isThinking,
                        .prompt_tokens = resDynmicAgent.usage.prompt_tokens,
                        .completion_tokens = resDynmicAgent.usage.completion_tokens,
                        .total_tokens = resDynmicAgent.usage.total_tokens,
                    });
                    self.logger.infoFmt("FINISH REASON STOP - complete", .{}) catch {};
                    break;
                } else if (finish_reason == .length) {
                    current_max_tokens += 4096;
                    continue;
                } else if (finish_reason == .tool_calls) {
                    try HandleTool(allocator, self.db, self.logger, session_id, model, cwd, session_name, loopCounter, &messagesLists, resDynmicAgent, &agent_temperature, &isThinking, api_key, base_url, config, base_tools);
                } else {
                    retryCount += 1;
                    self.logger.errFmt("Error calling agent: maybe streaming failed", .{}) catch {};
                    _ = try SendUserChoice(
                        allocator,
                        session_id,
                        self.logger,
                    );
                    break;
                }

                retryCount = 0;
            }

            // Log if finish_reason is null
            if (resDynmicAgent.finish_reason == null) {
                self.logger.warnFmt("WORKFLOW: finish_reason is NULL!", .{}) catch {};
            }
        }
    }
    fn callDynamicAgent(
        self: *TUIWorkflow,
        allocator: std.mem.Allocator,
        messages_list: *std.ArrayList(agent.AgentMessage),
        agent_temperature: f32,
        current_max_tokens: usize,
        isThinking: bool,
        api_key: []const u8,
        model: []const u8,
        base_url: []const u8,
        session_id: []const u8,
        config: *const config_mod.LlmConfig,
        base_tools: []const tool_models.AgentTool,
    ) !agent.CallResponse {
        _ = config;
        // Fetch MCP tools from configured servers
        // const mcp_tools = buildMcpTools.run(allocator, config) catch |err| blk: {
        //     self.logger.errFmt("Failed to load MCP tools: {s}", .{@errorName(err)}) catch {};
        //     break :blk &[_]tool_models.AgentTool{};
        // };
        // Note: mcp_tools memory is managed by the arena allocator
        // mcp still isse

        // Merge base tools with MCP tools
        var all_tools: std.ArrayList(tool_models.AgentTool) = .empty;
        try all_tools.appendSlice(allocator, base_tools);
        // try all_tools.appendSlice(allocator, mcp_tools); // this is issue will be fixed in the next release
        const tools = try all_tools.toOwnedSlice(allocator);

        var dynamic_agent = try agent.Agent.init(allocator, self.logger);
        dynamic_agent.apiKey = api_key;
        dynamic_agent.model = model;
        dynamic_agent.baseUrl = base_url;
        const dynamic_agent_call_params = agent.AgentCall{ .tools = tools, .messages = messages_list.items, .temperature = agent_temperature, .max_tokens = current_max_tokens };
        dynamic_agent.thinkingEnabled = isThinking;
        dynamic_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

        var stream_ctx = StreamingContext{
            .allocator = allocator,
            .session_id = session_id,
            .chunk_index = 0,
        };
        const res_dynamic_agent = try dynamic_agent.callStreaming(dynamic_agent_call_params, &stream_ctx, stream_callback);

        return res_dynamic_agent;
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
    fn callCompactAgent(
        self: *TUIWorkflow,
        messages: []agent.AgentMessage,
        arena: std.mem.Allocator,
        api_key: []const u8,
        model: []const u8,
        base_url: []const u8,
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
        compaction_agent.apiKey = api_key;
        compaction_agent.model = model;
        compaction_agent.baseUrl = base_url;

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

        // Use callStreaming for compaction agent - no-op callback since we don't need to stream to client
        const response = compaction_agent.callStreaming(params, null, noopStreamCallback) catch |err| {
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

    /// No-op callback for streaming - used when we don't need to stream chunks to client
    fn noopStreamCallback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
        _ = ctx;
        _ = chunk;
        // Do nothing - we just collect the final response
    }

    /// Compact messages in memory based on CompactionAgent output
    /// Also persists to database: marks old messages as not for LLM, saves new compacted message
    fn compactMessagesInMemory(
        self: *TUIWorkflow,
        allocator: std.mem.Allocator,
        messages: *std.ArrayList(agent.AgentMessage),
        compacted_xml: []const u8,
        session_id: []const u8,
        model: []const u8,
        cwd: []const u8,
    ) !void {
        const total = messages.items.len;
        if (total <= 4) return;

        // Mark all existing messages in this session as not for LLM (soft-delete)
        try mark_messages_not_for_llm.run(allocator, self.db, session_id);

        // Build the compacted summary content
        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(allocator);
        var w = summary.writer(allocator);
        try w.writeAll("[CONTEXT SUMMARY]\n\n");
        try w.writeAll(compacted_xml);
        const summary_content = try summary.toOwnedSlice(allocator);

        // Save the compacted summary to the database with is_feed_to_llm = 1
        const id = try std.fmt.allocPrint(allocator, "{}", .{std.time.nanoTimestamp()});
        defer allocator.free(id);
        const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.time.milliTimestamp()});
        defer allocator.free(created_at);

        const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)";
        try self.db.exec(allocator, sql, &.{ id, session_id, model, summary_content, "stop", "user", "", "", cwd, "Agent", "", "0", created_at });

        // Build new in-memory message list: system message + compacted summary
        var new_messages: std.ArrayList(agent.AgentMessage) = .empty;

        // Keep system message - duplicate content to be safe
        const system_content = if (messages.items[0].content) |c|
            try allocator.dupe(u8, c)
        else
            null;
        try new_messages.append(allocator, .{
            .role = .system,
            .content = system_content,
        });

        // Add compacted summary as user message
        try new_messages.append(allocator, .{
            .role = .user,
            .content = summary_content,
        });

        // Free ALL old messages (including ones we "kept" - we have copies now)
        for (messages.items) |*msg| {
            msg.deinit(allocator);
        }
        messages.deinit(allocator);
        messages.* = new_messages;

        self.logger.debugFmt("[COMPACTION] Compacted: {} -> {} messages (persisted to DB)", .{ total, messages.items.len }) catch {};
    }
};

test {
    _ = @import("tui_workflow_test.zig");
}
