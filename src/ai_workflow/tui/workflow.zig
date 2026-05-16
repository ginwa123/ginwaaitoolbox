const json = std.json;

const nalar_mod = @import("nalarcore");
const llm_history = @import("llm_history.zig");
const build_msg_prompt = @import("build_messages_for_agent_prompt.zig");
const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;
const models = @import("models.zig");
const on_event_sent = @import("on_event_sent.zig");
const tool_registry = @import("tool_registry.zig");
const handle_tool = @import("handle_tool.zig").handle_tool;
const session_table = @import("session_table.zig");

const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const config_mod = nalarcore.config;
const logger_mod = nalarcore.logger;
const agent = nalarcore.agent;
const prompt = nalarcore.agent.prompt;
const helpers = nalarcore.helpers;

const std = @import("std");
// Thread-safe set of active session loop IDs
pub const StreamingContext = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8 = "",
    chunk_index: usize = 0,
};

pub const CallbackAiWorkerFlow = struct {
    pub fn callback(data: RunParamsNew) void {
        const di = nalar_mod.getSingleton() catch return;
        const logger = di.logger;
        runAgenticMultiStepnew(di, data) catch |err| {
            logger.errFmt("runAgenticMultiStepnew failed: {s}", .{@errorName(err)});
        };
    }
};

