const nalarcore = @import("nalarcore");
const llm_history = @import("llm_history.zig");
const build_msg_prompt = @import("build_messages_for_agent_prompt.zig");
const models = @import("models.zig");
const on_event_sent = @import("on_event_sent.zig");
const tool_registry = @import("tool_registry.zig");
const handle_tool = @import("handle_tool.zig").handle_tool;
const notifications = @import("notifications.zig");

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
        const keyword = "CALLBACK_AI_WORKER_FLOW";
        const di = nalarcore.getSingleton() catch return;
        const logger = di.logger;
        const allocator = di.allocator;
        const db = di.db;
        const io = di.io;
        const session_id = data.session_id;
        const config = nalarcore.getLlmConfig(di);
        const cwd = data.cwd;

        runAgenticMultiStepnew(di, data) catch |err| {
            logger.errFmt("[{s}] Failed to run agentic workflow: {s}\n", .{ keyword, @errorName(err) });
            llm_history.deleteWorkerBySessionId(allocator, db, session_id) catch |error_sqlite| {
                logger.errFmt("[{s}] Failed to delete worker: {s}\n", .{ keyword, @errorName(error_sqlite) });
            };

            _ = llm_history.deleteQueuedMessagesBySessionId(allocator, db, session_id) catch |error_sqlite| {
                logger.errFmt("[{s}] Failed to delete all queued messages: {s}\n", .{ keyword, @errorName(error_sqlite) });
            };

            // For TooManyRetries, the inner bail already saved a rich diagnostic
            // to chat history (with the retry reason, count, and source). Skip the
            // generic user-message save here so the AI agent sees ONE clear message
            // instead of two — one rich (from the inner bail) and one redundant
            // "TooManyRetries" generic message that would just confuse it again.
            if (err == error.TooManyRetries) {
                logger.errFmt("[{s}] TooManyRetries\n", .{keyword});
                return;
            }

            const initial_agent_state = llm_history.get_current_agent_by_session_id(
                allocator,
                db,
                session_id,
            ) catch |err_agent_state| {
                logger.errFmt("[{s}] Failed to get current agent state: {s}\n", .{ keyword, @errorName(err_agent_state) });
                return;
            };
            const initial_agent = initial_agent_state.agent;

            const error_message = std.fmt.allocPrint(allocator, "Agent Nalar System error, the actual error is ->>>> {s}\n", .{@errorName(err)}) catch |err_fmt| {
                logger.errFmt("[{s}] Failed to format error message: {s}\n", .{ keyword, @errorName(err_fmt) });
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
                .is_feed_to_llm = false,
            }) catch |err_save| {
                logger.errFmt("[{s}] Failed to format error message: {s}\n", .{ keyword, @errorName(err_save) });
            };

            const session_skills_err = llm_history.getSessionSkills(allocator, db, session_id) catch null;
            defer if (session_skills_err) |s| for (s) |*skill| {
                allocator.free(skill.skill_name);
                allocator.free(skill.content);
            };

            _ = on_event_sent.onEventSendLLMHistory(allocator, .{
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
            }) catch |on_event_sent_err| {
                logger.errFmt("[{s}] failed to sent llm historry: {s}\n", .{ keyword, @errorName(on_event_sent_err) });
            };
        };
    }
};

