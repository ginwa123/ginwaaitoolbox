const mod = @import("mod.zig");
const std = @import("std");

const nalarcore = mod.nalarcore;

const llm_history = @import("llm_history.zig");
const build_msg_prompt = @import("build_messages_for_agent_prompt.zig");
const models = @import("models.zig");
const on_event_sent = @import("on_event_sent.zig");
const tool_registry = @import("tool_registry.zig");
const handle_tool = @import("handle_tool.zig").handle_tool;
const notifications = nalarcore.notifications_mod;

const sqlite = nalarcore.sqlite;
const config_mod = nalarcore.config;
const logger_mod = nalarcore.loggermod;
const agent = nalarcore.agent;
const prompt = nalarcore.agent.prompt;
const helpers = nalarcore.helpers;

const json = std.json;

const agentic_loop_mod = nalarcore.agentic_loop_mod;
const event_bus_mod = nalarcore.event_bus;

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
        const active_loops = di.active_loops;
        const event_bus = di.event_bus;
        const db = di.db;
        const io = di.io;
        const session_id = data.session_id;
        const config = nalarcore.getLlmConfig(di);
        const cwd = data.cwd;
        const environment = di.environment;

        runAgenticMultiStepnew(.{
            .allocator = allocator,
            .db = db,
            .io = io,
            .logger = logger,
            .event_bus = event_bus,
            .active_loops = active_loops,
            .llm_config = config,
            .environment = environment,
        }, data) catch |err| {
            logger.errFmt("[{s}] Failed to run agentic workflow: {s}\n", .{ keyword, @errorName(err) });

            agentic_loop_mod.deleteWorker(.{
                .allocator = allocator,
                .db = db,
                .logger = logger,
                .session_id = session_id,
                .event_bus = di.event_bus,
                .is_emit_sse = true,
            }) catch |error_sqlite| {
                logger.errFmt("[{s}] Failed to delete worker: {s}\n", .{ keyword, @errorName(error_sqlite) });
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

            const id = std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}) catch return;
            defer allocator.free(id);

            const created_at = std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}) catch return;
            defer allocator.free(created_at);

            agentic_loop_mod.insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = cwd, .entity = .{ .id = id, .session_id = session_id, .model = config.model, .response_content = error_message, .reasoning_content = null, .role = agent.Role.user.to_str(), .finish_reason = "null", .tool_calls_json = "", .tool_call_id = null, .agent = initial_agent, .loop_index = 0, .temperature = initial_agent_state.temperature, .is_thinking = initial_agent_state.is_thinking, .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0, .parent_id = session_id, .parent_session_id = session_id, .is_input = true, .is_output = false, .is_feed_to_llm = false, .image_urls = null, .created_at = created_at } }) catch return;
        };
    }
};

pub const RunAgenticMultiStepInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    event_bus: *event_bus_mod.EventBus,
    active_loops: *models.ActiveLoops,
    llm_config: *config_mod.LlmConfig,
    environment: ?*const std.process.Environ.Map,
};