pub fn runAgenticMultiStepnew(di: *nalar_mod.ContextIPCTui, params: RunParamsNew) !void {
    var parent_arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
    defer parent_arena_allocator.deinit();
    const parent_allocator = parent_arena_allocator.allocator();

    const db = di.db;
    const logger = di.logger;
    const active_loops = di.active_loops;
    const io = di.io;
    const config = di.llm_config;
    const environment = di.environment;

    const copy_parent_session_id = try parent_allocator.dupe(u8, params.parent_session_id);
    const copy_session_id = try parent_allocator.dupe(u8, params.session_id);
    const copy_message = try parent_allocator.dupe(u8, params.message);
    const copy_cwd = try parent_allocator.dupe(u8, params.cwd);
    // const copy_body = try parent_allocator.dupe(u8, params.body);
    const copy_allowed_tools = try parent_allocator.dupe(u8, params.allowed_tools);
    const copy_is_sub_agent = params.is_sub_agent;

    var is_have_queue_message = false;

    // Ensure cleanup happens even on error - remove from worker table
    defer {
        is_have_queue_message = llm_history.hasQueuedMessages(db, copy_session_id);
        if (is_have_queue_message == false) {
            llm_history.markSessionIdle(parent_allocator, db, copy_session_id) catch |err| {
                logger.errFmt("Failed to mark session idle: {s}", .{@errorName(err)});
            };
        }
    }

    const initial_agent_state = try llm_history.get_current_agent_by_session_id(
        parent_allocator,
        db,
        copy_session_id,
    );
    const initial_agent = initial_agent_state.agent;

    // Check if session is already running (exists in worker table)
    if (llm_history.isSessionRunning(db, copy_session_id) and active_loops.contains(io, copy_session_id)) {
        // Session is already running, queue the message
        llm_history.queueMessage(parent_allocator, db, copy_session_id, copy_message) catch {
            logger.warnFmt("Failed to queue message for session {s}", .{copy_session_id});
        };
        logger.debugFmt("WORKFLOW: queued message for session {s}", .{copy_session_id});
        is_have_queue_message = true;
        return;
    }
    defer active_loops.remove(io, copy_session_id);

    // Register in worker table (upsertWorker already does this)
    llm_history.upsertWorker(parent_allocator, db, copy_session_id, copy_session_id, copy_cwd) catch {
        logger.warnFmt("Failed to upsert worker info for {s}", .{copy_session_id});
    };

    // Queue the initial message
    llm_history.queueMessage(parent_allocator, db, copy_session_id, copy_message) catch {
        logger.warnFmt("Failed to queue initial message for session {s}", .{copy_session_id});
    };

    var retry_count: usize = 0;
    var current_max_tokens: usize = 8000;
    var loop_counter: u32 = 0;

    // Fetch MCP tools once before the loop - avoids repeated fetching and potential recursive spawning
    const mcp_tools_fetched = (build_msg_prompt.buildMCPToolsRun(parent_allocator, io, config.mcpServers orelse .null) catch |err| blk: {
        logger.errFmt("Failed to load MCP tools: {s}", .{@errorName(err)});
        break :blk null;
    }) orelse &[_]agent.AgentTool{};
    // Note: mcp_tools_fetched memory is managed by allocator

    // Filter and merge tools based on allowed_tools setting
    const merged_tools = try filterAndMergeTools(parent_allocator, mcp_tools_fetched, copy_allowed_tools, copy_is_sub_agent);

    // Debug: check merged_tools
    std.debug.print("DEBUG_MERGE: merged_tools count={d}\n", .{merged_tools.len});

    while (true) {
        _ = active_loops.tryInsert(io, copy_session_id);
        var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(parent_allocator);
        defer arenaAllocatorWhileLoop.deinit();
        const allocator = arenaAllocatorWhileLoop.allocator();

        // Check cancellation using DB
        if (llm_history.isSessionCancelled(db, copy_session_id)) {
            logger.infoFmt("WORKFLOW CANCELLED while looping back for next API call...", .{});
            break;
        }

        // Get queued messages from DB
        var queued_messages = try llm_history.getQueueMessages(allocator, db, copy_session_id);
        if (queued_messages) |*messages| {
            for (messages.items) |msg| {
                _ = try llm_history.saveMessage(allocator, io, db, .{
                    .session_id = copy_session_id,
                    .model = config.model,
                    .cwd = copy_cwd,
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
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .is_input = true,
                    .is_output = false,
                });

                on_event_sent.onEventSendLLMHistory(allocator, .{
                    .session_id = copy_session_id,
                    .model = config.model,
                    .cwd = copy_cwd,
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
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .is_input = true,
                    .is_output = false,
                }) catch {};

                _ = try llm_history.deleteQueuedMessage(allocator, db, copy_session_id, msg);
            }
        }

        // Update worker activity in DB to show we're actively processing
        llm_history.updateWorkerActivity(allocator, db, copy_session_id) catch {};

        if (retry_count > 10) return error.TooManyRetries;

        // Fetch current agent fresh from DB each iteration
        const currentAgentState = try llm_history.get_current_agent_by_session_id(
            allocator,
            db,
            copy_session_id,
        );
        const current_agent = currentAgentState.agent;
        var agent_temperature = currentAgentState.temperature;
        var isThinking = currentAgentState.is_thinking;

        var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;

        const db_messages = try llm_history.getMessages(allocator, db, copy_session_id);
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
        loop_counter = blk: {
            var max_loop_counter: u32 = 0;
            for (db_messages) |msg| {
                if (msg.loop_index > max_loop_counter) {
                    max_loop_counter = msg.loop_index;
                }
            }

            break :blk max_loop_counter;
        };
        loop_counter += 1;
        if (loop_counter == 1) {
            generateSessionNameNew(db_messages, allocator, config.api_key, config.model, config.base_url, copy_session_id, logger, io, db);
        }

        const initialMessages = try build_msg_prompt.buildMessages(allocator, io, db, copy_cwd, copy_session_id, db_messages, merged_tools);

        try messagesLists.appendSlice(allocator, initialMessages);

        logger.debugFmt("[COMPACTION] Total tokens from DB: {} ({} messages)", .{ total_tokens, messagesLists.items.len });
        if (agent.LLMModels.is_do_compact(total_tokens, agent.LLMModels.get_model_token_count(config.model))) {
            if (callCompactAgentNew(messagesLists.items, allocator, config.api_key, config.model, config.base_url, copy_cwd, logger, io )) |compacted_xml| {
                try compactMessageInMemoryNew(allocator, &messagesLists, compacted_xml, copy_session_id, config.model, copy_cwd, db, io, logger);
            }
        }

        const res_dynamic_agent = callDynamicAgentNew(allocator, io, &messagesLists, agent_temperature, current_max_tokens, isThinking, config.api_key, config.model, config.base_url, copy_session_id, merged_tools) catch |err| {
            if (err == error.Cancelled) {
                logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
                break;
            }
            retry_count += 1;
            logger.errFmt("Error calling dynamic agent: {s} now retrying", .{@errorName(err)});
            continue;
        };

        retry_count = 0;

        if (res_dynamic_agent.finish_reason) |finish_reason| {
            if (finish_reason == .stop) {
                _ = try llm_history.saveMessage(allocator, io, db, .{
                    .session_id = copy_session_id,
                    .model = config.model,
                    .cwd = copy_cwd,
                    .content = res_dynamic_agent.content,
                    .reasoning_content = res_dynamic_agent.reasoning_content,
                    .role = agent.Role.assistant.to_str(),
                    .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                    .tool_calls = null,
                    .tool_call_id = null,
                    .agent_name = current_agent,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
                    .completion_tokens = res_dynamic_agent.usage.completion_tokens,
                    .total_tokens = res_dynamic_agent.usage.total_tokens,
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                });

                // Send SSE event directly with the agent's response content
                // Don't use getLatestMessage as it might return wrong message if timestamps collide
                _ = try on_event_sent.onEventSendLLMHistory(allocator, .{
                    .session_id = copy_session_id,
                    .model = config.model,
                    .cwd = copy_cwd,
                    .content = res_dynamic_agent.content,
                    .reasoning_content = res_dynamic_agent.reasoning_content,
                    .role = agent.Role.assistant.to_str(),
                    .finish_reason = res_dynamic_agent.finish_reason.?.to_str(),
                    .tool_calls = null,
                    .tool_call_id = null,
                    .tool_name = null,
                    .agent_name = current_agent,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .is_input = false,
                    .is_output = true,
                    .parent_session_id = copy_parent_session_id,
                    .parent_id = copy_parent_session_id,
                    .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
                });

                const isHaveQueueMessage = llm_history.hasQueuedMessages(db, copy_session_id);
                if (isHaveQueueMessage) {
                    continue;
                }

                break;
            } else if (finish_reason == .length) {
                current_max_tokens += 4096;
                logger.debugFmt("Increased max tokens to {d}", .{current_max_tokens});
                continue;
            } else if (finish_reason == .tool_calls) {
                std.debug.print("DEBUG_WORKFLOW: finish_reason == .tool_calls, calling handle_tool\n", .{});
                try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, config.model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, active_loops);
            } else if (finish_reason == .assistant) {
                if (res_dynamic_agent.tool_calls != null and res_dynamic_agent.tool_calls.?.len > 0) {
                    try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, config.model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, active_loops);
                } else {
                    // Treat as normal completion
                    _ = try llm_history.saveMessage(allocator, io, db, .{
                        .session_id = copy_session_id,
                        .model = config.model,
                        .cwd = copy_cwd,
                        .content = res_dynamic_agent.content,
                        .reasoning_content = res_dynamic_agent.reasoning_content,
                        .role = agent.Role.assistant.to_str(),
                        .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                        .tool_calls = null,
                        .tool_call_id = null,
                        .agent_name = current_agent,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature,
                        .is_thinking = isThinking,
                        .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
                        .completion_tokens = res_dynamic_agent.usage.completion_tokens,
                        .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
                        .parent_id = copy_parent_session_id,
                        .parent_session_id = copy_parent_session_id,
                    });

                    // Send SSE event directly with the agent's response content
                    // Don't use getLatestMessage as it might return wrong message if timestamps collide
                    _ = try on_event_sent.onEventSendLLMHistory(allocator, .{
                        .session_id = copy_session_id,
                        .model = config.model,
                        .cwd = copy_cwd,
                        .content = res_dynamic_agent.content,
                        .reasoning_content = res_dynamic_agent.reasoning_content,
                        .role = "assistant",
                        .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                        .tool_calls = null,
                        .tool_call_id = null,
                        .tool_name = null,
                        .agent_name = current_agent,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature,
                        .is_thinking = isThinking,
                        .is_input = false,
                        .is_output = true,
                        .parent_session_id = copy_parent_session_id,
                        .parent_id = copy_parent_session_id,
                        .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
                    });

                    const isHaveQueueMessage = llm_history.hasQueuedMessages(db, copy_session_id);
                    if (isHaveQueueMessage) {
                        continue;
                    }

                    break;
                }
            } else {
                retry_count += 1;
                logger.errFmt("Error calling agent: maybe streaming failed", .{});
                on_event_sent.onEventSendLLMHistory(allocator, .{
                    .session_id = copy_session_id,
                    .model = config.model,
                    .cwd = copy_cwd,
                    .content = null,
                    .reasoning_content = null,
                    .role = null,
                    .finish_reason = "stop",
                    .tool_calls = null,
                    .tool_call_id = null,
                    .tool_name = null,
                    .agent_name = current_agent,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .is_input = false,
                    .is_output = false,
                    .parent_session_id = copy_parent_session_id,
                    .parent_id = copy_parent_session_id,
                }) catch {};
                break;
            }

            retry_count = 0;
        }

        // Log if finish_reason is null
        if (res_dynamic_agent.finish_reason == null) {
            logger.warnFmt("WORKFLOW: finish_reason is NULL!", .{});
        }
    }

    logger.debugFmt("WORKFLOW: exiting while loop for session_id {s}", .{copy_session_id});
}

