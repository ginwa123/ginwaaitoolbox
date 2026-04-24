const std = @import("std");
const json = std.json;
const nalar_mod = @import("nalarcore");
const agent = nalar_mod.agent;
const llm_models = nalar_mod.llm_models;
const prompt = nalar_mod.prompt;
pub const context = @import("models.zig").ContextIPCTui;
pub const ContextIPCTui = @import("models.zig").ContextIPCTui;
pub const kerjabot_get_session = @import("llm_history.zig");
pub const kerjabot_create_session = @import("llm_history.zig");
pub const kerjabot_get_list_session = @import("llm_history.zig");
pub const tui_check_session_exists = @import("llm_history.zig");
const sqlite = nalar_mod.sqlite;
const BashTool = nalar_mod.bash_tool;
const ReadFileTool = nalar_mod.read_file;
const tool_models = nalar_mod.tool_models;
const SetAgentProperties = nalar_mod.set_agent_properties;
const ListSkillsTool = nalar_mod.list_skills_tool;
const GetSkillTool = nalar_mod.get_skill_tool;
const RemoveSkillTool = nalar_mod.remove_skill_tool;
const skills = nalar_mod.skills;
const bash_helper = nalar_mod.helperTool;
const logger_mod = nalar_mod.logger;
const llm_history = @import("llm_history.zig");
const session_helpers = llm_history;
const get_current_agent_by_session_id = llm_history.get_current_agent_by_session_id;
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_message = @import("transform_llm_history_to_agent_messages.zig");
const buildMessages = @import("build_messages_for_agent_prompt.zig").buildMessages;
pub const startup = @import("startup.zig").startup;
const getMessages = session_helpers.getMessages;
const getLatestMessage = session_helpers.getLatestMessage;
const mark_messages_not_for_llm = @import("llm_history.zig");
const BuildMemoryForAgent = @import("build_messages_for_agent_prompt.zig").BuildMemoryForAgent;
const WriteFileTool = nalar_mod.write_file;
const TextReplaceTool = nalar_mod.text_replace_tool;

const on_event_sent = @import("on_event_sent.zig");
const on_event_send_new = on_event_sent.on_event_send_new;
const sendStreamChunkContent = on_event_sent.sendStreamChunkContent;
const sendStreamChunkReasoning = on_event_sent.sendStreamChunkReasoning;
const sendStreamChunkFinal = on_event_sent.sendStreamChunkFinal;
const ContentChunk = on_event_sent.ContentChunk;
const ReasoningChunk = on_event_sent.ReasoningChunk;
const FinalChunk = on_event_sent.FinalChunk;
const ResponseType = on_event_sent.ResponseType;
const Response = on_event_sent.Response;

const BuildSkillContent = @import("build_messages_for_agent_prompt.zig").BuildSkillContent;
const BuildDynamicAgentContent = @import("build_messages_for_agent_prompt.zig").BuildDynamicAgentContent;
const BuildBackgroundProcessContent = @import("build_messages_for_agent_prompt.zig").BuildBackgroundProcessPrompt;
const save_skill_mod = @import("session_skills.zig");
const buildMcpTools = @import("build_messages_for_agent_prompt.zig");
const config_mod = nalar_mod.config;
pub const session_registry = nalar_mod.session.session_registry;
const handle_tool = @import("handle_tool.zig").handle_tool;
const SpawnSubAgentTool = nalar_mod.agents;
const tool_registry = @import("tool_registry.zig");
const session_table = @import("session_table.zig");

pub const SessionInfo = struct {
    session_id: []const u8,
    cwd: []const u8,
    created_at: []const u8,

    pub fn deinit(self: *SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.cwd);
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
    _ = ctx;
    _ = chunk;
    // Streaming is disabled for now - content is sent via on_event_send_new after completion
}

