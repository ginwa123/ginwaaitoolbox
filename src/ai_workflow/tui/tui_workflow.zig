const std = @import("std");
const json = std.json;
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const prompt = root_mod.prompt;
const context = @import("models.zig").ContextIPCTui;
const sqlite = root_mod.sqlite;
const bash_tool = root_mod.bash_tool;
const read_file_tool = root_mod.read_file;
const tool_models = root_mod.tool_models;
const change_agent_tool = root_mod.change_agent_tool;
const list_skills_tool = root_mod.list_skills_tool;
const get_skill_tool = root_mod.get_skill_tool;
const remove_skill_tool = root_mod.remove_skill_tool;
const skills = root_mod.skills;
const loop_detector = root_mod.loop_detector;
const bash_helper = root_mod.helperTool;
const get_tree_dir = @import("get_tree_dir.zig");
const logger_mod = root_mod.logger;
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_message = @import("transform_llm_history_to_agent_messages.zig");
const send_tool_result = @import("send_tool_result.zig");
const send_user_choice = @import("send_user_choice.zig");
const send_response = @import("send_response.zig");
const send_error = @import("send_error.zig");
const save_message = @import("save_message.zig");
const build_messages = @import("build_messages_for_agent.zig");
const get_messages = @import("get_messages.zig");
const mark_messages_not_for_llm = @import("mark_message_not_for_llm.zig");
const send_stream_chunk_final = @import("send_stream_chunk_final.zig");
const send_steam_chunk_content = @import("send_stream_chunk_content.zig");
const send_stream_chunk_reasoning = @import("send_stream_chunk_reasoning.zig");
const send_stream_to_chunk_tool_call_delta = @import("send_stream_to_chunk_tool_call_delta.zig");
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const build_memory_for_agent = @import("build_memory_for_agent.zig");
const write_file_tool = root_mod.write_file;
const search_tool = root_mod.search_tool;
const text_replace_tool = root_mod.text_replace_tool;

const handle_content_filter = @import("handle_content_filter.zig");
const build_skill_content_mod = @import("build_skill_content.zig");
const save_skill_mod = @import("save_skill.zig");
const send_skill_mod = @import("send_skill.zig");
pub const cancellation_registry = root_mod.session.cancellation_registry;
const handle_tool = @import("handle_tool.zig");
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
    workflow: *TUIWorkflow,
    conn_fd: std.posix.fd_t,
    chunk_index: usize = 0,
    session_id: []const u8 = "",
};

/// Context-aware cancellation check for use with callStreaming
/// ctx should be a pointer to StreamingContext (same as stream_callback receives)
pub fn isCancelledWithContext(ctx: ?*anyopaque) bool {
    if (ctx == null) return false;

    // ctx is actually *StreamingContext, not *[]const u8
    const stream_ctx = @as(?*StreamingContext, @ptrCast(@alignCast(ctx))) orelse return false;

    if (cancellation_registry.getGlobalRegistry()) |registry| {
        return registry.isCancelled(stream_ctx.session_id);
    }
    return false;
}