fn generateSessionNameNew(
    db_messages: []models.TUIHistory,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    session_id: []const u8,
    logger: *logger_mod.Logger,
    io: std.Io,
    db: *sqlite.SqliteBackend,
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
        logger.debugFmt("No user message found in db_messages", .{});
        return;
    }

    // Build messages for the name generation prompt
    const name_messages = allocator.alloc(agent.AgentMessage, 2) catch return;
    name_messages[0] = .{ .role = .system, .content = prompt.GenerateSessionNameAgent };
    name_messages[1] = .{ .role = .user, .content = first_user_message.? };

    var name_agent = agent.Agent.init(allocator, io) catch return;
    defer name_agent.deinit();
    name_agent.apiKey = api_key;
    name_agent.model = model;
    name_agent.baseUrl = base_url;

    const params = agent.AgentCall{
        .tools = &.{},
        .messages = name_messages,
    };

    const response = name_agent.callStreaming(params, null, noopStreamCallbackNew) catch {
        logger.errFmt("[SESSION NAME] Failed to call LLM for session name", .{});
        return;
    };
    defer response.deinit();

    if (response.content) |content| {
        // Strip thinking tags if present, fallback to original content on error
        var stripped_content: []const u8 = content;
        var needs_free = false;
        if (helpers.xml.stripThinkingTags(content, allocator)) |stripped| {
            stripped_content = stripped;
            needs_free = true;
        } else |err| {
            logger.warnFmt("[SESSION NAME] Failed to strip thinking tags: {s}, using original content", .{@errorName(err)});
        }

        // limit to 50 chars
        if (stripped_content.len > 50) {
            stripped_content = stripped_content[0..50];
        }

        // Update session name in database
        session_table.updateSessionName(allocator, db, session_id, stripped_content) catch {
            logger.errFmt("[SESSION NAME] Failed to update session name: {s}", .{stripped_content});
            if (needs_free) allocator.free(stripped_content);
            return;
        };
        logger.debugFmt("[SESSION NAME] Generated session name: {s}", .{stripped_content});
        if (needs_free) allocator.free(stripped_content);
    }
}

fn callDynamicAgentNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    messages_list: *std.ArrayList(agent.AgentMessage),
    agent_temperature: f32,
    current_max_tokens: usize,
    isThinking: bool,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    session_id: []const u8,
    tools: []const agent.AgentTool,
) !agent.CallResponse {
    var dynamic_agent = try agent.Agent.init(allocator, io);
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

/// Call CompactionAgent to compress conversation history.
/// Returns compacted context or null on failure.
pub fn callCompactAgentNew(
    messages: []agent.AgentMessage,
    arena: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    cwd: []const u8,
    logger: *logger_mod.Logger,
    io: std.Io,
) ?[]const u8 {
    _ = cwd;
    logger.infoFmt("[COMPACTION] Starting callCompactAgent", .{});

    // Serialize messages for CompactionAgent
    var history: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &history);
    const w = &aw.writer; // *std.Io.Writer — use this for all writes

    w.writeAll("Conversation history to compact:\n\n") catch |err| {
        logger.errFmt("[COMPACTION] Failed to write history header: {s}", .{@errorName(err)});
        return null;
    };

    for (messages[1..], 1..) |msg, i| {
        _ = i;
        if (msg.content) |c| w.writeAll(c) catch |err| {
            logger.errFmt("[COMPACTION] Failed to write tool msg content: {s}", .{@errorName(err)});
            return null;
        };
    }

    // Transfer ownership back from the Allocating writer to the ArrayList
    history = aw.toArrayList();
    defer history.deinit(arena);

    logger.infoFmt("[COMPACTION] Building compaction messages...", .{});
    const msgs = arena.alloc(agent.AgentMessage, 2) catch |err| {
        logger.errFmt("[COMPACTION] Failed to alloc msgs: {s}", .{@errorName(err)});
        return null;
    };
    msgs[0] = .{ .role = .system, .content = prompt.CompactionAgent };

    // Slice is arena-owned, safe to use directly
    const history_content = history.items;
    msgs[1] = .{ .role = .user, .content = history_content };
    logger.infoFmt("[COMPACTION] History content: {} bytes", .{history_content.len});

    logger.infoFmt("[COMPACTION] Initializing compaction agent...", .{});
    var compaction_agent = agent.Agent.init(arena, io) catch |err| {
        logger.errFmt("[COMPACTION] Agent.init failed: {s}", .{@errorName(err)});
        return null;
    };
    defer compaction_agent.deinit();
    compaction_agent.apiKey = api_key;
    compaction_agent.model = model;
    compaction_agent.baseUrl = base_url;

    logger.infoFmt("[COMPACTION] Calling callStreaming...", .{});
    const response = compaction_agent.callStreaming(.{
        .tools = &.{},
        .messages = msgs,
        .temperature = 0.0,
    }, null, noopStreamCallbackNew) catch |err| {
        logger.errFmt("[COMPACTION] callStreaming failed: {s}", .{@errorName(err)});
        return null;
    };
    logger.infoFmt("[COMPACTION] callStreaming succeeded", .{});
    defer response.deinit();

    logger.infoFmt("[COMPACTION] Response content null? {}", .{response.content == null});
    const content = response.content orelse {
        logger.errFmt("[COMPACTION] Response content is null", .{});
        return null;
    };

    if (content.len == 0) {
        logger.warnFmt("[COMPACTION] Empty response from CompactionAgent", .{});
        return null;
    }

    logger.infoFmt("[COMPACTION] Got response: {} bytes", .{content.len});
    logger.debugFmt("[COMPACTION] Done: {} messages -> {} bytes", .{ messages.len, content.len });

    const duplicated = arena.dupe(u8, content) catch |err| {
        logger.errFmt("[COMPACTION] Failed to duplicate content: {s}", .{@errorName(err)});
        return null;
    };
    logger.infoFmt("[COMPACTION] callCompactAgent returning success", .{});
    return duplicated;
}