/// Filter and merge tools based on allowed_tools setting
/// - allowed_tools: "" = no tools, "all" = all tools, comma-separated = specific tools
/// Returns filtered base tools merged with MCP tools
pub fn filterAndMergeTools(
    allocator: std.mem.Allocator,
    mcp_tools: []const tool_models.AgentTool,
    allowed_tools: []const u8,
    is_sub_agent: bool,
) ![]tool_models.AgentTool {
    var base_tools = try allocator.alloc(tool_models.AgentTool, tool_registry.allAgentTools(allocator).len);
    @memcpy(base_tools, tool_registry.allAgentTools(allocator));

    // Filter base tools if allowed_tools is specified
    if (allowed_tools.len > 0 and !std.mem.eql(u8, allowed_tools, "all")) {
        var allowed_tools_set: std.StringArrayHashMap(void) = std.StringArrayHashMap(void).init(allocator);
        defer allowed_tools_set.deinit();

        var it = std.mem.splitScalar(u8, allowed_tools, ',');
        while (it.next()) |tool_name| {
            const trimmed = std.mem.trim(u8, tool_name, " ");
            if (trimmed.len > 0) {
                allowed_tools_set.put(trimmed, {}) catch {};
            }
        }

        var filtered_tools: std.ArrayList(tool_models.AgentTool) = std.ArrayList(tool_models.AgentTool).empty;
        defer filtered_tools.deinit(allocator);

        for (base_tools) |tool| {
            if (allowed_tools_set.contains(tool.function.name)) {
                try filtered_tools.append(allocator, tool);
            }
        }
        base_tools = try filtered_tools.toOwnedSlice(allocator);
    }

    // Sub-agents cannot spawn more sub-agents - strip spawn_sub_agent to prevent infinite recursion
    if (is_sub_agent) {
        var filtered: std.ArrayList(tool_models.AgentTool) = std.ArrayList(tool_models.AgentTool).empty;
        defer filtered.deinit(allocator);
        for (base_tools) |tool| {
            if (!std.mem.eql(u8, tool.function.name, "spawn_sub_agent")) {
                try filtered.append(allocator, tool);
            }
        }
        base_tools = try filtered.toOwnedSlice(allocator);
    }

    // Merge base tools and MCP tools
    var all_tools_list: std.ArrayList(tool_models.AgentTool) = std.ArrayList(tool_models.AgentTool).empty;
    defer all_tools_list.deinit(allocator);
    try all_tools_list.appendSlice(allocator, base_tools);
    try all_tools_list.appendSlice(allocator, mcp_tools);

    return try all_tools_list.toOwnedSlice(allocator);
}

pub const RunParams = struct {
    parent_allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
};