pub fn runAgenticMultiStepnew(di: RunAgenticMultiStepInput, params: RunParamsNew) !void {
    var parent_arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
    defer parent_arena_allocator.deinit();
    const parent_allocator = parent_arena_allocator.allocator();

    const db = di.db;
    const logger = di.logger;
    const active_loops = di.active_loops;
    const event_bus = di.event_bus;
    const io = di.io;
    const config = di.llm_config;
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
    const is_worker_running = agentic_loop_mod.isWorkerRunning(parent_allocator, db, copy_session_id);
    if (is_worker_running and active_loops.contains(io, copy_session_id)) {
        // Session is already running, queue the message
        try agentic_loop_mod.insertQueueMessage(agentic_loop_mod.InsertQueueMessageInput{
            .allocator = parent_allocator,
            .db = db,
            .logger = logger,
            .session_id = copy_session_id,
            .message = copy_message,
            .image_url = copy_image_urls,
            .event_bus = event_bus,
            .is_emit_sse = true,
        });
        is_have_queue_message = true;
        return;
    }
    defer {
        agentic_loop_mod.deleteWorker(.{
            .allocator = parent_allocator,
            .db = db,
            .logger = logger,
            .session_id = copy_session_id,
            .event_bus = event_bus,
            .is_emit_sse = true,
        }) catch |err| {
            logger.errFmt("Failed to delete worker: {s}", .{@errorName(err)});
        };
    }

    defer active_loops.remove(io, copy_session_id);

    try agentic_loop_mod.updateWorker(agentic_loop_mod.UpdateWorkerInput{
        .allocator = parent_allocator,
        .db = db,
        .logger = logger,
        .worker_id = copy_session_id,
        .session_id = copy_session_id,
        .working_directory = copy_cwd,
        .event_bus = event_bus,
        .is_emit_sse = true,
    });

    // Queue the initial message
    try agentic_loop_mod.insertQueueMessage(agentic_loop_mod.InsertQueueMessageInput{
        .allocator = parent_allocator,
        .db = db,
        .logger = logger,
        .session_id = copy_session_id,
        .message = copy_message,
        .image_url = copy_image_urls,
        .event_bus = event_bus,
        .is_emit_sse = true,
    });

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
        if (agentic_loop_mod.isWorkerCancelled(agentic_loop_mod.IsWorkerCancelledInput{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        })) {
            logger.infoFmt("WORKFLOW CANCELLED while looping back for next API call...", .{});
            break;
        }

        // Get queued messages from DB
        var queued_messages = try agentic_loop_mod.getQueueMessage(agentic_loop_mod.GetQueueMessageInput{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        });
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

                try agentic_loop_mod.insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = copy_cwd, .entity = .{
                    .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .session_id = copy_session_id,
                    .model = effective_model,
                    .response_content = queued.message,
                    .reasoning_content = null,
                    .role = agent.Role.user.to_str(),
                    .finish_reason = "null",
                    .tool_calls_json = "",
                    .tool_call_id = null,
                    .agent = initial_agent,
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
                    .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                } });

                try agentic_loop_mod.deleteQueuedMessage(.{
                    .allocator = allocator,
                    .db = db,
                    .is_emit_sse = true,
                    .event_bus = event_bus,
                    .session_id = copy_session_id,
                    .message = queued.message,
                });
            }
        }

        try agentic_loop_mod.updateWorker(agentic_loop_mod.UpdateWorkerInput{
            .allocator = allocator,
            .db = db,
            .logger = logger,
            .worker_id = copy_session_id,
            .session_id = copy_session_id,
            .working_directory = copy_cwd,
            .event_bus = event_bus,
            .is_emit_sse = true,
        });

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

            try agentic_loop_mod.insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = copy_cwd, .entity = .{
                .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                .session_id = copy_session_id,
                .model = effective_model,
                .response_content = diagnostic,
                .reasoning_content = null,
                .role = agent.Role.user.to_str(),
                .finish_reason = "null",
                .tool_calls_json = "",
                .tool_call_id = null,
                .agent = effective_agent_name,
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
                .image_urls = null,
                .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
            } });

            return error.TooManyRetries;
        }

        var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;
        const db_messages = try agentic_loop_mod.getLLMHistories(.{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        });
        const is_task_kanban = try agentic_loop_mod.isSessionKanban(allocator, db, copy_session_id);
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
        if (loop_counter == 1 and is_task_kanban == false) {
            generateSessionNameNew(db_messages, allocator, effective_api_key, effective_model, effective_base_url, copy_session_id, logger, io, db, event_bus);
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
                try agentic_loop_mod.insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = copy_cwd, .entity = .{
                    .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .session_id = copy_session_id,
                    .model = effective_model,
                    .response_content = res_dynamic_agent.content orelse "",
                    .reasoning_content = res_dynamic_agent.reasoning_content,
                    .role = agent.Role.assistant.to_str(),
                    .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else "stop",
                    .tool_calls_json = "",
                    .tool_call_id = null,
                    .agent = effective_agent_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .prompt_tokens = @intCast(res_dynamic_agent.usage.prompt_tokens),
                    .completion_tokens = @intCast(res_dynamic_agent.usage.completion_tokens),
                    .total_tokens = @intCast(res_dynamic_agent.usage.total_tokens),
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .is_input = false,
                    .is_output = true,
                    .image_urls = null,
                    .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .is_feed_to_llm = true,
                } });

                const isHaveQueueMessage = agentic_loop_mod.hasQueuedMessages(allocator, db, copy_session_id);
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

                // try llm_history.markSessionIdle(allocator, db, copy_session_id);
                try agentic_loop_mod.deleteWorker(agentic_loop_mod.DeleteWorkerInput{
                    .allocator = allocator,
                    .db = db,
                    .logger = logger,
                    .session_id = copy_session_id,
                    .event_bus = event_bus,
                    .is_emit_sse = true,
                });

                break;
            } else if (finish_reason == .length) {
                current_max_tokens += 4096;
                continue;
            } else if (finish_reason == .tool_calls) {
                try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, effective_model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, active_loops, copy_selected_profile_model);
            } else {
                retry_count += 1;
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
    db_messages: []agentic_loop_mod.LLMHistory,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    session_id: []const u8,
    logger: *logger_mod.Logger,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    event_bus: *event_bus_mod.EventBus,
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
        agentic_loop_mod.updateSessionName(allocator, db, session_id, stripped_content, event_bus) catch {
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
    // BUG FIX 2026-07-14: missing `defer dynamic_agent.deinit()` was leaking
    // `httpClient`'s connection pool / sockets on every workflow loop iteration.
    // After extended uptime the leak reaches the soft FD limit (1024) and triggers
    // `error.ProcessFdQuotaExceeded` in any subsequent FD-allocating call. The
    // other two `Agent.init` call sites in this codebase already had the matching
    // defer: `name_agent` (workflow.zig:637) and `compaction_agent`
    // (compaction.zig:168). `Agent.deinit()` (Agent.zig:1815) calls
    // `self.httpClient.deinit()` which frees any pooled HTTP connections.
    defer dynamic_agent.deinit();
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
        llm_config.maxCapacityForModel(null, null, llm_config, model),
        llm_config.compactionThresholdPercent(null, null, llm_config),
    )) {
        return false;
    }

    const copy_messages = try allocator.dupe(agent.AgentMessage, messages.items);
    defer allocator.free(copy_messages);
    var copy_list = std.ArrayList(agent.AgentMessage).fromOwnedSlice(copy_messages);
    defer copy_list.deinit(allocator);

    const compacted_xml = agentic_loop_mod.callCompactAgent(
        .{
            .allocator = allocator,
            .io = io,
            .messages = copy_list,
            .api_key = api_key,
            .model = model,
            .base_url = base_url,
            .logger = logger,
        },
    ) orelse {
        return false;
    };

    _ = try compactMessageInMemoryNew(allocator, messages.*, compacted_xml, session_id, model, cwd, db, io, logger);
    return true;
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
/// reference them later via search_history), and <summary>
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
    // from the DB via search_history / session_id).
    try env.appendSlice(allocator, "  <message_index>\n");

    const show_count = @min(dropped_messages.len, MAX_INDEX_ENTRIES);
    const start_idx = dropped_messages.len - show_count;
    const omitted_count = dropped_messages.len - show_count;

    if (omitted_count > 0) {
        try env.print(
            allocator,
            "    <truncated_entries count=\"{d}\" note=\"older entries omitted from index; use search_history with session_id to fetch full history from DB\"/>\n",
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
        // search_history tool can fetch it from the DB row.)
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
    var base_tools = try allocator.alloc(agent.AgentTool, agentic_loop_mod.tools.all_agent_tools(allocator).len);
    @memcpy(base_tools, agentic_loop_mod.tools.all_agent_tools(allocator));

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

pub const SubAgentOverrides = struct {
    resolved_name: []const u8,
    is_random_fallback: bool,
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    url_style: []const u8 = "",
    is_thinking: ?bool = null,
    temperature: ?f32 = null,
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
    selected_profile_model: []const u8 = "",
    inherited_context: []const u8 = "",
    sub_agent_overrides: ?SubAgentOverrides = null,
};