/// Callback for streaming chunks - sends each chunk to the client
pub fn stream_callback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    const stream_ctx = @as(?*StreamingContext, @ptrCast(@alignCast(ctx))) orelse return;
    const allocator = stream_ctx.allocator;
    const conn_fd = stream_ctx.conn_fd;

    if (chunk.done) {
        send_stream_chunk_final.run(allocator, conn_fd, stream_ctx.chunk_index, chunk.usage);
        return;
    }

    // Send content chunk
    if (chunk.content) |content| {
        send_steam_chunk_content.run(allocator, conn_fd, stream_ctx.chunk_index, content);
        stream_ctx.chunk_index += 1;
    }

    // Send reasoning content chunk
    if (chunk.reasoning_content) |rc| {
        send_stream_chunk_reasoning.run(allocator, conn_fd, stream_ctx.chunk_index, rc);
        stream_ctx.chunk_index += 1;
    }

    // Handle tool calls delta - we'll aggregate these
    if (chunk.tool_calls_delta) |deltas| {
        send_stream_to_chunk_tool_call_delta.run(allocator, conn_fd, stream_ctx.chunk_index, deltas);
        stream_ctx.chunk_index += 1;
    }
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

    pub fn run(self: *TUIWorkflow, allocator: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd: []const u8, api_key: []const u8, model: []const u8, base_url: []const u8, conn_fd: std.posix.fd_t) void {
        self.run_internal(allocator, session_id, message, cwd, api_key, model, base_url, conn_fd) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch return;
            defer allocator.free(err_msg);
            send_error.run(allocator, conn_fd, self.logger, err_msg, "user_choice");
        };
    }

    fn run_internal(self: *TUIWorkflow, parent_allocator: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd: []const u8, api_key: []const u8, model: []const u8, base_url: []const u8, conn_fd: std.posix.fd_t) !void {
        // Register this session for cancellation tracking
        if (cancellation_registry.getGlobalRegistry()) |registry| {
            try registry.register(session_id);
        }
        const session_name = message;
        // Fetch initial agent for the first save_message call
        const initial_agent = try get_current_agent_by_session_id.run(
            parent_allocator,
            self.db,
            session_id,
        );
        save_message.run(parent_allocator, self.db, session_id, model, cwd, message, null, null, null, "user", "null", null, null, initial_agent, session_name, 0) catch |err| {
            self.logger.errFmt("saveMessageAsUser error: {s}", .{@errorName(err)}) catch {};
        };

        // this variable is used to track the number of times the agent has been retried
        var retryCount: usize = 0;
        var agent_temperature: f32 = 0.2;
        var isThinking: bool = false;
        var current_max_tokens: usize = 8000;
        var loop_counter: u32 = 0;
        while (true) {
            var arena_allocator_while_loop = std.heap.ArenaAllocator.init(parent_allocator);
            defer arena_allocator_while_loop.deinit();
            const allocator = arena_allocator_while_loop.allocator();

            loop_counter += 1;
            if (retryCount > 10) return error.TooManyRetries;

            // Fetch current agent fresh from DB each iteration
            const current_agent = try get_current_agent_by_session_id.run(
                allocator,
                self.db,
                session_id,
            );

            var messages_list: std.ArrayList(agent.AgentMessage) = .empty;

            const initial_messages = try build_messages.run(allocator, cwd, "", try get_messages.run(allocator, self.db, session_id), try build_skill_content_mod.run(allocator, self.db, session_id), try build_memory_for_agent.run(allocator, cwd));

            try messages_list.appendSlice(allocator, initial_messages);

            const body_size = self.estimateBodySize(messages_list.items);
            self.logger.debugFmt("[COMPACTION] Body size: {} bytes", .{body_size}) catch {};
            if (body_size > COMPACTION_CONFIG.max_body_size) {
                self.logger.debugFmt("[COMPACTION] Threshold exceeded, triggering compaction", .{}) catch {};
                if (try self.call_compact_agent(messages_list.items, allocator, api_key, model, base_url)) |compacted_xml| {
                    try self.compactMessagesInMemory(allocator, &messages_list, compacted_xml, session_id, model, cwd);
                }
            }

            const res_dynamic_agent = self.call_dynamic_agent(allocator, &messages_list, agent_temperature, current_max_tokens, isThinking, api_key, model, base_url, conn_fd, session_id) catch |err| {
                retryCount += 1;
                self.logger.errFmt("Error calling dynamic agent: {s} now retrying", .{@errorName(err)}) catch {};
                continue;
            };

            retryCount = 0;

            if (res_dynamic_agent.finish_reason) |finish_reason| {
                if (finish_reason == .stop) {
                    _ = send_response.run(allocator, conn_fd, self.logger, res_dynamic_agent, "user_choice");
                    _ = try save_message.run(allocator, self.db, session_id, model, cwd, null, res_dynamic_agent.content, if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null, res_dynamic_agent.reasoning_content, agent.Role.assistant.toStr(), null, null, null, current_agent, session_name, loop_counter);
                    self.logger.infoFmt("FINISH REASON STOPPP", .{}) catch {};
                    break;
                } else if (finish_reason == .length) {
                    current_max_tokens += 4096;
                    continue;
                } else if (finish_reason == .tool_calls) {
                    try handle_tool.run(allocator, self, self.db, self.logger, conn_fd, session_id, model, cwd, session_name, loop_counter, &messages_list, res_dynamic_agent, &agent_temperature, &isThinking);
                } else {
                    retryCount += 1;
                    self.logger.errFmt("Error calling agent: maybe streaming failed", .{}) catch {};
                    _ = try send_user_choice.run(
                        allocator,
                        conn_fd,
                        self.logger,
                    );
                    break;
                    // continue;
                }

                retryCount = 0;
            }
        }
    }
    fn call_dynamic_agent(
        self: *TUIWorkflow,
        allocator: std.mem.Allocator,
        messages_list: *std.ArrayList(agent.AgentMessage),
        agent_temperature: f32,
        current_max_tokens: usize,
        isThinking: bool,
        api_key: []const u8,
        model: []const u8,
        base_url: []const u8,
        conn_fd: std.posix.fd_t,
        session_id: []const u8,
    ) !agent.CallResponse {
        const tools: []const tool_models.AgentTool = &.{
            bash_tool.bashTool,                read_file_tool.readFileTool, change_agent_tool.ChangeAgentTool, list_skills_tool.listSkillsTool, get_skill_tool.getSkillTool, remove_skill_tool.removeSkillTool,

            // write_file_tool.writeFileTool,
            text_replace_tool.textReplaceTool, search_tool.searchTool,
        };

        var dynamic_agent = try agent.Agent.init(allocator, self.logger);
        dynamic_agent.apiKey = api_key;
        dynamic_agent.model = model;
        dynamic_agent.baseUrl = base_url;
        const dynamic_agent_call_params = agent.AgentCall{ .tools = tools, .messages = messages_list.items, .temperature = agent_temperature, .max_tokens = current_max_tokens };
        dynamic_agent.thinkingEnabled = isThinking;
        dynamic_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

        var stream_ctx = StreamingContext{
            .allocator = allocator,
            .workflow = self,
            .chunk_index = 0,
            .conn_fd = conn_fd,
            .session_id = session_id,
        };
        const res_dynamic_agent = try dynamic_agent.callStreaming(dynamic_agent_call_params, &stream_ctx, stream_callback, isCancelledWithContext);

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
    fn call_compact_agent(
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
        try self.db.exec(allocator, sql, &.{ id, session_id, model, summary_content, "stop", "user", "", "", cwd, "ExplorationAgent", "", "0", created_at });

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