pub const TUIWorkflow = struct {
    // allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    config: *const config_mod.LlmConfig,
    logger: *logger_mod.Logger,

    pub fn init(db: *sqlite.SqliteBackend, config: *const config_mod.LlmConfig, logger: *logger_mod.Logger) TUIWorkflow {
        return .{
            .db = db,
            .config = config,
            .logger = logger,
        };
    }

    pub fn runAgenticSimpleStep(self: *TUIWorkflow, params: RunParams) !void {
        // Single-step mode: only answer the question, no tool execution
        // Register this session for activity/cancellation tracking
        if (session_registry.get_global_registry()) |registry| {
            if (registry.isRegistered(params.session_id) == false) {
                try registry.register(params.session_id);
            }
        }

        // Also register in worker table for enrichment info
        llm_history.upsertWorker(params.parent_allocator, self.db, params.session_id, params.session_id, params.cwd) catch {
            self.logger.warnFmt("Failed to upsert worker info for {s}", .{params.session_id}) catch {};
        };

        // Cleanup on exit - unregister session
        defer {
            if (session_registry.get_global_registry()) |registry| {
                registry.markIdle(params.session_id);
                registry.markStopped(params.session_id);
                registry.unregister(params.session_id);
            }
            // Also remove from worker table
            llm_history.removeWorker(params.parent_allocator, self.db, params.session_id) catch {};
        }

        // Get current agent state
        const agent_state = try get_current_agent_by_session_id(
            params.parent_allocator,
            self.db,
            params.session_id,
        );
        const current_agent = agent_state.agent;
        const agent_temperature = agent_state.temperature;
        const isThinking = agent_state.is_thinking;

        var arenaAllocator = std.heap.ArenaAllocator.init(params.parent_allocator);
        defer arenaAllocator.deinit();
        const allocator = arenaAllocator.allocator();

        // Mark session as running
        if (session_registry.get_global_registry()) |registry| {
            registry.mark_running(params.session_id);
        }

        // Fetch MCP tools
        const mcp_tools_fetched = (buildMcpTools.buildMCPToolsRun(params.parent_allocator, self.config.mcpServers orelse .null) catch |err| blk: {
            self.logger.errFmt("Failed to load MCP tools: {s}", .{@errorName(err)}) catch {};
            break :blk null;
        }) orelse &[_]tool_models.AgentTool{};

        // Filter and merge tools
        const merged_tools = try filterAndMergeTools(params.parent_allocator, mcp_tools_fetched, params.allowed_tools, params.is_sub_agent);

        // Get messages from database
        const db_messages = try getMessages(allocator, self.db, params.session_id);
        defer {
            for (db_messages) |*msg| msg.deinit(allocator);
            allocator.free(db_messages);
        }

        // Build messages for LLM
        var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;
        defer messagesLists.deinit(allocator);
        const initialMessages = try buildMessages(allocator, self.db, params.cwd, params.session_id, db_messages, merged_tools);
        try messagesLists.appendSlice(allocator, initialMessages);

        // Call the dynamic agent (single call only)
        const res = self.callDynamicAgent(
            allocator,
            &messagesLists,
            agent_temperature,
            8000,
            isThinking,
            self.config.api_key,
            self.config.model,
            self.config.base_url,
            params.session_id,
            merged_tools,
        ) catch |err| {
            self.logger.errFmt("runAgenticSimpleStep: Error calling dynamic agent: {s}", .{@errorName(err)}) catch {};
            return err;
        };

        // Save assistant response to database
        _ = try llm_history.saveMessage(allocator, self.db, .{
            .session_id = params.session_id,
            .model = self.config.model,
            .cwd = params.cwd,
            .content = res.content,
            .reasoning_content = res.reasoning_content,
            .role = agent.Role.assistant.to_str(),
            .finish_reason = if (res.finish_reason) |fr| fr.to_str() else null,
            .tool_calls = null,
            .tool_call_id = null,
            .agent_name = current_agent,
            .loop_index = 0,
            .temperature = agent_temperature,
            .is_thinking = isThinking,
            .prompt_tokens = res.usage.prompt_tokens,
            .completion_tokens = res.usage.completion_tokens,
            .total_tokens = res.usage.total_tokens,
            .parent_id = params.parent_session_id,
            .parent_session_id = params.parent_session_id,
        });

        // Send SSE event with the response
        _ = try on_event_send_new(allocator, .{
            .session_id = params.session_id,
            .model = self.config.model,
            .cwd = params.cwd,
            .content = res.content,
            .reasoning_content = res.reasoning_content,
            .role = "assistant",
            .finish_reason = if (res.finish_reason) |fr| fr.to_str() else "stop",
            .tool_calls = null,
            .tool_call_id = null,
            .tool_name = null,
            .agent_name = current_agent,
            .loop_index = 0,
            .temperature = agent_temperature,
            .is_thinking = isThinking,
            .is_input = false,
            .is_output = true,
            .parent_session_id = params.parent_session_id,
            .parent_id = params.parent_session_id,
        });
    }

    pub fn runAgenticMultiStep(self: *TUIWorkflow, params: RunParams) !void {
        var is_have_queue_message = false;
        // Register this session for activity/cancellation tracking
        if (session_registry.get_global_registry()) |registry| {
            if (registry.isRegistered(params.session_id) == false) {
                try registry.register(params.session_id);
            }
        }

        // Also register in worker table for enrichment info
        llm_history.upsertWorker(params.parent_allocator, self.db, params.session_id, params.session_id, params.cwd) catch {
            self.logger.warnFmt("Failed to upsert worker info for {s}", .{params.session_id}) catch {};
        };

        // Ensure cleanup happens even on error - balances mark_running() and unregisters session
        defer {
            if (is_have_queue_message == false) {
                if (session_registry.get_global_registry()) |registry| {
                    registry.markIdle(params.session_id);
                    registry.markStopped(params.session_id);
                    registry.unregister(params.session_id);
                }
                // Also remove from worker table
                llm_history.removeWorker(params.parent_allocator, self.db, params.session_id) catch {};
            }
        }

        const initial_agent_state = try get_current_agent_by_session_id(
            params.parent_allocator,
            self.db,
            params.session_id,
        );
        const initial_agent = initial_agent_state.agent;

        if (session_registry.get_global_registry()) |registry| {
            const is_running = registry.is_running(params.session_id);
            if (is_running) {
                _ = registry.queueMessage(params.session_id, params.message);
                self.logger.debugFmt("WORKFLOW: queued message for session {s}", .{params.session_id}) catch {};
                is_have_queue_message = true;
                return;
            }

            _ = registry.queueMessage(params.session_id, params.message);
        }

        var retryCount: usize = 0;
        var current_max_tokens: usize = 8000;
        var loopCounter: u32 = 0;

        // Fetch MCP tools once before the loop - avoids repeated fetching and potential recursive spawning
        const mcp_tools_fetched = (buildMcpTools.buildMCPToolsRun(params.parent_allocator, self.config.mcpServers orelse .null) catch |err| blk: {
            self.logger.errFmt("Failed to load MCP tools: {s}", .{@errorName(err)}) catch {};
            break :blk null;
        }) orelse &[_]tool_models.AgentTool{};
        // Note: mcp_tools_fetched memory is managed by allocator

        // Filter and merge tools based on allowed_tools setting
        const merged_tools = try filterAndMergeTools(params.parent_allocator, mcp_tools_fetched, params.allowed_tools, params.is_sub_agent);

        // Handle body message - add as initial user message if provided
        if (params.body.len > 0) {
            if (session_registry.get_global_registry()) |registry| {
                _ = registry.queueMessage(params.session_id, params.body);
            }
        }

        while (true) {
            var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(params.parent_allocator);
            defer arenaAllocatorWhileLoop.deinit();
            const allocator = arenaAllocatorWhileLoop.allocator();

            if (session_registry.get_global_registry()) |registry| {
                if (registry.isCancelled(params.session_id)) {
                    _ = try self.logger.infoFmt("WORKFLOW CANCELLED while looping back for next API call...", .{});
                    break;
                }

                const queued_messages = registry.getQueueMessages(params.session_id);
                if (queued_messages) |messages| {
                    for (messages.items) |msg| {
                        _ = try llm_history.saveMessage(allocator, self.db, .{
                            .session_id = params.session_id,
                            .model = self.config.model,
                            .cwd = params.cwd,
                            .content = msg,
                            .reasoning_content = null,
                            .role = agent.Role.user.to_str(),
                            .finish_reason = "null",
                            .tool_calls = null,
                            .tool_call_id = null,
                            .agent_name = initial_agent,
                            .loop_index = 0,
                            .temperature = initial_agent_state.temperature,
                            .is_thinking = initial_agent_state.is_thinking,
                            .prompt_tokens = 0,
                            .completion_tokens = 0,
                            .total_tokens = 0,
                            .parent_id = params.parent_session_id,
                            .parent_session_id = params.parent_session_id,
                            .is_input = true,
                            .is_output = false,
                        });
                        _ = registry.deleteQueueMessages(params.session_id, msg);
                    }
                }
                registry.mark_running(params.session_id);
            }

            // Update worker activity in DB to show we're actively processing
            llm_history.updateWorkerActivity(allocator, self.db, params.session_id) catch {};

            loopCounter += 1;
            if (retryCount > 10) return error.TooManyRetries;

            // Fetch current agent fresh from DB each iteration
            const currentAgentState = try get_current_agent_by_session_id(
                allocator,
                self.db,
                params.session_id,
            );
            const current_agent = currentAgentState.agent;
            var agent_temperature = currentAgentState.temperature;
            var isThinking = currentAgentState.is_thinking;

            var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;

            const db_messages = try getMessages(allocator, self.db, params.session_id);
            defer {
                for (db_messages) |*msg| msg.deinit(allocator);
                allocator.free(db_messages);
            }
            const total_tokens = blk: {
                var max_token: u32 = 0;
                for (db_messages) |msg| {
                    if (msg.total_tokens > max_token) {
                        max_token = msg.total_tokens;
                    }
                }
                break :blk max_token;
            };
            const initialMessages = try buildMessages(allocator, self.db, params.cwd, params.session_id, db_messages, merged_tools);

            try messagesLists.appendSlice(allocator, initialMessages);

            self.logger.debugFmt("[COMPACTION] Total tokens from DB: {} ({} messages)", .{ total_tokens, messagesLists.items.len }) catch {};
            if (llm_models.is_do_compact(total_tokens, llm_models.get_model_token_count(self.config.model))) {
                self.logger.debugFmt("[COMPACTION] Threshold exceeded, triggering compaction", .{}) catch {};
                if (try self.callCompactAgent(messagesLists.items, allocator, self.config.api_key, self.config.model, self.config.base_url, params.cwd)) |compacted_xml| {
                    try self.compactMessageInMemory(allocator, &messagesLists, compacted_xml, params.session_id, self.config.model, params.cwd);
                }
            }

            const res_dynamic_agent = self.callDynamicAgent(allocator, &messagesLists, agent_temperature, current_max_tokens, isThinking, self.config.api_key, self.config.model, self.config.base_url, params.session_id, merged_tools) catch |err| {
                if (err == error.Cancelled) {
                    self.logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{params.session_id}) catch {};
                    break;
                }
                retryCount += 1;
                self.logger.errFmt("Error calling dynamic agent: {s} now retrying", .{@errorName(err)}) catch {};
                continue;
            };

            retryCount = 0;

            if (res_dynamic_agent.finish_reason) |finish_reason| {
                if (finish_reason == .stop) {
                    _ = try llm_history.saveMessage(allocator, self.db, .{
                        .session_id = params.session_id,
                        .model = self.config.model,
                        .cwd = params.cwd,
                        .content = res_dynamic_agent.content,
                        .reasoning_content = res_dynamic_agent.reasoning_content,
                        .role = agent.Role.assistant.to_str(),
                        .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                        .tool_calls = null,
                        .tool_call_id = null,
                        .agent_name = current_agent,
                        .loop_index = loopCounter,
                        .temperature = agent_temperature,
                        .is_thinking = isThinking,
                        .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
                        .completion_tokens = res_dynamic_agent.usage.completion_tokens,
                        .total_tokens = res_dynamic_agent.usage.total_tokens,
                        .parent_id = params.parent_session_id,
                        .parent_session_id = params.parent_session_id,
                    });

                    // Send SSE event directly with the agent's response content
                    // Don't use getLatestMessage as it might return wrong message if timestamps collide
                    _ = try on_event_send_new(allocator, .{
                        .session_id = params.session_id,
                        .model = self.config.model,
                        .cwd = params.cwd,
                        .content = res_dynamic_agent.content,
                        .reasoning_content = res_dynamic_agent.reasoning_content,
                        .role = "assistant",
                        .finish_reason = res_dynamic_agent.finish_reason.?.to_str(),
                        .tool_calls = null,
                        .tool_call_id = null,
                        .tool_name = null,
                        .agent_name = current_agent,
                        .loop_index = loopCounter,
                        .temperature = agent_temperature,
                        .is_thinking = isThinking,
                        .is_input = false,
                        .is_output = true,
                        .parent_session_id = params.parent_session_id,
                        .parent_id = params.parent_session_id,
                    });

                    const session_info = session_table.getSession(allocator, self.db, params.session_id) catch |err| {
                        self.logger.errFmt("Error getting session: {s}", .{@errorName(err)}) catch {};
                        break;
                    };

                    // Generate session name from first user message if this is the first response
                    if (session_info) |session| {
                        if (loopCounter == 1 and std.mem.eql(u8, session.name, "New Session")) {
                            self.generateSessionName(db_messages, allocator, self.config.api_key, self.config.model, self.config.base_url, params.session_id);
                        }
                    }

                    break;
                } else if (finish_reason == .length) {
                    current_max_tokens += 4096;
                    _ = try self.logger.debugFmt("Increased max tokens to {d}", .{current_max_tokens});
                    continue;
                } else if (finish_reason == .tool_calls) {
                    try handle_tool(allocator, self.db, self.logger, params.session_id, params.parent_session_id, self.config.model, params.cwd, loopCounter, res_dynamic_agent, &agent_temperature, &isThinking, self.config.api_key, self.config.base_url, self.config, merged_tools, &messagesLists);
                } else if (finish_reason == .assistant) {
                    if (res_dynamic_agent.tool_calls != null and res_dynamic_agent.tool_calls.?.len > 0) {
                        try handle_tool(allocator, self.db, self.logger, params.session_id, params.parent_session_id, self.config.model, params.cwd, loopCounter, res_dynamic_agent, &agent_temperature, &isThinking, self.config.api_key, self.config.base_url, self.config, merged_tools, &messagesLists);
                    } else {
                        // Treat as normal completion
                        _ = try llm_history.saveMessage(allocator, self.db, .{
                            .session_id = params.session_id,
                            .model = self.config.model,
                            .cwd = params.cwd,
                            .content = res_dynamic_agent.content,
                            .reasoning_content = res_dynamic_agent.reasoning_content,
                            .role = agent.Role.assistant.to_str(),
                            .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                            .tool_calls = null,
                            .tool_call_id = null,
                            .agent_name = current_agent,
                            .loop_index = loopCounter,
                            .temperature = agent_temperature,
                            .is_thinking = isThinking,
                            .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
                            .completion_tokens = res_dynamic_agent.usage.completion_tokens,
                            .total_tokens = res_dynamic_agent.usage.total_tokens,
                            .parent_id = params.parent_session_id,
                            .parent_session_id = params.parent_session_id,
                        });

                        // Send SSE event directly with the agent's response content
                        // Don't use getLatestMessage as it might return wrong message if timestamps collide
                        _ = try on_event_send_new(allocator, .{
                            .session_id = params.session_id,
                            .model = self.config.model,
                            .cwd = params.cwd,
                            .content = res_dynamic_agent.content,
                            .reasoning_content = res_dynamic_agent.reasoning_content,
                            .role = "assistant",
                            .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                            .tool_calls = null,
                            .tool_call_id = null,
                            .tool_name = null,
                            .agent_name = current_agent,
                            .loop_index = loopCounter,
                            .temperature = agent_temperature,
                            .is_thinking = isThinking,
                            .is_input = false,
                            .is_output = true,
                            .parent_session_id = params.parent_session_id,
                            .parent_id = params.parent_session_id,
                        });
                        break;
                    }
                } else {
                    retryCount += 1;
                    self.logger.errFmt("Error calling agent: maybe streaming failed", .{}) catch {};
                    on_event_send_new(allocator, .{
                        .session_id = params.session_id,
                        .model = self.config.model,
                        .cwd = params.cwd,
                        .content = null,
                        .reasoning_content = null,
                        .role = null,
                        .finish_reason = "stop",
                        .tool_calls = null,
                        .tool_call_id = null,
                        .tool_name = null,
                        .agent_name = current_agent,
                        .loop_index = loopCounter,
                        .temperature = agent_temperature,
                        .is_thinking = isThinking,
                        .is_input = false,
                        .is_output = false,
                        .parent_session_id = params.parent_session_id,
                        .parent_id = params.parent_session_id,
                    }) catch {};
                    break;
                }

                retryCount = 0;
            }

            // Log if finish_reason is null
            if (res_dynamic_agent.finish_reason == null) {
                self.logger.warnFmt("WORKFLOW: finish_reason is NULL!", .{}) catch {};
            }
        }

        _ = try self.logger.debugFmt("WORKFLOW: exiting while loop for session_id {s}", .{params.session_id});
    }
    fn callDynamicAgent(
        _: *TUIWorkflow,
        allocator: std.mem.Allocator,
        messages_list: *std.ArrayList(agent.AgentMessage),
        agent_temperature: f32,
        current_max_tokens: usize,
        isThinking: bool,
        api_key: []const u8,
        model: []const u8,
        base_url: []const u8,
        session_id: []const u8,
        tools: []const tool_models.AgentTool,
    ) !agent.CallResponse {
        var dynamic_agent = try agent.Agent.init(allocator);
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

    /// Call CompactionAgent to compress conversation history
    fn callCompactAgent(
        self: *TUIWorkflow,
        messages: []agent.AgentMessage,
        arena: std.mem.Allocator,
        api_key: []const u8,
        model: []const u8,
        base_url: []const u8,
        cwd: []const u8,
    ) !?[]const u8 {
        // Serialize messages as-is for CompactionAgent to reason over
        var history_buf: std.ArrayList(u8) = .empty;
        defer history_buf.deinit(arena);
        var w = history_buf.writer(arena);

        try w.print("Working directory: {s}\n", .{cwd});
        try w.print("Current context size: {} messages\n\n", .{messages.len});

        // Include system prompt so CompactionAgent knows what tools/constraints exist
        if (messages.len > 0) {
            if (messages[0].content) |system_content| {
                try w.writeAll("=== SYSTEM PROMPT (for context) ===\n");
                // Truncate system prompt to avoid token explosion
                const max_len = 8000;
                if (system_content.len > max_len) {
                    try w.writeAll("System prompt (truncated): ");
                    try w.writeAll(system_content[0..max_len]);
                    try w.writeAll("\n... [truncated]\n");
                } else {
                    try w.writeAll(system_content);
                }
                try w.writeAll("\n=== END SYSTEM PROMPT ===\n\n");
            }
        }

        try w.writeAll("Conversation history to compact:\n\n");

        for (messages, 0..) |msg, i| {
            if (i == 0) continue; // System prompt already included above

            if (msg.role == .tool) {
                try w.print("--- Message {} (tool_result id:{s}) ---\n", .{ i, msg.tool_call_id orelse "unknown" });
                if (msg.content) |c| try w.writeAll(c);
            } else if (msg.reasoning_content) |rc| {
                try w.print("--- Message {} ({s}) ---\n", .{ i, msg.role.to_str() });
                try w.writeAll("[REASONING]\n");
                try w.writeAll(rc);
                if (msg.content) |c| {
                    try w.writeAll("\n[RESPONSE]\n");
                    try w.writeAll(c);
                }
            } else if (msg.tool_calls) |tcs| {
                try w.print("--- Message {} ({s}) ---\n", .{ i, msg.role.to_str() });
                try w.writeAll("[TOOL CALLS]\n");
                for (tcs) |tc| {
                    try w.print("  - {s}({s})\n", .{ tc.function.name, tc.function.arguments });
                }
            } else if (msg.content) |c| {
                try w.print("--- Message {} ({s}) ---\n", .{ i, msg.role.to_str() });
                try w.writeAll(c);
            }

            try w.writeAll("\n");
        }

        // Add file listing to give CompactionAgent project awareness
        try w.writeAll("\n=== PROJECT FILE LISTING ===\n");
        try self.addFileListing(w, cwd, arena);

        const compaction_messages = try arena.alloc(agent.AgentMessage, 2);
        compaction_messages[0] = .{ .role = .system, .content = prompt.CompactionAgent };
        compaction_messages[1] = .{ .role = .user, .content = try history_buf.toOwnedSlice(arena) };

        var compaction_agent = try agent.Agent.init(arena);
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

        self.logger.debugFmt("[COMPACTION] Calling CompactionAgent ({} messages)", .{
            messages.len,
        }) catch {};

        // Use callStreaming for compaction agent - no-op callback since we don't need to stream to client
        const response = compaction_agent.callStreaming(params, null, noopStreamCallback) catch |err| {
            self.logger.errFmt("[COMPACTION] Failed: {s}", .{@errorName(err)}) catch {};
            return null;
        };
        defer response.deinit();

        if (response.content) |content| {
            self.logger.debugFmt("[COMPACTION] Done: {} messages -> {} bytes", .{
                messages.len,
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
    }

    /// Generate session name from the first user message using LLM
    fn generateSessionName(
        self: *TUIWorkflow,
        db_messages: []TUIHistory,
        allocator: std.mem.Allocator,
        api_key: []const u8,
        model: []const u8,
        base_url: []const u8,
        session_id: []const u8,
    ) void {
        // Find the first user message from db_messages (TUIHistory)
        var first_user_message: ?[]const u8 = null;
        for (db_messages) |msg| {
            // role is stored as string "user" in TUIHistory
            if (std.mem.eql(u8, msg.role, "user") and msg.response_content.len > 0) {
                first_user_message = msg.response_content;
                break;
            }
        }

        if (first_user_message == null) {
            self.logger.debugFmt("No user message found in db_messages", .{}) catch {};
            return;
        }

        // Build messages for the name generation prompt
        const name_messages = allocator.alloc(agent.AgentMessage, 2) catch return;
        name_messages[0] = .{ .role = .system, .content = prompt.GenerateSessionNameAgent };
        name_messages[1] = .{ .role = .user, .content = first_user_message.? };

        var name_agent = agent.Agent.init(allocator) catch return;
        defer name_agent.deinit();
        name_agent.apiKey = api_key;
        name_agent.model = model;
        name_agent.baseUrl = base_url;

        const params = agent.AgentCall{
            .tools = &.{},
            .messages = name_messages,
        };

        const response = name_agent.callStreaming(params, null, noopStreamCallback) catch {
            self.logger.errFmt("[SESSION NAME] Failed to call LLM for session name", .{}) catch {};
            return;
        };
        defer response.deinit();

        if (response.content) |content| {
            // Trim and limit to 50 chars
            var trimmed = std.mem.trim(u8, content, " \n\t");
            if (trimmed.len > 50) {
                trimmed = trimmed[0..50];
            }
            if (trimmed.len > 0) {
                // Update session name in database
                session_table.updateSessionName(allocator, self.db, session_id, trimmed) catch {
                    self.logger.errFmt("[SESSION NAME] Failed to update session name: {s}", .{trimmed}) catch {};
                    return;
                };
                self.logger.debugFmt("[SESSION NAME] Generated session name: {s}", .{trimmed}) catch {};
            }
        }
    }

    /// Compact messages in memory based on CompactionAgent output
    /// Also persists to database: marks old messages as not for LLM, saves new compacted message
    fn compactMessageInMemory(
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
        try mark_messages_not_for_llm.mark_message_not_for_llm_run(allocator, self.db, session_id);

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

        const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, is_feed_to_llm, agent, loop_index, created_at, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)";
        try self.db.exec(allocator, sql, &.{ id, session_id, model, summary_content, "stop", "user", "", "", "Agent", "0", created_at, "1", "0", "" });

        // Update the session's cwd in the sessions table
        const copy_cwd = try std.heap.c_allocator.dupe(u8, cwd);
        defer std.heap.c_allocator.free(copy_cwd);
        try self.db.exec(allocator, "UPDATE sessions SET cwd = ? WHERE id = ?", &.{ copy_cwd, session_id });

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

    /// Add a file listing to the writer for project context
    fn addFileListing(self: *TUIWorkflow, w: anytype, cwd: []const u8, arena: std.mem.Allocator) !void {
        inline for (.{ ".zig", ".c", ".h", ".cpp", ".js", ".ts", ".json", ".md", ".txt", ".toml", ".yaml", ".yml" }) |ext| {
            try self.findFilesWithExtension(w, cwd, ext, arena, 0, 3);
        }
    }

    /// Recursively find files with specific extension
    fn findFilesWithExtension(self: *TUIWorkflow, w: anytype, dir_path: []const u8, ext: []const u8, arena: std.mem.Allocator, depth: usize, max_depth: usize) !void {
        if (depth > max_depth) return;

        var dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
        defer dir.close();

        var iterator = dir.iterate();
        while (iterator.next() catch null) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (std.mem.eql(u8, entry.name, "node_modules")) continue;
            if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;
            if (std.mem.eql(u8, entry.name, ".cache")) continue;
            if (entry.name[0] == '.') continue;

            if (entry.kind == .directory) {
                const subdir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
                defer arena.free(subdir);
                try self.findFilesWithExtension(w, subdir, ext, arena, depth + 1, max_depth);
            } else if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.name, ext)) {
                    const rel_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
                    defer arena.free(rel_path);
                    try w.print("  {s}\n", .{rel_path});
                }
            }
        }
    }
};