pub fn runAgenticMultiStepnew(di: *nalarcore.ContextIPCTui, params: RunParamsNew) !void {
    var parent_arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
    defer parent_arena_allocator.deinit();
    const parent_allocator = parent_arena_allocator.allocator();

    const db = di.db;
    const logger = di.logger;
    const active_loops = di.active_loops;
    const io = di.io;
    const config = nalarcore.getLlmConfig(di);
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

    const initial_agent_state = try llm_history.get_current_agent_by_session_id(
        parent_allocator,
        db,
        copy_session_id,
    );
    const initial_agent = initial_agent_state.agent;

    // Check if session is already running (exists in worker table)
    if (llm_history.isSessionRunning(db, copy_session_id) and active_loops.contains(io, copy_session_id)) {
        // Session is already running, queue the message
        try llm_history.queueMessage(parent_allocator, db, copy_session_id, copy_message, copy_image_urls);
        is_have_queue_message = true;
        return;
    }
    defer {
        llm_history.markSessionIdle(parent_allocator, db, copy_session_id) catch |err| {
            logger.errFmt("Failed to mark session idle: {s}", .{@errorName(err)});
        };
    }

    defer active_loops.remove(io, copy_session_id);

    // Register in worker table (upsertWorker already does this)
    try llm_history.upsertWorker(parent_allocator, db, copy_session_id, copy_session_id, copy_cwd);

    try llm_history.updateSessionUpdatedAt(parent_allocator, db, copy_session_id);

    try llm_history.updateWorkspaceUpdatedAt(parent_allocator, db, copy_session_id);

    // Queue the initial message
    try llm_history.queueMessage(parent_allocator, db, copy_session_id, copy_message, copy_image_urls);

    var retry_count: usize = 0;
    // Track the most recent retry error so the AI agent can understand WHY
    // retries were happening when the budget is exhausted. Without this,
    // "TooManyRetries" is ambiguous — the AI doesn't know if the cause was
    // network, rate-limit, auth, etc. These are read by the bail block below
    // (when retry_count exceeds 10) and embedded into a user-facing diagnostic
    // message that the AI sees on its next turn.
    var last_retry_error: anyerror = error.Unknown;
    var last_retry_source: []const u8 = "unknown";
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
                        logger.errFmt("Failed to extract image URLs: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                }
                defer {
                    if (image_urls) |urls| {
                        for (urls) |url| allocator.free(url);
                        allocator.free(urls);
                    }
                }

                try llm_history.saveMessage(allocator, io, db, .{
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

                try on_event_sent.onEventSendLLMHistory(allocator, .{
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
                });

                _ = try llm_history.deleteQueuedMessage(allocator, db, copy_session_id, queued.message);
            }
        }

        // Update worker activity in DB to show we're actively processing
        try llm_history.updateWorkerActivity(allocator, db, copy_session_id);

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

        // Bail on retry budget exhaustion. Placed here (after effective_agent_name
        // is computed) so the diagnostic saved to chat history has the correct
        // agent context for the AI to read on its next turn. Without this rich
        // diagnostic, the AI only sees the generic "TooManyRetries" error name
        // in the outer catch and has no idea WHY retries were happening or what
        // the underlying cause was (network, rate-limit, auth, etc.).
        if (retry_count > 10) {
            const reason_error = @errorName(last_retry_error);
            const reason_source = last_retry_source;
            const diagnostic = std.fmt.allocPrint(parent_allocator,
                \\[Agent Nalar System error] workflow halted after {} consecutive retries.
                \\Reason for last retry: {s} (source: {s}).
            , .{ retry_count, reason_error, reason_source }) catch "workflow halted after too many retries";

            logger.errFmt("TooManyRetries exhausted: {} consecutive failures for session_id={s} — last_error={s} source={s}", .{ retry_count, copy_session_id, reason_error, reason_source });

            // Save the diagnostic as a user message so the AI agent sees it on
            // its next turn. Mirror the pattern the outer catch uses for generic
            // errors so the message shape is consistent.
            const session_skills_bail = llm_history.getSessionSkills(allocator, db, copy_session_id) catch null;
            defer if (session_skills_bail) |s| for (s) |*skill| {
                allocator.free(skill.skill_name);
                allocator.free(skill.content);
            };

            _ = llm_history.saveMessage(allocator, io, db, .{
                .session_id = copy_session_id,
                .model = effective_model,
                .cwd = copy_cwd,
                .content = diagnostic,
                .reasoning_content = null,
                .role = agent.Role.user.to_str(),
                .finish_reason = "null",
                .tool_calls = null,
                .tool_call_id = null,
                .agent_name = effective_agent_name,
                .loop_index = loop_counter,
                .temperature = agent_temperature,
                .is_thinking = isThinking,
                .prompt_tokens = 0,
                .completion_tokens = 0,
                .total_tokens = 0,
                .parent_id = copy_parent_session_id,
                .parent_session_id = copy_parent_session_id,
                .is_input = true,
                .is_output = false,
            }) catch {};

            _ = on_event_sent.onEventSendLLMHistory(allocator, .{
                .session_id = copy_session_id,
                .model = effective_model,
                .cwd = copy_cwd,
                .content = diagnostic,
                .reasoning_content = null,
                .role = agent.Role.user.to_str(),
                .finish_reason = "null",
                .tool_calls_json = null,
                .tool_call_id = null,
                .tool_name = null,
                .agent_name = effective_agent_name,
                .loop_index = loop_counter,
                .temperature = agent_temperature,
                .is_thinking = isThinking,
                .is_input = true,
                .is_output = false,
                .parent_session_id = copy_parent_session_id,
                .parent_id = copy_parent_session_id,
                .image_url = null,
                .session_skills = session_skills_bail,
            }) catch {};

            return error.TooManyRetries;
        }

        var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;

        const db_messages = try llm_history.getMessages(allocator, db, copy_session_id);
        const is_task_kanban = try llm_history.isTaskKanban(allocator, db, copy_session_id);
        const is_task_design = try llm_history.isTaskDesign(allocator, db, copy_session_id);
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
        if (loop_counter == 1 and is_task_kanban == false and is_task_design == false) {
            generateSessionNameNew(db_messages, allocator, effective_api_key, effective_model, effective_base_url, copy_session_id, logger, io, db);
        }

        const initialMessages = try build_msg_prompt.buildMessages(allocator, io, db, copy_cwd, copy_session_id, copy_parent_session_id, db_messages, merged_tools, copy_inherited_context, sub_agent_system_prompt);

        try messagesLists.appendSlice(allocator, initialMessages);

        const is_do_compaction = try maybeCompactMessagesNew(allocator, total_tokens, effective_model, false, &messagesLists, effective_api_key, effective_base_url, copy_cwd, copy_session_id, db, io, logger, config);
        if (is_do_compaction) {
            continue;
        }

        logger.debugFmt("[WORKFLOW-debug-system-prompt] system_prompt={s}", .{messagesLists.items[0].content.?});

        const res_dynamic_agent = callDynamicAgentNew(allocator, io, messagesLists, agent_temperature, current_max_tokens, isThinking, effective_api_key, effective_model, effective_base_url, effective_url_style, copy_session_id, merged_tools) catch |err| {
            if (err == error.Cancelled) {
                logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
                break;
            }
            retry_count += 1;
            // Capture WHY this retry fired so the AI agent can understand
            // the cause when the retry budget is eventually exhausted.
            last_retry_error = err;
            last_retry_source = "callDynamicAgentNew";
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
                const session_skills_dynamic = try llm_history.getSessionSkills(allocator, db, copy_session_id);
                defer for (session_skills_dynamic) |*skill| {
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
                if (config.notify_on_complete and copy_is_sub_agent == false) {
                    const preview = if (res_dynamic_agent.content) |c| c else "(empty response)";
                    try notifications.notify(io, allocator, "Agent Nalar", preview);
                }

                try llm_history.markSessionIdle(allocator, db, copy_session_id);

                break;
            } else if (finish_reason == .length) {
                current_max_tokens += 4096;
                continue;
            } else if (finish_reason == .tool_calls) {
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
                    const session_skills_assistant = try llm_history.getSessionSkills(allocator, db, copy_session_id);
                    defer for (session_skills_assistant) |*skill| {
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
                const session_skills_retry = try llm_history.getSessionSkills(allocator, db, copy_session_id);
                defer for (session_skills_retry) |*skill| {
                    allocator.free(skill.skill_name);
                    allocator.free(skill.content);
                };

                _ = try on_event_sent.onEventSendLLMHistory(allocator, .{
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
                });
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
    messages_list: std.ArrayList(agent.AgentMessage),
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
/// messages. Returns `true` if compaction was performed (caller should re-enter
/// the loop with the now-compacted list), `false` if no compaction was done.
/// Errors from `compactMessageInMemoryNew` propagate to the caller.
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
    llm_config: *const config_mod.LlmConfig,
) !bool {
    if (!force and !agent.LLMModels.shouldCompact(
        total_tokens,
        // No profile/sub-agent in scope at this call site — pass null
        // for both so the resolver falls back through the top-level
        // defaults (the orchestrator's own config) to the built-in
        // LLMModels per-model capacity + 80% threshold. Future
        // refactors that thread `profile_name` + `sub_agent_name` here
        // will pick up per-profile overrides via the cascade.
        llm_config.maxCapacityForModel(null, null, llm_config, model),
        llm_config.compactionThresholdPercent(null, null, llm_config),
    )) {
        return false;
    }

    // Snapshot the current messages so that callCompactAgentNew's in-place mutation
    // of index 0 (rewriting it to the compaction system prompt) does not leak back
    // into the caller's list if the compact call fails.
    const copy_messages = try allocator.dupe(agent.AgentMessage, messages.items);
    defer allocator.free(copy_messages);
    var copy_list = std.ArrayList(agent.AgentMessage).fromOwnedSlice(copy_messages);
    defer copy_list.deinit(allocator);

    const compacted_xml = callCompactAgentNew(copy_list, allocator, api_key, model, base_url, cwd, logger, io) orelse {
        // LLM call failed; caller keeps the original (uncompacted) list.
        return false;
    };

    // compactMessageInMemoryNew consumes the old list and returns the compacted one.
    // Replace the caller's list in place so the next loop iteration sees the
    // compacted messages.
    _ = try compactMessageInMemoryNew(allocator, messages.*, compacted_xml, session_id, model, cwd, db, io, logger);
    return true;
}

/// Call CompactionAgent to compress conversation history.
/// Returns compacted context or null on failure.
/// Call CompactionAgent to compress conversation history.
/// Returns compacted context or null on failure.
pub fn callCompactAgentNew(
    messages: std.ArrayList(agent.AgentMessage),
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    cwd: []const u8,
    logger: *logger_mod.Logger,
    io: std.Io,
) ?[]const u8 {
    _ = cwd;

    if (messages.items.len < 2) {
        logger.warnFmt("[COMPACTION] Not enough messages to compact", .{});
        return null;
    }

    const last_idx = messages.items.len - 1;

    // The original agent's system prompt — assumed to live at index 0.
    // Used for context only (constraints/tools/scope), not summarized as conversation.
    const original_system_prompt: []const u8 = messages.items[0].content orelse "";

    // Collect content from all messages between first and last,
    // labeled by role so the CompactionAgent can tell turns apart
    // instead of receiving one undifferentiated blob of text.
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (messages.items[1..last_idx]) |msg| {
        if (msg.content) |c| {
            const role_str = msg.role.to_str();
            const labeled = std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ role_str, c }) catch |err| {
                logger.errFmt("[COMPACTION] Failed to label message content: {s}", .{@errorName(err)});
                return null;
            };
            parts.append(allocator, labeled) catch |err| {
                logger.errFmt("[COMPACTION] Failed to collect message content: {s}", .{@errorName(err)});
                return null;
            };
        }

        // If the message carries structured tool calls (e.g. assistant
        // messages with finish_reason == .tool_calls), surface those too —
        // otherwise the compactor never sees that a tool was invoked at all
        // when content is null or purely conversational.
        if (msg.tool_calls) |tool_calls| {
            for (tool_calls) |tc| {
                const tc_str = std.fmt.allocPrint(allocator, "[tool_call]: {s}({s})", .{
                    tc.function.name,
                    tc.function.arguments,
                }) catch continue;
                parts.append(allocator, tc_str) catch continue;
            }
        }
    }

    const history_str = std.mem.join(allocator, "\n", parts.items) catch |err| {
        logger.errFmt("[COMPACTION] Failed to join history: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(history_str);

    const compact_message = std.fmt.allocPrint(allocator,
        \\You are preparing a handoff package for a fresh AI coding agent.
        \\The next agent has ZERO context. It cannot ask questions. It must act immediately.
        \\
        \\Rules:
        \\- Be surgical. No narrative, no filler, no summaries of conversation.
        \\- Every line must help the next agent take action or avoid a mistake.
        \\- If something was tried and failed, say exactly why — not just "it failed".
        \\- If a file was modified, say what changed and why, not just the filename.
        \\- The NEXT ACTION must be a single concrete step, not a vague goal.
        \\- If there are blockers, say what they are and what was tried to unblock them.
        \\
        \\Output exactly this structure, no extra sections:
        \\
        \\GOAL:
        \\(The original user objective, one or two sentences max)
        \\
        \\CURRENT STATE:
        \\- cwd:
        \\- repo:
        \\- branch:
        \\- worktree:
        \\- build status: (passing / failing / unknown)
        \\- test status: (passing / failing / unknown)
        \\
        \\TECH STACK:
        \\(Languages, frameworks, build tools — only what is relevant to the task)
        \\
        \\FILES MODIFIED:
        \\(path — what changed and why, one line per file)
        \\
        \\KEY DISCOVERIES:
        \\(Non-obvious things learned about the codebase, APIs, or constraints)
        \\
        \\FAILED ATTEMPTS:
        \\(What was tried, what happened, root cause if known)
        \\
        \\OPEN ISSUES:
        \\(Unresolved problems blocking or threatening progress)
        \\
        \\ASSUMPTIONS MADE:
        \\(Decisions taken without explicit user confirmation)
        \\
        \\NEXT ACTION:
        \\(Exactly one concrete step. File to edit, command to run, function to write.)
        \\
        \\AFTER THAT:
        \\(The 2-3 steps that follow NEXT ACTION, in order)
        \\
        \\DO NOT:
        \\(Pitfalls, wrong paths, things that look right but aren't)
        \\
        \\---
        \\ORIGINAL SYSTEM PROMPT (context only — constraints, tools, scope the
        \\original agent operated under. Do NOT summarize this section itself;
        \\use it only to inform DO NOT / ASSUMPTIONS MADE / FAILED ATTEMPTS above):
        \\{s}
        \\
        \\---
        \\CONVERSATION HISTORY:
        \\{s}
    , .{ original_system_prompt, history_str }) catch |err| {
        logger.errFmt("[COMPACTION] Failed to format compact message: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(compact_message);

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

/// Compact messages in memory based on CompactionAgent output.
/// Also persists to database: marks old messages as not for LLM, saves new compacted message.
/// On success, consumes `messages` (frees its backing slice) and returns the new
/// compacted list. On the `total <= 4` early return or any error before deinit,
/// `messages` is left intact and returned unchanged — the caller must always use
/// the return value.
pub fn compactMessageInMemoryNew(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(agent.AgentMessage),
    compacted_xml: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *logger_mod.Logger,
) !std.ArrayList(agent.AgentMessage) {
    const total = messages.items.len;
    if (total <= 4) return messages;

    // Mark all existing messages in this session as not for LLM (soft-delete)
    try llm_history.markMessageNotForLlmRun(allocator, db, session_id);

    // Build the compacted summary content with XML wrapping
    const summary_content = try buildCompactionEnvelope(
        allocator,
        messages.items[1..],
        total,
        session_id,
        model,
        io,
        compacted_xml,
        logger,
    );

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

    // Free ALL old messages (including ones we "kept" - we have copies now).
    // The old list is consumed; the caller must use the returned list.
    // Use a mutable local copy because the `messages` parameter is treated
    // as `const` in Zig 0.16 when the function signature has matching
    // parameter and return types (T → !T), and ArrayList.deinit requires
    // `*Self` (not `*const Self`).
    var messages_owned = messages;
    for (messages_owned.items) |*msg| {
        msg.deinit(allocator);
    }
    messages_owned.deinit(allocator);

    logger.debugFmt("[COMPACTION] Compacted: {} -> {} messages (persisted to DB)", .{ total, new_messages.items.len });
    return new_messages;
}

/// Build the structured `<compact_messages>` envelope that replaces
/// the dropped messages after compaction. The envelope has three
/// sections: <metadata> (compaction event facts), <message_index>
/// (id+role+preview for every dropped message so the agent can
/// reference them later via read_compacted_messages), and <summary>
/// (the compactor's output, preserved verbatim).
///
/// `dropped_messages` is the slice of messages that will be marked
/// `is_feed_to_llm=0` — typically `messages.items[1..]` for the
/// compactMessageInMemoryNew caller. We capture their metadata HERE
/// (in memory) rather than re-querying the DB, because these messages
/// still have their content/tool_call_id fields available in the
/// in-memory struct.
///
/// Caller owns the returned string and must free with `allocator.free`.
const MAX_INDEX_ENTRIES: usize = 50;
const MAX_SUMMARY_BYTES: usize = 20_000;

fn buildCompactionEnvelope(
    allocator: std.mem.Allocator,
    dropped_messages: []const agent.AgentMessage,
    original_count: usize,
    session_id: []const u8,
    model: []const u8,
    io: std.Io,
    compacted_xml: []const u8,
    logger: *logger_mod.Logger,
) ![]u8 {
    // Real RFC3339-ish timestamp from std.Io.Timestamp — same pattern
    // the logger's Timing.timestampIso uses. Non-empty so the test
    // can verify the tag is present without hardcoding a value.
    const now_iso = try logger_mod.timestampIso(allocator, io);
    defer allocator.free(now_iso);

    var env: std.ArrayList(u8) = .empty;
    defer env.deinit(allocator);

    try env.appendSlice(allocator, "<compact_messages>\n");

    // --- metadata header ---
    try env.print(allocator,
        \\  <metadata>
        \\    <session_id>{s}</session_id>
        \\    <model>{s}</model>
        \\    <compacted_at>{s}</compacted_at>
        \\    <original_count>{d}</original_count>
        \\  </metadata>
        \\
    , .{ session_id, model, now_iso, original_count });

    // --- message_index ---
    // Capped to MAX_INDEX_ENTRIES so a very long session (e.g. 360+
    // dropped messages) can't blow up the envelope size on its own;
    // we keep the most RECENT dropped messages since those are most
    // likely to be relevant to what the agent does next, and note how
    // many older entries were omitted (full content still recoverable
    // from the DB via read_compacted_messages / session_id).
    try env.appendSlice(allocator, "  <message_index>\n");

    const show_count = @min(dropped_messages.len, MAX_INDEX_ENTRIES);
    const start_idx = dropped_messages.len - show_count;
    const omitted_count = dropped_messages.len - show_count;

    if (omitted_count > 0) {
        try env.print(
            allocator,
            "    <truncated_entries count=\"{d}\" note=\"older entries omitted from index; use read_compacted_messages with session_id to fetch full history from DB\"/>\n",
            .{omitted_count},
        );
    }

    for (dropped_messages[start_idx..], start_idx..) |msg, i| {
        const msg_id = try std.fmt.allocPrint(allocator, "adhoc_{d}", .{i});
        defer allocator.free(msg_id);

        const role_str = msg.role.to_str();
        const preview = msg.content orelse "";
        // Byte-slice cap; fine for ASCII previews. If non-English content
        // is common, swap for a UTF-8-aware trim so we don't cut a
        // multi-byte codepoint in half.
        const preview_trimmed = if (preview.len > 100) preview[0..100] else preview;
        const preview_escaped = try helpers.xml_escape(allocator, preview_trimmed);
        defer allocator.free(preview_escaped);

        try env.print(allocator,
            \\    <entry>
            \\      <id>{s}</id>
            \\      <role>{s}</role>
            \\
        , .{ msg_id, role_str });

        // For tool-result messages, surface tool_call_id so the agent
        // can match results back to calls. (tool_name is not available
        // on the in-memory AgentMessage struct in this codebase; the
        // read_compacted_messages tool can fetch it from the DB row.)
        if (msg.role == .tool) {
            const tcid = msg.tool_call_id orelse "";
            const tcid_escaped = try helpers.xml_escape(allocator, tcid);
            defer allocator.free(tcid_escaped);
            try env.print(allocator, "      <tool_call_id>{s}</tool_call_id>\n", .{tcid_escaped});
        }

        try env.print(allocator,
            \\      <preview>{s}</preview>
            \\    </entry>
            \\
        , .{preview_escaped});
    }

    try env.appendSlice(allocator, "  </message_index>\n");

    // --- summary (the compactor's output) ---
    // Hard cap as a safety net — the real budget should be enforced via
    // the compactor prompt itself, but we never want a misbehaving model
    // response to produce an unbounded envelope.
    const summary_to_embed = if (compacted_xml.len > MAX_SUMMARY_BYTES)
        compacted_xml[0..MAX_SUMMARY_BYTES]
    else
        compacted_xml;

    // Wrapped in CDATA so embedded <, >, & in the summary (quoted file
    // contents, shell output, diffs, etc.) can never break the envelope.
    // If the summary itself contains the CDATA close sequence "]]>", we
    // split it into adjacent CDATA sections rather than escaping, so the
    // model still sees natural punctuation everywhere else.
    try env.appendSlice(allocator, "  <summary><![CDATA[\n");
    if (std.mem.indexOf(u8, summary_to_embed, "]]>") == null) {
        try env.appendSlice(allocator, summary_to_embed);
    } else {
        var rest = summary_to_embed;
        while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
            try env.appendSlice(allocator, rest[0 .. idx + 2]); // up to and incl "]]"
            try env.appendSlice(allocator, "]]><![CDATA[>"); // close, literal '>', reopen
            rest = rest[idx + 3 ..];
        }
        try env.appendSlice(allocator, rest);
    }
    try env.appendSlice(allocator, "\n]]></summary>\n");

    try env.appendSlice(allocator, "</compact_messages>\n");

    const result = try env.toOwnedSlice(allocator);
    logger.debugFmt(
        "[COMPACTION] envelope size: {d} bytes, {d}/{d} index entries shown, summary {d}/{d} bytes",
        .{ result.len, show_count, dropped_messages.len, summary_to_embed.len, compacted_xml.len },
    );
    return result;
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