/// Compact messages in memory based on CompactionAgent output
/// Also persists to database: marks old messages as not for LLM, saves new compacted message
pub fn compactMessageInMemoryNew(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(agent.AgentMessage),
    compacted_xml: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *logger_mod.Logger,
) !void {
    const total = messages.items.len;
    if (total <= 4) return;

    // Mark all existing messages in this session as not for LLM (soft-delete)
    try llm_history.mark_message_not_for_llm_run(allocator, db, session_id);

    // Build the compacted summary content
    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(allocator);
    try summary.print(allocator, "[CONTEXT SUMMARY]\n\n", .{});
    try summary.print(allocator, "{s}", .{compacted_xml});
    const summary_content = try summary.toOwnedSlice(allocator);

    // Save the compacted summary to the database with is_feed_to_llm = 1
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000)});
    defer allocator.free(created_at);

    const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, is_feed_to_llm, agent, loop_index, created_at, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)";
    try db.exec(allocator, sql, &.{ id, session_id, model, summary_content, "stop", "user", "", "", "Agent", "0", created_at, "1", "0", "" });

    // Update the session's cwd in the sessions table
    const copy_cwd = try std.heap.c_allocator.dupe(u8, cwd);
    defer std.heap.c_allocator.free(copy_cwd);
    try db.exec(allocator, "UPDATE sessions SET cwd = ? WHERE id = ?", &.{ copy_cwd, session_id });

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

    logger.debugFmt("[COMPACTION] Compacted: {} -> {} messages (persisted to DB)", .{ total, messages.items.len });
}

fn noopStreamCallbackNew(_: ?*anyopaque, _: agent.StreamChunk) void {}

/// Callback for streaming chunks - sends each chunk to the client via SSE
pub fn stream_callback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    if (ctx == null) return;

    const stream_ctx = @as(*StreamingContext, @ptrCast(@alignCast(ctx.?)));
    const allocator = stream_ctx.allocator;
    const session_id = stream_ctx.session_id;

    // Handle done marker - no data to send
    if (chunk.done) {
        stream_ctx.chunk_index = 0;
        return;
    }

    // Send content chunk if present
    if (chunk.content) |content| {
        if (content.len > 0) {
            const content_chunk = on_event_sent.ContentChunk{
                .index = stream_ctx.chunk_index,
                .content = content,
            };
            on_event_sent.sendStreamChunkContent(allocator, session_id, content_chunk);
        }
    }

    // Send reasoning chunk if present
    if (chunk.reasoning_content) |reasoning| {
        if (reasoning.len > 0) {
            const reasoning_chunk = on_event_sent.ReasoningChunk{
                .index = stream_ctx.chunk_index,
                .reasoning = reasoning,
            };
            on_event_sent.sendStreamChunkReasoning(allocator, session_id, reasoning_chunk);
        }
    }

    // Send tool call delta chunk if present
    if (chunk.tool_calls_delta) |deltas| {
        if (deltas.len > 0) {
            const delta_chunk = on_event_sent.ToolCallDeltaChunk{
                .index = stream_ctx.chunk_index,
                .deltas = deltas,
            };
            on_event_sent.sendStreamToolCallDelta(allocator, session_id, delta_chunk);
        }
    }

    stream_ctx.chunk_index += 1;
}

/// Filter and merge tools based on allowed_tools setting
/// - allowed_tools: "" = no tools, "all" = all tools, comma-separated = specific tools
/// Returns filtered base tools merged with MCP tools
pub fn filterAndMergeTools(
    allocator: std.mem.Allocator,
    mcp_tools: []const agent.AgentTool,
    allowed_tools: []const u8,
    is_sub_agent: bool,
) ![]agent.AgentTool {
    var base_tools = try allocator.alloc(agent.AgentTool, tool_registry.allAgentTools(allocator).len);
    @memcpy(base_tools, tool_registry.allAgentTools(allocator));

    // Filter base tools if allowed_tools is specified
    if (allowed_tools.len > 0 and !std.mem.eql(u8, allowed_tools, "all")) {
        var allowed_tools_set: std.StringArrayHashMapUnmanaged(void) = .{};

        var it = std.mem.splitScalar(u8, allowed_tools, ',');
        while (it.next()) |tool_name| {
            const trimmed = std.mem.trim(u8, tool_name, " ");
            if (trimmed.len > 0) {
                try allowed_tools_set.put(allocator, trimmed, {});
            }
        }

        var filtered_tools: std.ArrayList(agent.AgentTool) = std.ArrayList(agent.AgentTool).empty;
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
        var filtered: std.ArrayList(agent.AgentTool) = std.ArrayList(agent.AgentTool).empty;
        defer filtered.deinit(allocator);
        for (base_tools) |tool| {
            if (!std.mem.eql(u8, tool.function.name, "spawn_sub_agent")) {
                try filtered.append(allocator, tool);
            }
        }
        base_tools = try filtered.toOwnedSlice(allocator);
    }

    // Merge base tools and MCP tools
    var all_tools_list: std.ArrayList(agent.AgentTool) = std.ArrayList(agent.AgentTool).empty;
    defer all_tools_list.deinit(allocator);
    try all_tools_list.appendSlice(allocator, base_tools);
    try all_tools_list.appendSlice(allocator, mcp_tools);

    return try all_tools_list.toOwnedSlice(allocator);
}

pub const RunParams = struct {
    ctxTui: *nalarcore.ContextIPCTui,

    parent_allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
};

pub const RunParamsNew = struct {
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
};

