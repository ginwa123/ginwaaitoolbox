const nalar_mod = @import("nalarcore");
const llm_history = @import("llm_history.zig");
const build_msg_prompt = @import("build_messages_for_agent_prompt.zig");
const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;
const models = @import("models.zig");
const on_event_sent = @import("on_event_sent.zig");
const tool_registry = @import("tool_registry.zig");
const handle_tool = @import("handle_tool.zig").handle_tool;
const notifications = @import("notifications.zig");

const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const config_mod = nalarcore.config;
const logger_mod = nalarcore.logger;
const agent = nalarcore.agent;
const prompt = nalarcore.agent.prompt;
const helpers = nalarcore.helpers;

const std = @import("std");
const json = std.json;

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
        const allocator = di.allocator;
        const db = di.db;
        const io = di.io;
        const session_id = data.session_id;
        const config = nalar_mod.getLlmConfig(di);
        const cwd = data.cwd;

        runAgenticMultiStepnew(di, data) catch |err| {
            logger.errFmt("runAgenticMultiStepnew failed: {s}", .{@errorName(err)});
            llm_history.deleteWorkerBySessionId(allocator, db, session_id) catch |error_sqlite| {
                logger.errFmt("Failed to delete worker: {s}", .{@errorName(error_sqlite)});
            };

            llm_history.deleteQueuedMessagesBySessionId(allocator, db, session_id) catch |error_sqlite| {
                logger.errFmt("Failed to delete all queued messages: {s}", .{@errorName(error_sqlite)});
            };

            const initial_agent_state = llm_history.get_current_agent_by_session_id(
                allocator,
                db,
                session_id,
            ) catch |err_agent_state| {
                logger.errFmt("Failed to get current agent state: {s}", .{@errorName(err_agent_state)});
                return;
            };
            const initial_agent = initial_agent_state.agent;

            const error_message = std.fmt.allocPrint(allocator, "{s} {s} {s}\n", .{ "Theres a error ", @errorName(err), "ignore this instruction" }) catch |err_fmt| {
                logger.errFmt("Failed to format error message: {s}", .{@errorName(err_fmt)});
                return;
            };
            _ = llm_history.saveMessage(allocator, io, db, .{
                .session_id = session_id,
                .model = config.model,
                .cwd = cwd,
                .content = error_message,
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
                .parent_id = session_id,
                .parent_session_id = session_id,
                .is_input = true,
                .is_output = false,
            }) catch {};

            const session_skills_err = llm_history.getSessionSkills(allocator, db, session_id) catch null;
            defer if (session_skills_err) |s| for (s) |*skill| {
                allocator.free(skill.skill_name);
                allocator.free(skill.content);
            };

            on_event_sent.onEventSendLLMHistory(allocator, .{
                .session_id = session_id,
                .model = config.model,
                .cwd = cwd,
                .content = error_message,
                .reasoning_content = null,
                .role = agent.Role.user.to_str(),
                .finish_reason = "null",
                .tool_calls_json = null,
                .tool_call_id = null,
                .agent_name = initial_agent,
                .loop_index = 0,
                .temperature = initial_agent_state.temperature,
                .is_thinking = initial_agent_state.is_thinking,
                .parent_id = session_id,
                .parent_session_id = session_id,
                .is_input = true,
                .is_output = false,
                .image_url = null,
                .session_skills = session_skills_err,
            }) catch {};
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
    const config = nalar_mod.getLlmConfig(di);
    const environment = di.environment;

    // ─── Resolve the effective LLM profile (selected_profile_model) ──────
    // Fallback chain:
    //   1. params.selected_profile_model (from POST body) if non-empty AND profile exists
    //   2. top-level LlmConfig (the "default" mode)
    // All four slices borrow from the LlmConfig; they live for the whole workflow run.
    var effective_api_key: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.api_key.len > 0) break :blk profile.api_key;
            } else {
                logger.warnFmt("WORKFLOW: selected_profile_model '{s}' not found in LlmConfig.profiles_models, using top-level config", .{params.selected_profile_model});
            }
        }
        break :blk config.api_key;
    };
    var effective_model: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.model.len > 0) break :blk profile.model;
            }
        }
        break :blk config.model;
    };
    var effective_base_url: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.base_url.len > 0) break :blk profile.base_url;
            }
        }
        break :blk config.base_url;
    };
    var effective_url_style: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.url_style.len > 0) break :blk profile.url_style;
            }
        }
        break :blk config.url_style;
    };

    const copy_parent_session_id = try parent_allocator.dupe(u8, params.parent_session_id);
    const copy_session_id = try parent_allocator.dupe(u8, params.session_id);
    const copy_message = try parent_allocator.dupe(u8, params.message);
    const copy_cwd = try parent_allocator.dupe(u8, params.cwd);
    const copy_allowed_tools = try parent_allocator.dupe(u8, params.allowed_tools);
    const copy_is_sub_agent = params.is_sub_agent;
    const copy_image_urls = try parent_allocator.dupe(u8, params.image_urls);
    const copy_inherited_context = try parent_allocator.dupe(u8, params.inherited_context);
    const copy_selected_profile_model = try parent_allocator.dupe(u8, params.selected_profile_model);

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
        llm_history.queueMessage(parent_allocator, db, copy_session_id, copy_message, copy_image_urls) catch {
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

    llm_history.updateSessionUpdatedAt(parent_allocator, db, copy_session_id) catch {
        logger.warnFmt("Failed to update session updated at for {s}", .{copy_session_id});
    };

    llm_history.updateWorkspaceUpdatedAt(parent_allocator, db, copy_session_id) catch {
        logger.warnFmt("Failed to update workspace item tasks updated at for {s}", .{copy_session_id});
    };

    // Queue the initial message
    llm_history.queueMessage(parent_allocator, db, copy_session_id, copy_message, copy_image_urls) catch {
        logger.warnFmt("Failed to queue initial message for session {s}", .{copy_session_id});
    };

    var retry_count: usize = 0;
    var current_max_tokens: usize = 20000;
    var loop_counter: u32 = 0;

    // Fetch MCP tools once before the loop - avoids repeated fetching and potential recursive spawning
    const mcp_tools_fetched = (build_msg_prompt.buildMCPToolsRun(parent_allocator, io, config.mcpServers() orelse .null) catch |err| blk: {
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
            for (messages.items) |queued| {
                // Use image_url from database if present, otherwise try to extract from message
                var image_urls: ?[][]const u8 = null;
                if (queued.image_url.len > 0) {
                    // Split by pipe separator
                    var parts = std.mem.splitScalar(u8, queued.image_url, '|');
                    var urls = std.ArrayList([]const u8).empty;
                    defer {
                        for (urls.items) |u| allocator.free(u);
                        urls.deinit(allocator);
                    }
                    while (parts.next()) |part| {
                        if (part.len > 0) {
                            try urls.append(allocator, try allocator.dupe(u8, part));
                        }
                    }
                    if (urls.items.len > 0) {
                        image_urls = try urls.toOwnedSlice(allocator);
                    }
                } else {
                    // Fallback: try to extract from message content
                    image_urls = helpers.image.extractBase64ImageUrls(queued.message, allocator) catch |err| blk: {
                        logger.warnFmt("Failed to extract image URLs: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                }
                defer {
                    if (image_urls) |urls| {
                        for (urls) |url| allocator.free(url);
                        allocator.free(urls);
                    }
                }

                _ = try llm_history.saveMessage(allocator, io, db, .{
                    .session_id = copy_session_id,
                    .model = effective_model,
                    .cwd = copy_cwd,
                    .content = queued.message,
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
                    .image_urls = image_urls,
                });

                const session_skills_queued = llm_history.getSessionSkills(parent_allocator, db, copy_session_id) catch null;
                defer if (session_skills_queued) |s| for (s) |*skill| {
                    parent_allocator.free(skill.skill_name);
                    parent_allocator.free(skill.content);
                };

                on_event_sent.onEventSendLLMHistory(allocator, .{
                    .session_id = copy_session_id,
                    .model = effective_model,
                    .cwd = copy_cwd,
                    .content = queued.message,
                    .reasoning_content = null,
                    .role = agent.Role.user.to_str(),
                    .finish_reason = "null",
                    .tool_calls_json = null,
                    .tool_call_id = null,
                    .agent_name = initial_agent,
                    .loop_index = 0,
                    .temperature = initial_agent_state.temperature,
                    .is_thinking = initial_agent_state.is_thinking,
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .is_input = true,
                    .is_output = false,
                    .image_url = if (queued.image_url.len > 0) queued.image_url else null,
                    .session_skills = session_skills_queued,
                }) catch {};

                _ = try llm_history.deleteQueuedMessage(allocator, db, copy_session_id, queued.message);
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

        // Apply sub-agent overrides (resolved by Config.resolveSubAgent
        // in tool_registry.execSpawnSubAgent). For the main-agent
        // flow, `sub_agent_overrides` is null and this block is a
        // no-op. For the sub-agent flow, non-empty string fields
        // override the profile-resolved values, and non-null
        // bool/f32 fields override the session's current values.
        var sub_agent_session_name: []const u8 = "";
        if (params.sub_agent_overrides) |ov| {
            if (ov.model.len > 0) effective_model = ov.model;
            if (ov.base_url.len > 0) effective_base_url = ov.base_url;
            if (ov.api_key.len > 0) effective_api_key = ov.api_key;
            if (ov.url_style.len > 0) effective_url_style = ov.url_style;
            if (ov.is_thinking) |t| isThinking = t;
            if (ov.temperature) |t| agent_temperature = t;
            sub_agent_session_name = ov.resolved_name;
        }
        // For sub-agent flow: replace `current_agent` (the session's
        // last `agent_name` from llm_history) with the resolved
        // sub-agent name. The session is brand-new for sub-agents
        // (no prior agent_name), so `current_agent` defaults to
        // "Agent" — we want the sub-agent's resolved_name instead.
        const effective_agent_name: []const u8 = if (sub_agent_session_name.len > 0)
            sub_agent_session_name
        else
            current_agent;

        // Sub-agent's specialized system_prompt (from
        // SubAgentConfig.system_prompt) is injected as the
        // `## Your Active Agent Configuration` section of
        // build_agent_prompt. For the main-agent flow and the
        // random-fallback case, this is empty and `buildMessages`
        // falls back to `BuildDynamicAgentContent`.
        const sub_agent_system_prompt: []const u8 = if (params.sub_agent_overrides) |ov|
            ov.system_prompt
        else
            "";

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
            generateSessionNameNew(db_messages, allocator, effective_api_key, effective_model, effective_base_url, copy_session_id, logger, io, db);
        }

        const initialMessages = try build_msg_prompt.buildMessages(allocator, io, db, copy_cwd, copy_session_id, copy_parent_session_id, db_messages, merged_tools, copy_inherited_context, sub_agent_system_prompt);

        try messagesLists.appendSlice(allocator, initialMessages);

        logger.debugFmt("[COMPACTION] Total tokens from DB: {} ({} messages)", .{ total_tokens, messagesLists.items.len });
        try maybeCompactMessagesNew(allocator, total_tokens, effective_model, false, &messagesLists, effective_api_key, effective_base_url, copy_cwd, copy_session_id, db, io, logger);

        const res_dynamic_agent = callDynamicAgentNew(allocator, io, &messagesLists, agent_temperature, current_max_tokens, isThinking, effective_api_key, effective_model, effective_base_url, effective_url_style, copy_session_id, merged_tools) catch |err| {
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
                    .model = effective_model,
                    .cwd = copy_cwd,
                    .content = res_dynamic_agent.content,
                    .reasoning_content = res_dynamic_agent.reasoning_content,
                    .role = agent.Role.assistant.to_str(),
                    .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                    .tool_calls = null,
                    .tool_call_id = null,
                    .agent_name = effective_agent_name,
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
                const session_skills_dynamic = llm_history.getSessionSkills(allocator, db, copy_session_id) catch null;
                defer if (session_skills_dynamic) |s| for (s) |*skill| {
                    allocator.free(skill.skill_name);
                    allocator.free(skill.content);
                };

                _ = try on_event_sent.onEventSendLLMHistory(allocator, .{
                    .session_id = copy_session_id,
                    .model = effective_model,
                    .cwd = copy_cwd,
                    .content = res_dynamic_agent.content,
                    .reasoning_content = res_dynamic_agent.reasoning_content,
                    .role = agent.Role.assistant.to_str(),
                    .finish_reason = res_dynamic_agent.finish_reason.?.to_str(),
                    .tool_calls_json = null,
                    .tool_call_id = null,
                    .tool_name = null,
                    .agent_name = effective_agent_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .is_input = false,
                    .is_output = true,
                    .parent_session_id = copy_parent_session_id,
                    .parent_id = copy_parent_session_id,
                    .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
                    .image_url = null,
                    .session_skills = session_skills_dynamic,
                });

                const isHaveQueueMessage = llm_history.hasQueuedMessages(db, copy_session_id);
                if (isHaveQueueMessage) {
                    continue;
                }

                // Fire an OS notification when the user has opted in. Only on
                // `finish_reason == .stop` — tool_calls and length are
                // mid-conversation events the user is already watching. Fire-
                // and-forget: a missing notify-send (or denied daemon) is
                // logged and ignored so the LLM workflow never blocks.
                if (config.notify_on_complete) {
                    const preview = if (res_dynamic_agent.content) |c| c else "(empty response)";
                    notifications.notify(io, allocator, "Agent Nalar", preview) catch |err| {
                        logger.warnFmt("notifications: {s}", .{@errorName(err)});
                    };
                }

                break;
            } else if (finish_reason == .length) {
                current_max_tokens += 4096;
                logger.debugFmt("Increased max tokens to {d}", .{current_max_tokens});
                continue;
            } else if (finish_reason == .tool_calls) {
                std.debug.print("DEBUG_WORKFLOW: finish_reason == .tool_calls, calling handle_tool\n", .{});
                try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, effective_model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, active_loops, copy_selected_profile_model);
            } else if (finish_reason == .assistant) {
                if (res_dynamic_agent.tool_calls != null and res_dynamic_agent.tool_calls.?.len > 0) {
                    try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, effective_model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, active_loops, copy_selected_profile_model);
                } else {
                    // Treat as normal completion
                    _ = try llm_history.saveMessage(allocator, io, db, .{
                        .session_id = copy_session_id,
                        .model = effective_model,
                        .cwd = copy_cwd,
                        .content = res_dynamic_agent.content,
                        .reasoning_content = res_dynamic_agent.reasoning_content,
                        .role = agent.Role.assistant.to_str(),
                        .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                        .tool_calls = null,
                        .tool_call_id = null,
                        .agent_name = effective_agent_name,
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
                    const session_skills_assistant = llm_history.getSessionSkills(allocator, db, copy_session_id) catch null;
                    defer if (session_skills_assistant) |s| for (s) |*skill| {
                        allocator.free(skill.skill_name);
                        allocator.free(skill.content);
                    };

                    _ = try on_event_sent.onEventSendLLMHistory(allocator, .{
                        .session_id = copy_session_id,
                        .model = effective_model,
                        .cwd = copy_cwd,
                        .content = res_dynamic_agent.content,
                        .reasoning_content = res_dynamic_agent.reasoning_content,
                        .role = agent.Role.assistant.to_str(),
                        .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
                        .tool_calls_json = null,
                        .tool_call_id = null,
                        .tool_name = null,
                        .agent_name = effective_agent_name,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature,
                        .is_thinking = isThinking,
                        .is_input = false,
                        .is_output = true,
                        .parent_session_id = copy_parent_session_id,
                        .parent_id = copy_parent_session_id,
                        .total_tokens = @as(u32, @intCast(res_dynamic_agent.usage.total_tokens)),
                        .image_url = null,
                        .session_skills = session_skills_assistant,
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

                const session_skills_retry = llm_history.getSessionSkills(allocator, db, copy_session_id) catch null;
                defer if (session_skills_retry) |s| for (s) |*skill| {
                    allocator.free(skill.skill_name);
                    allocator.free(skill.content);
                };

                on_event_sent.onEventSendLLMHistory(allocator, .{
                    .session_id = copy_session_id,
                    .model = effective_model,
                    .cwd = copy_cwd,
                    .content = null,
                    .reasoning_content = null,
                    .role = null,
                    .finish_reason = "stop",
                    .tool_calls_json = null,
                    .tool_call_id = null,
                    .tool_name = null,
                    .agent_name = effective_agent_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .is_input = false,
                    .is_output = false,
                    .parent_session_id = copy_parent_session_id,
                    .parent_id = copy_parent_session_id,
                    .image_url = null,
                    .session_skills = session_skills_retry,
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
        llm_history.updateSessionName(allocator, db, session_id, stripped_content) catch {
            logger.errFmt("[SESSION NAME] Failed to update session name: {s}", .{stripped_content});
            if (needs_free) allocator.free(stripped_content);
            return;
        };

        llm_history.updateTaskName(allocator, db, session_id, stripped_content) catch {
            logger.errFmt("[SESSION NAME] Failed to update task name: {s}", .{stripped_content});
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
    url_style: []const u8,
    session_id: []const u8,
    tools: []const agent.AgentTool,
) !agent.CallResponse {
    var dynamic_agent = try agent.Agent.init(allocator, io);
    dynamic_agent.apiKey = api_key;
    dynamic_agent.model = model;
    dynamic_agent.baseUrl = base_url;
    dynamic_agent.UrlStyle = url_style;
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

/// Conditionally compact `messages` in place. When `force` is false, compaction
/// happens only when `total_tokens` is at/above 80% of the model's context window;
/// pass `force=true` to bypass the threshold (e.g. for an explicit "compact now"
/// HTTP endpoint). The compact-agent call is best-effort — if it returns null, the
/// message list is left untouched and the caller continues with the original
/// messages. Errors from `compactMessageInMemoryNew` propagate to the caller.
pub fn maybeCompactMessagesNew(
    allocator: std.mem.Allocator,
    total_tokens: u32,
    model: []const u8,
    force: bool,
    messages: *std.ArrayList(agent.AgentMessage),
    api_key: []const u8,
    base_url: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *logger_mod.Logger,
) !void {
    if (!force and !agent.LLMModels.isDoCompact(total_tokens, agent.LLMModels.getModelTokenCount(model))) {
        return;
    }

    // Snapshot the current messages so that callCompactAgentNew's in-place mutation
    // of index 0 (rewriting it to the compaction system prompt) does not leak back
    // into the caller's list if the compact call fails.
    const copy_messages = try allocator.dupe(agent.AgentMessage, messages.items);
    defer allocator.free(copy_messages);
    var copy_list = std.ArrayList(agent.AgentMessage).fromOwnedSlice(copy_messages);
    defer copy_list.deinit(allocator);

    if (callCompactAgentNew(&copy_list, allocator, api_key, model, base_url, cwd, logger, io)) |compacted_xml| {
        try compactMessageInMemoryNew(allocator, messages, compacted_xml, session_id, model, cwd, db, io, logger);
    }
}

/// Call CompactionAgent to compress conversation history.
/// Returns compacted context or null on failure.
pub fn callCompactAgentNew(
    messages: *std.ArrayList(agent.AgentMessage),
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    cwd: []const u8,
    logger: *logger_mod.Logger,
    io: std.Io,
) ?[]const u8 {
    _ = cwd;

    const last_idx = messages.items.len - 1;

    // Collect content from all messages between first and last
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (messages.items[1..last_idx]) |msg| {
        if (msg.content) |c| parts.append(allocator, c) catch |err| {
            logger.errFmt("[COMPACTION] Failed to collect message content: {s}", .{@errorName(err)});
            return null;
        };
    }

    const history_str = std.mem.join(allocator, "\n", parts.items) catch |err| {
        logger.errFmt("[COMPACTION] Failed to join history: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(history_str);

    const compact_message = std.fmt.allocPrint(allocator,
        \\You are compacting an AI agent's conversation history to reduce context length.
        \\Preserve ALL of the following:
        \\- The original task or goal
        \\- Key decisions made and why
        \\- Tool calls and their results (file reads, command outputs, etc.)
        \\- Current progress and what remains
        \\- Any errors encountered and how they were resolved
        \\
        \\Format your response exactly as:
        \\**Goal:** <one sentence>
        \\**Progress:** <what has been done>
        \\**Key findings:** <important outputs, facts, file contents>
        \\**Next step:** <specific actionable next action>
        \\
        \\History to compact:
        \\{s}
        \\
    , .{history_str}) catch |err| {
        logger.errFmt("[COMPACTION] Failed to format compact message: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(compact_message);

    // Build a fresh message list — never touch the caller's messages
    var messages_convocompact: std.ArrayList(agent.AgentMessage) = .empty;
    defer messages_convocompact.deinit(allocator);

    messages_convocompact.append(allocator, .{
        .role = .system,
        .content = prompt.CompactionAgent,
    }) catch |err| {
        logger.errFmt("[COMPACTION] Failed to append system message: {s}", .{@errorName(err)});
        return null;
    };

    messages_convocompact.append(allocator, .{
        .role = .user,
        .content = compact_message,
    }) catch |err| {
        logger.errFmt("[COMPACTION] Failed to append user message: {s}", .{@errorName(err)});
        return null;
    };

    var compaction_agent = agent.Agent.init(allocator, io) catch |err| {
        logger.errFmt("[COMPACTION] Agent.init failed: {s}", .{@errorName(err)});
        return null;
    };
    defer compaction_agent.deinit();

    compaction_agent.apiKey = api_key;
    compaction_agent.model = model;
    compaction_agent.baseUrl = base_url;

    const response = compaction_agent.callStreaming(.{
        .tools = &.{},
        .messages = messages_convocompact.items,
        .temperature = 0.0,
    }, null, noopStreamCallbackNew) catch |err| {
        logger.errFmt("[COMPACTION] callStreaming failed: {s}", .{@errorName(err)});
        return null;
    };
    defer response.deinit();

    const content = response.content orelse {
        logger.errFmt("[COMPACTION] Response content is null", .{});
        return null;
    };

    if (content.len == 0) {
        logger.warnFmt("[COMPACTION] Empty response from CompactionAgent", .{});
        return null;
    }

    const duplicated = allocator.dupe(u8, content) catch |err| {
        logger.errFmt("[COMPACTION] Failed to duplicate content: {s}", .{@errorName(err)});
        return null;
    };

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
    try llm_history.markMessageNotForLlmRun(allocator, db, session_id);

    // Build the compacted summary content with XML wrapping
    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(allocator);
    try summary.print(allocator, "<compact_messages>\n\n", .{});
    try summary.print(allocator, "{s}", .{compacted_xml});
    try summary.print(allocator, "\n\n</compact_messages>", .{});
    const summary_content = try summary.toOwnedSlice(allocator);

    // Save the compacted summary to the database with is_feed_to_llm = 1
    try llm_history.saveMessage(allocator, io, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = summary_content,
        .reasoning_content = null,
        .role = "user",
        .finish_reason = "stop",
        .tool_calls = null,
        .tool_call_id = null,
        .tool_name = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

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

/// Resolved sub-agent config overlay, populated by
/// `tool_registry.execSpawnSubAgent` after calling
/// `Config.resolveSubAgent`. When `non-null`, the fields here are
/// applied on top of the existing `selected_profile_model`
/// resolution in `runAgenticMultiStepnew`.
///
/// String fields with `.len == 0` mean "inherit the
/// profile-resolved value" (the matched `SubAgentConfig` had an
/// empty string for that field, OR the random-fallback case).
/// `is_thinking` / `temperature` `null` means "auto — inherit
/// parent's value at run time".
///
/// The struct is *passed by value* (not pointer) because it's small
/// and `RunParamsNew` is by-value already. The string slices it
/// references borrow from the `LlmConfig` allocator — they must
/// outlive the workflow run, which they do because
/// `LlmConfig` is owned by the singleton.
pub const SubAgentOverrides = struct {
    /// Final name to record in `llm_history.agent_name` and the
    /// session_id suffix. Either the matched config name (e.g.
    /// "code-reviewer") or a generated random name
    /// ("agent-{16 hex chars}") for the fallback case.
    resolved_name: []const u8,
    /// True when the original `agent_name` was not found in any
    /// sub_agents list. The frontend shows a "random" badge in the
    /// SpawnSubAgent tool result when this is true.
    is_random_fallback: bool,
    /// LLM fields (overlay on profile-resolved values). Empty
    /// string = "inherit the profile-resolved value".
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    url_style: []const u8 = "",
    /// `null` = "auto — inherit parent's value at run time".
    /// When non-null, the override is applied on top of the
    /// session's current value (NOT the profile value — see
    /// `runAgenticMultiStepnew` for the order of application).
    is_thinking: ?bool = null,
    temperature: ?f32 = null,
    /// System prompt to inject as the sub-agent's
    /// `## Your Active Agent Configuration`. Empty = no injection
    /// (the sub-agent uses the default `build_agent_prompt`
    /// scaffold with no specialized configuration).
    system_prompt: []const u8 = "",
};

pub const RunParamsNew = struct {
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
    image_urls: []const u8 = "",
    selected_profile_model: []const u8 = "", // NEW
    inherited_context: []const u8 = "", // NEW: mode string for parent history inheritance
    /// NEW: pre-resolved sub-agent config overlay. When non-null,
    /// the fields here are applied on top of the
    /// `selected_profile_model` resolution (see `SubAgentOverrides`
    /// doc). The struct is small and owned by the call site; the
    /// string slices it references must outlive this workflow run.
    sub_agent_overrides: ?SubAgentOverrides = null,
};
