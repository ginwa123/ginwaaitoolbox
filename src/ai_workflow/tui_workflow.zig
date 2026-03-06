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
const list_skills_tool = tree1_mod.list_skills_tool;
const get_skill_tool = tree1_mod.get_skill_tool;
const loop_detector = tree1_mod.loop_detector;
const bash_helper = tree1_mod.helperTool;
const get_tree_dir = @import("get_tree_dir.zig");
const logger_mod = tree1_mod.logger;
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

const handle_content_filter = @import("handle_content_filter.zig");
pub const cancellation_registry = @import("cancellation_registry.zig");
const handle_tool = @import("handle_tool.zig");
/// Compaction configuration constants
const COMPACTION_CONFIG = struct {
    pub const target_body_size: usize = 50 * 1024; // 50KB target
    pub const max_body_size: usize = 700 * 1024; // 150kb threshold to trigger
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

pub const StreamingContext = struct {
    allocator: std.mem.Allocator,
    workflow: *TUIWorkflow,
    conn_fd: std.posix.fd_t,
    chunk_index: usize = 0,
    session_id: []const u8 = "",
};

// DEPRECATED: Legacy global cancellation - use CancellationRegistry instead
// Kept for backward compatibility during transition
var g_cancelled_ptr: ?*std.atomic.Value(bool) = null;

/// DEPRECATED: Use CancellationRegistry.register() instead
pub fn setCancelledPtr(ptr: *std.atomic.Value(bool)) void {
    g_cancelled_ptr = ptr;
}

/// DEPRECATED: Use CancellationRegistry.isCancelled(session_id) instead
pub fn isCancelled() bool {
    if (g_cancelled_ptr) |ptr| {
        return ptr.load(.seq_cst);
    }
    return false;
}

/// Context-aware cancellation check for use with callStreaming
/// ctx should be a pointer to the session_id string
pub fn isCancelledWithContext(ctx: ?*anyopaque) bool {
    if (ctx == null) return false;
    
    const session_id_ptr = @as(?*const []const u8, @ptrCast(@alignCast(ctx))) orelse return false;
    
    if (cancellation_registry.getGlobalRegistry()) |registry| {
        return registry.isCancelled(session_id_ptr.*);
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
/// Loaded skill tracking for system context injection
pub const LoadedSkill = struct {
    skill_name: []const u8,
    content: []const u8,

    pub fn deinit(self: *const LoadedSkill, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.content);
    }
};

pub const TUIWorkflow = struct {
    // allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,

    session_id: []const u8 = "",

    message: []const u8 = "",

    // current working directory
    cwd: []const u8 = "",

    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",

    conn_fd: std.posix.fd_t = -1,

    loop_detector: loop_detector.LoopDetector = .{},
    loaded_skills: std.ArrayList(LoadedSkill) = .{},


    pub fn init(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !TUIWorkflow {
        const log_ptr = try allocator.create(logger_mod.Logger);
        log_ptr.* = logger_mod.Logger.initColor(allocator, .{
            .min_level = .debug,
            .output_mode = .file,
            .log_file_path = "/var/tmp/agentic_coding.log",
            .include_location = true,
            .include_request_id = true,
            .include_timestamp = true,
        });
        return .{
            .db = db,
            .logger = log_ptr,
            .session_id = "",
            .message = "",
            .cwd = "",
            .api_key = "",
            .model = "",
            .base_url = "",
            .conn_fd = -1,
            .loaded_skills = .{},
        };
    }

    pub fn run(self: *TUIWorkflow, allocator: std.mem.Allocator) void {
        self.run_internal(allocator) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch return;
            defer allocator.free(err_msg);
            send_error.run(allocator, self.conn_fd, self.logger, err_msg, "user_choice");
        };
    }

    fn run_internal(self: *TUIWorkflow, parent_allocator: std.mem.Allocator) !void {
        // Register this session for cancellation tracking
        if (cancellation_registry.getGlobalRegistry()) |registry| {
            try registry.register(self.session_id);
        }
        const initial_agent = try get_current_agent_by_session_id.run(
            parent_allocator,
            self.db,
            self.session_id,
        );
        var current_agent: []const u8 = initial_agent;
        const session_name = self.message;
        save_message.run(parent_allocator, self.db, self.session_id, self.model, self.cwd, self.message, null, "user", "null", null, null, current_agent, session_name, 0) catch |err| {
            self.logger.errFmt("saveMessageAsUser error: {s}", .{@errorName(err)}) catch {};
        };

        var retryCount: usize = 0;
        var agent_temperature: f32 = 0.2;
        var isThinking: bool = false;
        var current_max_tokens: usize = 8000;
        var loop_counter: u32 = 0;
        while (true) {
            var arena_allocator_while_loop = std.heap.ArenaAllocator.init(parent_allocator);
            defer arena_allocator_while_loop.deinit();
            const allocator = arena_allocator_while_loop.allocator();

            var messages_list: std.ArrayList(agent.AgentMessage) = .empty;
            const skills = try self.buildSkillsContent(allocator);
            defer allocator.free(skills);
            const initial_messages = try build_messages.run(allocator, self.cwd, try get_tree_dir.run(allocator, self.cwd), try get_messages.run(allocator, self.db, self.session_id), skills);

            try messages_list.appendSlice(allocator, initial_messages);

            loop_counter += 1;
            if (retryCount > 10) return error.TooManyRetries;

            const body_size = self.estimateBodySize(messages_list.items);
            self.logger.debugFmt("[COMPACTION] Body size: {} bytes", .{body_size}) catch {};
            if (body_size > COMPACTION_CONFIG.max_body_size) {
                self.logger.debugFmt("[COMPACTION] Threshold exceeded, triggering compaction", .{}) catch {};
                if (try self.call_compact_agent(messages_list.items, allocator)) |compacted_xml| {
                    try self.compactMessagesInMemory(allocator, &messages_list, compacted_xml);
                }
            }

            const res_dynamic_agent = try self.call_dynamic_agent(allocator, &messages_list, agent_temperature, current_max_tokens, isThinking);

            retryCount = 0;

            if (res_dynamic_agent.finish_reason) |finish_reason| {
                if (finish_reason == .stop) {
                    send_response.run(allocator, self.conn_fd, self.logger, res_dynamic_agent, "user_choice");
                    _ = try save_message.run(allocator, self.db, self.session_id, self.model, self.cwd, null, res_dynamic_agent, agent.Role.assistant.toStr(), null, null, null, current_agent, session_name, loop_counter);
                    // _ = try send_user_choice.run(allocator, self.conn_fd, self.logger);
                    self.logger.infoFmt("FINISH REASON STOPPP", .{}) catch {};
                    break;
                } else if (finish_reason == .length) {
                    current_max_tokens += 4096;
                    continue;
                } else if (finish_reason == .tool_calls) {
                    try handle_tool.run(allocator, parent_allocator, self, self.db, self.logger, self.conn_fd, self.session_id, self.model, self.cwd, &current_agent, session_name, loop_counter, &messages_list, res_dynamic_agent, &agent_temperature, &isThinking);
                } else {
                    retryCount += 1;
                    self.logger.errFmt("Error calling agent: maybe streaming failed", .{}) catch {};
                    _ = try send_user_choice.run(
                        allocator,
                        self.conn_fd,
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
    ) !agent.CallResponse {
        const tools: []const tool_models.AgentTool = &.{ bash_tool.bashTool, change_agent_tool.ChangeAgentTool, list_skills_tool.listSkillsTool, get_skill_tool.getSkillTool };

        var dynamic_agent = try agent.Agent.init(allocator, self.logger);
        dynamic_agent.apiKey = self.api_key;
        dynamic_agent.model = self.model;
        dynamic_agent.baseUrl = self.base_url;
        const dynamic_agent_call_params = agent.AgentCall{ .tools = tools, .messages = messages_list.items, .temperature = agent_temperature, .max_tokens = current_max_tokens };
        dynamic_agent.thinkingEnabled = isThinking;
        dynamic_agent.httpOptions.read_timeout_ms = 600_000; // 10 minutes

        var stream_ctx = StreamingContext{
            .allocator = allocator,
            .workflow = self,
            .chunk_index = 0,
            .conn_fd = self.conn_fd,
            .session_id = self.session_id,
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
        allocator: std.mem.Allocator,
        messages: *std.ArrayList(agent.AgentMessage),
        compacted_xml: []const u8,
    ) !void {
        const total = messages.items.len;
        if (total <= 4) return;

        // Mark all existing messages in this session as not for LLM (soft-delete)
        try mark_messages_not_for_llm.run(allocator, self.db, self.session_id);

        // Build the compacted summary content
        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(allocator);
        var w = summary.writer(allocator);
        try w.writeAll("[CONTEXT SUMMARY]\n\n");
        try w.writeAll(compacted_xml);
        const summary_content = try summary.toOwnedSlice(allocator);

        // Save the compacted summary to the database with is_feed_to_llm = 1
        const id = try std.fmt.allocPrint(allocator, "{}-{}", .{ std.time.timestamp(), std.crypto.random.int(u64) });
        defer allocator.free(id);
        const createdStr = try std.fmt.allocPrint(allocator, "{}", .{std.time.timestamp()});
        defer allocator.free(createdStr);

        const sql = "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)";
        try self.db.exec(allocator, sql, &.{ id, self.session_id, self.model, createdStr, summary_content, "stop", "user", "", "", self.cwd, "GeneralAgent", "", "0" });

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

    pub fn handleListSkills(self: *TUIWorkflow, allocator: std.mem.Allocator, messages_list: *std.ArrayList(agent.AgentMessage), tool_call: agent.ToolCall) void {
        const result = list_skills_tool.executeListSkills(allocator) catch |err| blk: {
            self.logger.errFmt("Error executing list_skills: {s}", .{@errorName(err)}) catch {};
            break :blk "{\"error\": \"Failed to list skills\"}";
        };

        self.logger.debugFmt("LIST_SKILLS RESULT: {s}", .{result}) catch {};

        const tool_result_msg = agent.AgentMessage{
            .role = .tool,
            .content = result,
            .tool_call_id = allocator.dupe(u8, tool_call.id) catch return,
        };
        messages_list.append(allocator, tool_result_msg) catch return;
        const current_agent = get_current_agent_by_session_id.run(allocator, self.db, self.session_id) catch return;

        save_message.run(allocator, self.db, self.session_id, self.model, self.cwd, result, null, "tool", "tool", null, tool_call.id, current_agent, null, 0) catch {};
        send_tool_result.run(allocator, self.conn_fd, self.logger, result, tool_call.id, tool_call.function.name, null);
    }

    pub fn handleGetSkill(self: *TUIWorkflow, allocator: std.mem.Allocator, messages_list: *std.ArrayList(agent.AgentMessage), tool_call: agent.ToolCall) !void {
        // Parse arguments JSON to GetSkillInput
        const parsed = std.json.parseFromSlice(
            get_skill_tool.GetSkillInput,
            allocator,
            tool_call.function.arguments,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            self.logger.errFmt("Failed to parse get_skill arguments: {s}", .{@errorName(err)}) catch {};
            return;
        };
        defer parsed.deinit();

        const result = get_skill_tool.executeGetSkill(allocator, parsed.value) catch |err| blk: {
            self.logger.errFmt("Error executing get_skill: {s}", .{@errorName(err)}) catch {};
            break :blk "{\"error\": \"Failed to get skill\"}";
        };
        defer allocator.free(result);

        self.logger.debugFmt("GET_SKILL RESULT: {s}", .{result}) catch {};

        // Parse the result JSON to extract skill info
        const resultParsed = std.json.parseFromSlice(
            get_skill_tool.GetSkillResult,
            allocator,
            result,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            self.logger.errFmt("Failed to parse get_skill result: {s}", .{@errorName(err)}) catch {};
            // Still send tool result even if parsing fails
            const tool_result_msg = agent.AgentMessage{
                .role = .tool,
                .content = result,
                .tool_call_id = allocator.dupe(u8, tool_call.id) catch return,
            };
            messages_list.append(allocator, tool_result_msg) catch return;
            const current_agent = get_current_agent_by_session_id.run(allocator, self.db, self.session_id) catch return;

            _ = try save_message.run(allocator, self.db, self.session_id, self.model, self.cwd, result, null, "tool", "tool", null, tool_call.id, current_agent, null, 0);
            send_tool_result.run(allocator, self.conn_fd, self.logger, result, tool_call.id, tool_call.function.name, null);
            return;
        };
        defer resultParsed.deinit();

        const skill_result = resultParsed.value;

        // Only inject if skill was successfully loaded and not already loaded
        if (skill_result.loaded and skill_result.content.len > 0) {
            if (!self.isSkillLoaded(skill_result.skill_name)) {
                // Add to loaded skills list
                const skill_name_copy = allocator.dupe(u8, skill_result.skill_name) catch return;
                const content_copy = allocator.dupe(u8, skill_result.content) catch {
                    return;
                };
                const loaded_skill = LoadedSkill{
                    .skill_name = skill_name_copy,
                    .content = content_copy,
                };
                self.loaded_skills.append(allocator, loaded_skill) catch {
                    loaded_skill.deinit(allocator);
                    return;
                };

                self.logger.debugFmt("Skill '{s}' loaded and added to system context", .{skill_result.skill_name}) catch {};

                // Save skill to database for persistence
                self.saveSkillToDB(allocator, skill_name_copy, content_copy) catch |err| {
                    self.logger.errFmt("Failed to save skill to database: {s}", .{@errorName(err)}) catch {};
                };
                // Send updated skills list to TUI
                self.sendSkillsList(allocator);
                // Send updated skills list to TUI
                self.sendSkillsList(allocator);
                // Rebuild system message with all loaded skills
                const current_agent = get_current_agent_by_session_id.run(allocator, self.db, self.session_id) catch return;

                // Get agent prompt based on current agent
                const agent_prompt: []const u8 = if (std.mem.eql(u8, current_agent, "GeneralAgent"))
                    prompt.GeneralAgent
                else if (std.mem.eql(u8, current_agent, "ExplorationAgent"))
                    prompt.ExplorationAgent
                else if (std.mem.eql(u8, current_agent, "PlanningAgent"))
                    prompt.PlanningAgent
                else if (std.mem.eql(u8, current_agent, "ExecutingAgent"))
                    prompt.ExecutingAgent
                else if (std.mem.eql(u8, current_agent, "KnowledgeAgent"))
                    prompt.KnowledgeAgent
                else
                    prompt.GeneralAgent;

                const newSystemContent = self.buildSystemMessageWithSkills(allocator, agent_prompt) catch |err| {
                    self.logger.errFmt("Failed to build system message with skills: {s}", .{@errorName(err)}) catch {};
                    return;
                };
                defer allocator.free(newSystemContent);

                // Replace system message in messages_list
                var system_replaced = false;
                for (messages_list.items) |*msg| {
                    if (msg.role == .system) {
                        // Free old content and replace with new
                        if (msg.content) |old_content| {
                            allocator.free(old_content);
                        }
                        msg.content = allocator.dupe(u8, newSystemContent) catch return;
                        system_replaced = true;
                        break;
                    }
                }
                if (!system_replaced) {
                    // Insert new system message at beginning
                    messages_list.insert(allocator, 0, agent.AgentMessage{
                        .role = .system,
                        .content = allocator.dupe(u8, newSystemContent) catch return,
                    }) catch return;
                }
            } else {
                self.logger.debugFmt("Skill '{s}' already loaded, skipping duplicate", .{skill_result.skill_name}) catch {};
            }
        }

        // Send tool result (use original result before deinit)
        const tool_result_msg = agent.AgentMessage{
            .role = .tool,
            .content = result,
            .tool_call_id = allocator.dupe(u8, tool_call.id) catch return,
        };
        messages_list.append(allocator, tool_result_msg) catch return;

        const current_agent_final = try get_current_agent_by_session_id.run(allocator, self.db, self.session_id);
        save_message.run(allocator, self.db, self.session_id, self.model, self.cwd, result, null, "tool", "tool", null, tool_call.id, current_agent_final, null, 0) catch {};
        send_tool_result.run(allocator, self.conn_fd, self.logger, result, tool_call.id, tool_call.function.name, null);
    }

    /// Build skills content string from loaded skills
    fn buildSkillsContent(self: *TUIWorkflow, allocator: std.mem.Allocator) ![]const u8 {
        if (self.loaded_skills.items.len == 0) {
            return allocator.dupe(u8, "");
        }

        var skillsBuilder: std.ArrayList(u8) = .empty;
        try skillsBuilder.appendSlice(allocator, "\n\n## Loaded Skills\n\n");
        for (self.loaded_skills.items) |skill| {
            try skillsBuilder.appendSlice(allocator, "### ");
            try skillsBuilder.appendSlice(allocator, skill.skill_name);
            try skillsBuilder.appendSlice(allocator, "\n\n");
            try skillsBuilder.appendSlice(allocator, skill.content);
            try skillsBuilder.appendSlice(allocator, "\n\n");
        }

        return try skillsBuilder.toOwnedSlice(allocator);
    }

    /// Build system message content with loaded skills injected
    fn buildSystemMessageWithSkills(self: *TUIWorkflow, allocator: std.mem.Allocator, agent_prompt: []const u8) ![]const u8 {
        const treeDir = try get_tree_dir.run(allocator, self.cwd);

        // Build base system content without skills
        const baseContent = try prompt.agenticCodingWithCwd(allocator, self.cwd, agent_prompt, treeDir, "");

        // If no skills loaded, return base content
        if (self.loaded_skills.items.len == 0) {
            return allocator.dupe(u8, baseContent);
        }

        // Build skills section
        var skillsBuilder: std.ArrayList(u8) = .empty;
        try skillsBuilder.appendSlice(allocator, "\n\n## Loaded Skills\n\n");
        for (self.loaded_skills.items) |skill| {
            try skillsBuilder.appendSlice(allocator, "### ");
            try skillsBuilder.appendSlice(allocator, skill.skill_name);
            try skillsBuilder.appendSlice(allocator, "\n\n");
            try skillsBuilder.appendSlice(allocator, skill.content);
            try skillsBuilder.appendSlice(allocator, "\n\n");
        }

        // Combine base content with skills section
        const skillsSection = try skillsBuilder.toOwnedSlice(allocator);

        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ baseContent, skillsSection });
    }

    /// Check if a skill is already loaded
    fn isSkillLoaded(self: *TUIWorkflow, skill_name: []const u8) bool {
        for (self.loaded_skills.items) |skill| {
            if (std.mem.eql(u8, skill.skill_name, skill_name)) {
                return true;
            }
        }
        return false;
    }

    /// Save a loaded skill to the database for persistence
    fn saveSkillToDB(self: *TUIWorkflow, allocator: std.mem.Allocator, skill_name: []const u8, content: []const u8) !void {
        // Skip if session_id is empty
        if (self.session_id.len == 0) return;

        const sql = "INSERT OR REPLACE INTO session_skills (session_id, skill_name, content, loaded_at) VALUES (?, ?, ?, strftime('%s', 'now'))";
        try self.db.exec(allocator, sql, &.{ self.session_id, skill_name, content });
        self.logger.debugFmt("Skill '{s}' saved to database for session {s}", .{ skill_name, self.session_id }) catch {};
    }

    /// Load all skills for the current session from the database
    pub fn loadSkillsFromDB(self: *TUIWorkflow, allocator: std.mem.Allocator) !void {
        // Skip if session_id is empty
        if (self.session_id.len == 0) return;

        // Clear existing skills first
        for (self.loaded_skills.items) |skill| {
            skill.deinit(allocator);
        }
        self.loaded_skills.clearRetainingCapacity();

        // Load from database
        const sql = "SELECT skill_name, content FROM session_skills WHERE session_id = ? ORDER BY loaded_at ASC";
        var rows = try self.db.query(allocator, sql, &.{self.session_id});
        defer rows.deinit();

        while (try rows.next()) |row| {
            const skill_name = try allocator.dupe(u8, row.values[0]);
            errdefer allocator.free(skill_name);
            const content = try allocator.dupe(u8, row.values[1]);
            errdefer allocator.free(content);

            const loaded_skill = LoadedSkill{
                .skill_name = skill_name,
                .content = content,
            };
            try self.loaded_skills.append(allocator, loaded_skill);
            self.logger.debugFmt("Loaded skill '{s}' from database for session {s}", .{ skill_name, self.session_id }) catch {};
        }

        self.logger.debugFmt("Loaded {} skills from database for session {s}", .{ self.loaded_skills.items.len, self.session_id }) catch {};
    }

    /// Send skills list to TUI via IPC
    pub fn sendSkillsList(self: *TUIWorkflow, allocator: std.mem.Allocator) void {
        if (self.conn_fd < 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        var w = buf.writer(allocator);

        w.writeAll("<response><type>skills</type><skills>") catch return;
        for (self.loaded_skills.items) |skill| {
            w.writeAll("<skill><name>") catch return;
            w.writeAll(skill.skill_name) catch return;
            w.writeAll("</name></skill>") catch return;
        }
        w.writeAll("</skills></response>") catch return;

        self.logger.debugFmt("SEND SKILLS XML: {s}", .{buf.items}) catch {};

        _ = std.posix.write(self.conn_fd, buf.items) catch |err| {
            if (err != error.BrokenPipe) {
                self.logger.errFmt("Send Skills response error {s}", .{@errorName(err)}) catch {};
            }
        };
        _ = std.posix.write(self.conn_fd, "\n") catch {};
    }
};