// pub const TUIWorkflow = struct {
//     io: std.Io,
//     db: *sqlite.SqliteBackend,
//     config: *config_mod.LlmConfig,
//     logger: *logger_mod.Logger,
//     environment: ?*const std.process.Environ.Map,
//     active_loops: *ActiveLoops,
//
//     pub fn init(tui_workflow: TUIWorkflow) TUIWorkflow {
//         return tui_workflow;
//     }
//
//     pub fn runAgenticMultiStep(self: *TUIWorkflow, params: RunParams) !void {
//         var is_have_queue_message = false;
//
//         // Ensure cleanup happens even on error - remove from worker table
//         defer {
//             is_have_queue_message = llm_history.hasQueuedMessages(self.db, params.session_id);
//             if (is_have_queue_message == false) {
//                 llm_history.markSessionIdle(params.parent_allocator, self.db, params.session_id) catch |err| {
//                     self.logger.errFmt("Failed to mark session idle: {s}", .{@errorName(err)});
//                 };
//             }
//         }
//
//         const initial_agent_state = try llm_history.get_current_agent_by_session_id(
//             params.parent_allocator,
//             self.db,
//             params.session_id,
//         );
//         const initial_agent = initial_agent_state.agent;
//
//         // Check if session is already running (exists in worker table)
//         if (llm_history.isSessionRunning(self.db, params.session_id) and self.active_loops.contains(self.io, params.session_id)) {
//             // Session is already running, queue the message
//             llm_history.queueMessage(params.parent_allocator, self.db, params.session_id, params.message) catch {
//                 self.logger.warnFmt("Failed to queue message for session {s}", .{params.session_id});
//             };
//             self.logger.debugFmt("WORKFLOW: queued message for session {s}", .{params.session_id});
//             is_have_queue_message = true;
//             return;
//         }
//         defer self.active_loops.remove(self.io, params.session_id);
//
//         // Register in worker table (upsertWorker already does this)
//         llm_history.upsertWorker(params.parent_allocator, self.db, params.session_id, params.session_id, params.cwd) catch {
//             self.logger.warnFmt("Failed to upsert worker info for {s}", .{params.session_id});
//         };
//
//         // Queue the initial message
//         llm_history.queueMessage(params.parent_allocator, self.db, params.session_id, params.message) catch {
//             self.logger.warnFmt("Failed to queue initial message for session {s}", .{params.session_id});
//         };
//
//         var retryCount: usize = 0;
//         var current_max_tokens: usize = 8000;
//         var loopCounter: u32 = 0;
//         var is_first_iteration: bool = true;
//
//         // Fetch MCP tools once before the loop - avoids repeated fetching and potential recursive spawning
//         const mcp_tools_fetched = (buildMcpTools.buildMCPToolsRun(params.parent_allocator, self.io, self.config.mcpServers orelse .null) catch |err| blk: {
//             self.logger.errFmt("Failed to load MCP tools: {s}", .{@errorName(err)});
//             break :blk null;
//         }) orelse &[_]tool_models.AgentTool{};
//         // Note: mcp_tools_fetched memory is managed by allocator
//
//         // Filter and merge tools based on allowed_tools setting
//         const merged_tools = try filterAndMergeTools(params.parent_allocator, mcp_tools_fetched, params.allowed_tools, params.is_sub_agent);
//
//         // Debug: check merged_tools
//         std.debug.print("DEBUG_MERGE: merged_tools count={d}\n", .{merged_tools.len});
//
//         // Handle body message - add as initial user message if provided
//         if (params.body.len > 0) {
//             llm_history.queueMessage(params.parent_allocator, self.db, params.session_id, params.body) catch {
//                 self.logger.warnFmt("Failed to queue body message for session {s}", .{params.session_id});
//             };
//         }
//
//         while (true) {
//             _ = self.active_loops.tryInsert(self.io, params.session_id);
//             var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(params.parent_allocator);
//             defer arenaAllocatorWhileLoop.deinit();
//             const allocator = arenaAllocatorWhileLoop.allocator();
//
//             // Check cancellation using DB
//             if (llm_history.isSessionCancelled(self.db, params.session_id)) {
//                 self.logger.infoFmt("WORKFLOW CANCELLED while looping back for next API call...", .{});
//                 break;
//             }
//
//             // Get queued messages from DB
//             var queued_messages = try llm_history.getQueueMessages(allocator, self.db, params.session_id);
//             if (queued_messages) |*messages| {
//                 for (messages.items) |msg| {
//                     _ = try llm_history.saveMessage(allocator, self.io, self.db, .{
//                         .session_id = params.session_id,
//                         .model = self.config.model,
//                         .cwd = params.cwd,
//                         .content = msg,
//                         .reasoning_content = null,
//                         .role = agent.Role.user.to_str(),
//                         .finish_reason = "null",
//                         .tool_calls = null,
//                         .tool_call_id = null,
//                         .agent_name = initial_agent,
//                         .loop_index = 0,
//                         .temperature = initial_agent_state.temperature,
//                         .is_thinking = initial_agent_state.is_thinking,
//                         .prompt_tokens = 0,
//                         .completion_tokens = 0,
//                         .total_tokens = 0,
//                         .parent_id = params.parent_session_id,
//                         .parent_session_id = params.parent_session_id,
//                         .is_input = true,
//                         .is_output = false,
//                     });
//
//                     onEventSendLLMHistory(allocator, .{
//                         .session_id = params.session_id,
//                         .model = self.config.model,
//                         .cwd = params.cwd,
//                         .content = msg,
//                         .reasoning_content = null,
//                         .role = agent.Role.user.to_str(),
//                         .finish_reason = "null",
//                         .tool_calls = null,
//                         .tool_call_id = null,
//                         .agent_name = initial_agent,
//                         .loop_index = 0,
//                         .temperature = initial_agent_state.temperature,
//                         .is_thinking = initial_agent_state.is_thinking,
//                         .parent_id = params.parent_session_id,
//                         .parent_session_id = params.parent_session_id,
//                         .is_input = true,
//                         .is_output = false,
//                     }) catch {};
//
//                     _ = try llm_history.deleteQueuedMessage(allocator, self.db, params.session_id, msg);
//                 }
//             }
//
//             // Update worker activity in DB to show we're actively processing
//             llm_history.updateWorkerActivity(allocator, self.db, params.session_id) catch {};
//
//             loopCounter += 1;
//             if (retryCount > 10) return error.TooManyRetries;
//
//             // Fetch current agent fresh from DB each iteration
//             const currentAgentState = try get_current_agent_by_session_id(
//                 allocator,
//                 self.db,
//                 params.session_id,
//             );
//             const current_agent = currentAgentState.agent;
//             var agent_temperature = currentAgentState.temperature;
//             var isThinking = currentAgentState.is_thinking;
//
//             var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;
//
//             const db_messages = try getMessages(allocator, self.db, params.session_id);
//             defer {
//                 for (db_messages) |*msg| msg.deinit(allocator);
//                 allocator.free(db_messages);
//             }
//             const total_tokens = blk: {
//                 var max_token: u32 = 0;
//                 for (db_messages) |msg| {
//                     if (msg.total_tokens > max_token) {
//                         max_token = msg.total_tokens;
//                     }
//                 }
//                 break :blk max_token;
//             };
//             const initialMessages = try buildMessages(allocator, self.io, self.db, params.cwd, params.session_id, db_messages, merged_tools);
//
//             try messagesLists.appendSlice(allocator, initialMessages);
//
//             self.logger.debugFmt("[COMPACTION] Total tokens from DB: {} ({} messages)", .{ total_tokens, messagesLists.items.len });
//             if (llm_models.is_do_compact(total_tokens, llm_models.get_model_token_count(self.config.model))) {
//                 self.logger.debugFmt("[COMPACTION] Threshold exceeded, triggering compaction", .{});
//                 if (self.callCompactAgent(messagesLists.items, allocator, self.config.api_key, self.config.model, self.config.base_url, params.cwd)) |compacted_xml| {
//                     try self.compactMessageInMemory(allocator, &messagesLists, compacted_xml, params.session_id, self.config.model, params.cwd);
//                 }
//             }
//
//             const res_dynamic_agent = self.callDynamicAgent(allocator, &messagesLists, agent_temperature, current_max_tokens, isThinking, self.config.api_key, self.config.model, self.config.base_url, params.session_id, merged_tools) catch |err| {
//                 if (err == error.Cancelled) {
//                     self.logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{params.session_id});
//                     break;
//                 }
//                 retryCount += 1;
//                 self.logger.errFmt("Error calling dynamic agent: {s} now retrying", .{@errorName(err)});
//                 continue;
//             };
//
//             retryCount = 0;
//
//             const session_info = session_table.getSession(allocator, self.db, params.session_id) catch |err| {
//                 self.logger.errFmt("Error getting session: {s}", .{@errorName(err)});
//                 break;
//             };
//
//             // Generate session name from first user message if this is the first response
//             if (session_info) |session| {
//                 if (is_first_iteration and std.mem.eql(u8, session.name, "New Session")) {
//                     self.generateSessionName(db_messages, allocator, self.config.api_key, self.config.model, self.config.base_url, params.session_id);
//                 }
//             }
//
//             // Mark first iteration as complete after generating session name
//             if (is_first_iteration) {
//                 is_first_iteration = false;
//             }
//
//             if (res_dynamic_agent.finish_reason) |finish_reason| {
//                 if (finish_reason == .stop) {
//                     _ = try llm_history.saveMessage(allocator, self.io, self.db, .{
//                         .session_id = params.session_id,
//                         .model = self.config.model,
//                         .cwd = params.cwd,
//                         .content = res_dynamic_agent.content,
//                         .reasoning_content = res_dynamic_agent.reasoning_content,
//                         .role = agent.Role.assistant.to_str(),
//                         .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
//                         .tool_calls = null,
//                         .tool_call_id = null,
//                         .agent_name = current_agent,
//                         .loop_index = loopCounter,
//                         .temperature = agent_temperature,
//                         .is_thinking = isThinking,
//                         .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
//                         .completion_tokens = res_dynamic_agent.usage.completion_tokens,
//                         .total_tokens = res_dynamic_agent.usage.total_tokens,
//                         .parent_id = params.parent_session_id,
//                         .parent_session_id = params.parent_session_id,
//                     });
//
//                     // Send SSE event directly with the agent's response content
//                     // Don't use getLatestMessage as it might return wrong message if timestamps collide
//                     _ = try onEventSendLLMHistory(allocator, .{
//                         .session_id = params.session_id,
//                         .model = self.config.model,
//                         .cwd = params.cwd,
//                         .content = res_dynamic_agent.content,
//                         .reasoning_content = res_dynamic_agent.reasoning_content,
//                         .role = agent.Role.assistant.to_str(),
//                         .finish_reason = res_dynamic_agent.finish_reason.?.to_str(),
//                         .tool_calls = null,
//                         .tool_call_id = null,
//                         .tool_name = null,
//                         .agent_name = current_agent,
//                         .loop_index = loopCounter,
//                         .temperature = agent_temperature,
//                         .is_thinking = isThinking,
//                         .is_input = false,
//                         .is_output = true,
//                         .parent_session_id = params.parent_session_id,
//                         .parent_id = params.parent_session_id,
//                         .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
//                     });
//
//                     const isHaveQueueMessage = llm_history.hasQueuedMessages(self.db, params.session_id);
//                     if (isHaveQueueMessage) {
//                         continue;
//                     }
//
//                     break;
//                 } else if (finish_reason == .length) {
//                     current_max_tokens += 4096;
//                     self.logger.debugFmt("Increased max tokens to {d}", .{current_max_tokens});
//                     continue;
//                 } else if (finish_reason == .tool_calls) {
//                     std.debug.print("DEBUG_WORKFLOW: finish_reason == .tool_calls, calling handle_tool\n", .{});
//                     try handle_tool(allocator, self.io, self.db, self.logger, params.session_id, params.parent_session_id, self.config.model, params.cwd, loopCounter, res_dynamic_agent, &agent_temperature, &isThinking, self.config.api_key, self.config.base_url, self.config, self.environment, self.active_loops);
//                 } else if (finish_reason == .assistant) {
//                     if (res_dynamic_agent.tool_calls != null and res_dynamic_agent.tool_calls.?.len > 0) {
//                         try handle_tool(allocator, self.io, self.db, self.logger, params.session_id, params.parent_session_id, self.config.model, params.cwd, loopCounter, res_dynamic_agent, &agent_temperature, &isThinking, self.config.api_key, self.config.base_url, self.config, self.environment, self.active_loops);
//                     } else {
//                         // Treat as normal completion
//                         _ = try llm_history.saveMessage(allocator, self.io, self.db, .{
//                             .session_id = params.session_id,
//                             .model = self.config.model,
//                             .cwd = params.cwd,
//                             .content = res_dynamic_agent.content,
//                             .reasoning_content = res_dynamic_agent.reasoning_content,
//                             .role = agent.Role.assistant.to_str(),
//                             .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
//                             .tool_calls = null,
//                             .tool_call_id = null,
//                             .agent_name = current_agent,
//                             .loop_index = loopCounter,
//                             .temperature = agent_temperature,
//                             .is_thinking = isThinking,
//                             .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
//                             .completion_tokens = res_dynamic_agent.usage.completion_tokens,
//                             .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
//                             .parent_id = params.parent_session_id,
//                             .parent_session_id = params.parent_session_id,
//                         });
//
//                         // Send SSE event directly with the agent's response content
//                         // Don't use getLatestMessage as it might return wrong message if timestamps collide
//                         _ = try onEventSendLLMHistory(allocator, .{
//                             .session_id = params.session_id,
//                             .model = self.config.model,
//                             .cwd = params.cwd,
//                             .content = res_dynamic_agent.content,
//                             .reasoning_content = res_dynamic_agent.reasoning_content,
//                             .role = "assistant",
//                             .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
//                             .tool_calls = null,
//                             .tool_call_id = null,
//                             .tool_name = null,
//                             .agent_name = current_agent,
//                             .loop_index = loopCounter,
//                             .temperature = agent_temperature,
//                             .is_thinking = isThinking,
//                             .is_input = false,
//                             .is_output = true,
//                             .parent_session_id = params.parent_session_id,
//                             .parent_id = params.parent_session_id,
//                             .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
//                         });
//
//                         const isHaveQueueMessage = llm_history.hasQueuedMessages(self.db, params.session_id);
//                         if (isHaveQueueMessage) {
//                             continue;
//                         }
//
//                         break;
//                     }
//                 } else {
//                     retryCount += 1;
//                     self.logger.errFmt("Error calling agent: maybe streaming failed", .{});
//                     onEventSendLLMHistory(allocator, .{
//                         .session_id = params.session_id,
//                         .model = self.config.model,
//                         .cwd = params.cwd,
//                         .content = null,
//                         .reasoning_content = null,
//                         .role = null,
//                         .finish_reason = "stop",
//                         .tool_calls = null,
//                         .tool_call_id = null,
//                         .tool_name = null,
//                         .agent_name = current_agent,
//                         .loop_index = loopCounter,
//                         .temperature = agent_temperature,
//                         .is_thinking = isThinking,
//                         .is_input = false,
//                         .is_output = false,
//                         .parent_session_id = params.parent_session_id,
//                         .parent_id = params.parent_session_id,
//                     }) catch {};
//                     break;
//                 }
//
//                 retryCount = 0;
//             }
//
//             // Log if finish_reason is null
//             if (res_dynamic_agent.finish_reason == null) {
//                 self.logger.warnFmt("WORKFLOW: finish_reason is NULL!", .{});
//             }
//         }
//
//         self.logger.debugFmt("WORKFLOW: exiting while loop for session_id {s}", .{params.session_id});
//     }
//     fn callDynamicAgent(
//         self: *TUIWorkflow,
//         allocator: std.mem.Allocator,
//         messages_list: *std.ArrayList(agent.AgentMessage),
//         agent_temperature: f32,
//         current_max_tokens: usize,
//         isThinking: bool,
//         api_key: []const u8,
//         model: []const u8,
//         base_url: []const u8,
//         session_id: []const u8,
//         tools: []const tool_models.AgentTool,
//     ) !agent.CallResponse {
//         var dynamic_agent = try agent.Agent.init(allocator, self.io);
//         dynamic_agent.apiKey = api_key;
//         dynamic_agent.model = model;
//         dynamic_agent.baseUrl = base_url;
//         const dynamic_agent_call_params = agent.AgentCall{ .tools = tools, .messages = messages_list.items, .temperature = agent_temperature, .max_tokens = current_max_tokens };
//         dynamic_agent.thinkingEnabled = isThinking;
//         dynamic_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes
//
//         var stream_ctx = StreamingContext{
//             .allocator = allocator,
//             .session_id = session_id,
//             .chunk_index = 0,
//         };
//         const res_dynamic_agent = try dynamic_agent.callStreaming(dynamic_agent_call_params, &stream_ctx, stream_callback);
//
//         return res_dynamic_agent;
//     }
//
//     /// No-op callback for streaming - used when we don't need to stream chunks to client.
//     fn noopStreamCallback(_: ?*anyopaque, _: agent.StreamChunk) void {}
//
//     /// Generate session name from the first user message using LLM
//     fn generateSessionName(
//         self: *TUIWorkflow,
//         db_messages: []models.TUIHistory,
//         allocator: std.mem.Allocator,
//         api_key: []const u8,
//         model: []const u8,
//         base_url: []const u8,
//         session_id: []const u8,
//     ) void {
//         // Find the first user message from db_messages (TUIHistory)
//         var first_user_message: ?[]const u8 = null;
//         for (db_messages) |msg| {
//             // role is stored as string "user" in TUIHistory
//             if (std.mem.eql(u8, msg.role, "user") and msg.response_content.len > 0) {
//                 first_user_message = msg.response_content;
//                 break;
//             }
//         }
//
//         if (first_user_message == null) {
//             self.logger.debugFmt("No user message found in db_messages", .{});
//             return;
//         }
//
//         // Build messages for the name generation prompt
//         const name_messages = allocator.alloc(agent.AgentMessage, 2) catch return;
//         name_messages[0] = .{ .role = .system, .content = prompt.GenerateSessionNameAgent };
//         name_messages[1] = .{ .role = .user, .content = first_user_message.? };
//
//         var name_agent = agent.Agent.init(allocator, self.io) catch return;
//         defer name_agent.deinit();
//         name_agent.apiKey = api_key;
//         name_agent.model = model;
//         name_agent.baseUrl = base_url;
//
//         const params = agent.AgentCall{
//             .tools = &.{},
//             .messages = name_messages,
//         };
//
//         const response = name_agent.callStreaming(params, null, noopStreamCallback) catch {
//             self.logger.errFmt("[SESSION NAME] Failed to call LLM for session name", .{});
//             return;
//         };
//         defer response.deinit();
//
//         if (response.content) |content| {
//             // Strip thinking tags if present, fallback to original content on error
//             var stripped_content: []const u8 = content;
//             var needs_free = false;
//             if (helpers.xml.stripThinkingTags(content, allocator)) |stripped| {
//                 stripped_content = stripped;
//                 needs_free = true;
//             } else |err| {
//                 self.logger.warnFmt("[SESSION NAME] Failed to strip thinking tags: {s}, using original content", .{@errorName(err)});
//             }
//
//             // limit to 50 chars
//             if (stripped_content.len > 50) {
//                 stripped_content = stripped_content[0..50];
//             }
//
//             // Update session name in database
//             session_table.updateSessionName(allocator, self.db, session_id, stripped_content) catch {
//                 self.logger.errFmt("[SESSION NAME] Failed to update session name: {s}", .{stripped_content});
//                 if (needs_free) allocator.free(stripped_content);
//                 return;
//             };
//             self.logger.debugFmt("[SESSION NAME] Generated session name: {s}", .{stripped_content});
//             if (needs_free) allocator.free(stripped_content);
//         }
//     }
//
//     /// Compact messages in memory based on CompactionAgent output
//     /// Also persists to database: marks old messages as not for LLM, saves new compacted message
//     pub fn compactMessageInMemory(
//         self: *TUIWorkflow,
//         allocator: std.mem.Allocator,
//         messages: *std.ArrayList(agent.AgentMessage),
//         compacted_xml: []const u8,
//         session_id: []const u8,
//         model: []const u8,
//         cwd: []const u8,
//     ) !void {
//         const total = messages.items.len;
//         if (total <= 4) return;
//
//         // Mark all existing messages in this session as not for LLM (soft-delete)
//         try llm_history.mark_message_not_for_llm_run(allocator, self.db, session_id);
//
//         // Build the compacted summary content
//         var summary: std.ArrayList(u8) = .empty;
//         defer summary.deinit(allocator);
//         try summary.print(allocator, "[CONTEXT SUMMARY]\n\n", .{});
//         try summary.print(allocator, "{s}", .{compacted_xml});
//         const summary_content = try summary.toOwnedSlice(allocator);
//
//         // Save the compacted summary to the database with is_feed_to_llm = 1
//         const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(self.io, .real).nanoseconds});
//         defer allocator.free(id);
//         const created_at = try std.fmt.allocPrint(allocator, "{}", .{@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, 1_000_000)});
//         defer allocator.free(created_at);
//
//         const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, is_feed_to_llm, agent, loop_index, created_at, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)";
//         try self.db.exec(allocator, sql, &.{ id, session_id, model, summary_content, "stop", "user", "", "", "Agent", "0", created_at, "1", "0", "" });
//
//         // Update the session's cwd in the sessions table
//         const copy_cwd = try std.heap.c_allocator.dupe(u8, cwd);
//         defer std.heap.c_allocator.free(copy_cwd);
//         try self.db.exec(allocator, "UPDATE sessions SET cwd = ? WHERE id = ?", &.{ copy_cwd, session_id });
//
//         // Build new in-memory message list: system message + compacted summary
//         var new_messages: std.ArrayList(agent.AgentMessage) = .empty;
//
//         // Keep system message - duplicate content to be safe
//         const system_content = if (messages.items[0].content) |c|
//             try allocator.dupe(u8, c)
//         else
//             null;
//         try new_messages.append(allocator, .{
//             .role = .system,
//             .content = system_content,
//         });
//
//         // Add compacted summary as user message
//         try new_messages.append(allocator, .{
//             .role = .user,
//             .content = summary_content,
//         });
//
//         // Free ALL old messages (including ones we "kept" - we have copies now)
//         for (messages.items) |*msg| {
//             msg.deinit(allocator);
//         }
//         messages.deinit(allocator);
//         messages.* = new_messages;
//
//         self.logger.debugFmt("[COMPACTION] Compacted: {} -> {} messages (persisted to DB)", .{ total, messages.items.len });
//     }
//
//     /// Add a file listing to the writer for project context
//     fn addFileListing(self: *TUIWorkflow, w: *anyopaque, cwd: []const u8, arena: std.mem.Allocator) void {
//         // Fallback: skip file listing if directory can't be opened
//         // The compaction can still proceed without this context
//         inline for (.{ ".zig", ".c", ".h", ".cpp", ".js", ".ts", ".json", ".md", ".txt", ".toml", ".yaml", ".yml" }) |ext| {
//             self.findFilesWithExtension(w, cwd, ext, arena, 0, 3);
//         }
//     }
//
//     /// Recursively find files with specific extension
//     fn findFilesWithExtension(self: *TUIWorkflow, w: *anyopaque, dir_path: []const u8, ext: []const u8, arena: std.mem.Allocator, depth: usize, max_depth: usize) void {
//         if (depth > max_depth) return;
//
//         // Use std.Io.Dir.openDirAbsolute to open directory directly (doesn't depend on process cwd)
//         // NOTE: .iterate = true is required for iterate() to work properly
//         var dir = std.Io.Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true }) catch return;
//         defer std.Io.Dir.close(dir, self.io);
//
//         var iterator = dir.iterate();
//         while (iterator.next(self.io) catch null) |entry| {
//             if (std.mem.eql(u8, entry.name, ".git")) continue;
//             if (std.mem.eql(u8, entry.name, "node_modules")) continue;
//             if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
//             if (std.mem.eql(u8, entry.name, "zig-out")) continue;
//             if (std.mem.eql(u8, entry.name, ".cache")) continue;
//             if (entry.name[0] == '.') continue;
//
//             if (entry.kind == .directory) {
//                 const subdir = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch return;
//                 defer arena.free(subdir);
//                 self.findFilesWithExtension(w, subdir, ext, arena, depth + 1, max_depth);
//             } else if (entry.kind == .file) {
//                 if (std.mem.endsWith(u8, entry.name, ext)) {
//                     const rel_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch return;
//                     defer arena.free(rel_path);
//                     const writer: *std.Io.Writer = @ptrCast(@alignCast(w));
//                     writer.print("  {s}\n", .{rel_path}) catch {};
//                 }
//             }
//         }
//     }
// };
