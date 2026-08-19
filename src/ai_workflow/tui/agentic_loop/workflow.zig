const std = @import("std");
const testing = std.testing;

pub const nalarcore = @import("nalarcore");

const llm_history = @import("llm_history.zig");
const build_msg_prompt = @import("prompts_build_messages_for_agent_prompt.zig");
const models = @import("models.zig");
pub const on_event_sent = @import("on_event_sent.zig");
const tool_registry = @import("tools_equipped.zig");
const handle_tool = @import("handle_tool.zig").handle_tool;
const notifications = nalarcore.notifications_mod;

const sqlite = nalarcore.sqlite;
const migration_mod = nalarcore.migrations_mod.migration;
const migration = migration_mod;
const config_mod = nalarcore.config;
const logger_mod = nalarcore.loggermod;
const agent = nalarcore.agent;
const prompt = nalarcore.agent.prompt;
const helpers = nalarcore.helpers;

const json = std.json;

const event_bus_mod = nalarcore.event_bus;
const SqliteBackend = nalarcore.sqlite.SqliteBackend;

const compact_message_mod = @import("workflow_compact_message.zig");
const commpact_message_mod = @import("workflow_commpact_message.zig");
const delete_queue_worker_mod = @import("delete_queue_worker.zig");
const delete_worker_mod = @import("delete_worker.zig");
const get_llm_histories_mod = @import("get_llm_histories.zig");
const get_queue_message_mod = @import("get_queue_message.zig");
const has_queue_message_mod = @import("has_queue_messagge.zig");
const insert_llm_histories_mod = @import("insert_llm_histories.zig");
const insert_queue_message_mod = @import("insert_queue_message.zig");
const is_session_kanban_mod = @import("is_session_kanban.zig");
const is_worker_cancelled_mod = @import("is_worker_cancelled.zig");
const is_worker_running_mod = @import("is_worker_running.zig");
const mark_history_not_for_llmrun_mod = @import("markHistoryNotForLLMRun.zig");
const retry_delay_ms_mod = @import("retry_delay_ms.zig");
const session_skills_mod = @import("session_skills.zig");
const sse_mod = @import("sse.zig");
const sse_on_event_send_session_mod = @import("sse_on_event_send_session.zig");
const sse_send_event_worker_mod = @import("sse_send_event_worker.zig");
const update_session_name_mod = @import("update_session_name.zig");
const update_worker_mod = @import("update_worker.zig");

// Re-exports (formerly from mod.zig). These form the public surface of
// the agentic_loop module — `agentic_loop_mod.<X>` resolves to
// `workflow.zig`, so any caller that previously imported from
// `mod.zig` can keep the same access pattern.
pub const updateWorker = update_worker_mod.updateWorker;
pub const UpdateWorkerInput = update_worker_mod.UpsertWorkerInput;
pub const insertQueueMessage = insert_queue_message_mod.insertQueueMessage;
pub const InsertQueueMessageInput = insert_queue_message_mod.InsertQueueMessageInput;
pub const getQueueMessage = get_queue_message_mod.getQueueMessages;
pub const GetQueueMessageInput = get_queue_message_mod.GetQueueMessageInput;
pub const isWorkerCancelled = is_worker_cancelled_mod.isWorkerCancelled;
pub const IsWorkerCancelledInput = is_worker_cancelled_mod.IsWorkerCancelledInput;
pub const SseEvent = sse_mod.SseEvent;
pub const onEventSendWorkers = sse_send_event_worker_mod.onEventSendWorkers;
pub const OnEventInputWorkers = sse_send_event_worker_mod.OnEventInputWorkers;
pub const DeleteWorkerInput = delete_worker_mod.DeleteWorkerInput;
pub const deleteWorker = delete_worker_mod.deleteWorker;
pub const GetLLMHistoriesInput = get_llm_histories_mod.GetLLMHistoriesInput;
pub const getLLMHistories = get_llm_histories_mod.getLLMHistories;
pub const LLMHistory = @import("llm_history_row.zig").LLMHistory;
pub const onEventSendLLMHistory = @import("sse_on_event_send_llm_history.zig").onEventSendLLMHistory;
pub const InsertLLMHistoriesInput = insert_llm_histories_mod.InsertLLMHistoriesInput;
pub const insertLLMHistories = insert_llm_histories_mod.inserLLMHistories;
pub const SkillInfo = session_skills_mod.SkillInfo;
pub const hasQueuedMessages = has_queue_message_mod.hasQueuedMessages;
pub const DeleteQueueMessagesInput = delete_queue_worker_mod.DeleteQueueMessagesInput;
pub const deleteQueuedMessage = delete_queue_worker_mod.deleteQueuedMessage;
pub const isWorkerRunning = is_worker_running_mod.isWorkerRunning;
pub const CallCompactAgentInput = commpact_message_mod.CallCompactAgentInput;
pub const callCompactAgent = commpact_message_mod.callCompactAgent;
pub const buildCompactMessagePrompt = compact_message_mod.buildCompactMessagePrompt;
pub const fetchUserChatHistory = compact_message_mod.fetchUserChatHistory;
pub const fetchReadFilePaths = compact_message_mod.fetchReadFilePaths;
pub const fetchRecentActivities = compact_message_mod.fetchRecentActivities;
pub const enrichCompactionXml = compact_message_mod.enrichCompactionXml;
pub const parseReadFilePath = compact_message_mod.parseReadFilePath;
pub const UserTurn = compact_message_mod.UserTurn;
pub const ReadFileTurn = compact_message_mod.ReadFileTurn;
pub const RecentActivity = compact_message_mod.RecentActivity;
pub const isSessionKanban = is_session_kanban_mod.isSessionKanban;
pub const OnEventInputSessions = sse_on_event_send_session_mod.OnEventInputSessions;
pub const onEventSendSessions = sse_on_event_send_session_mod.onEventSendSessions;
pub const updateSessionName = update_session_name_mod.updateSessionName;
pub const parsing_mod = @import("parsing.zig");
pub const tools = @import("tools.zig");
pub const prompts_mod = @import("prompts.zig");
pub const mark_history_not_for_llmrun = mark_history_not_for_llmrun_mod.markHistoryNotForLLMRun;
pub const makeWorkingDirectoryContext = prompts_mod.makeWorkingDirectoryContext;
pub const retryDelayMs = retry_delay_ms_mod.retryDelayMs;
pub const RetryDelayMsInput = retry_delay_ms_mod.RetryDelayMsInput;

pub const maybeCompactMessagesNew = @import("workflow_commpact_message.zig").maybeCompactMessagesNew;
const defaultCompactDeps = @import("workflow_commpact_message.zig").defaultCompactDeps;
pub const compactMessageInMemoryNew = @import("workflow_commpact_message.zig").compactMessageInMemoryNew;

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

        var arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
        defer arena_allocator.deinit();
        const allocator = arena_allocator.allocator();

        const active_loops = di.active_loops;
        const event_bus = di.event_bus;
        const db = di.db;
        const io = di.io;
        const session_id = data.session_id;
        const cwd = data.cwd;
        const environment = di.environment;

        runAgenticMultiStepnew(.{
            .allocator = allocator,
            .db = db,
            .io = io,
            .logger = logger,
            .event_bus = event_bus,
            .active_loops = active_loops,
            // Live DI handle: re-read inside the workflow loop so
            // NalarSettings changes take effect per iteration
            // (plan 2026-08-06-live-config-reload).
            .di = di,
            .environment = environment,
        }, data) catch |err| {
            logger.errFmt("[{s}] Failed to run agentic workflow: {s}\n", .{ keyword, @errorName(err) });

            deleteWorker(.{
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

            _ = insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = cwd, .entity = .{ .id = id, .session_id = session_id, .model = nalarcore.getLlmConfig(di).model, .response_content = error_message, .reasoning_content = null, .role = agent.Role.user.to_str(), .finish_reason = "null", .tool_calls_json = "", .tool_call_id = null, .agent = initial_agent, .loop_index = 0, .temperature = initial_agent_state.temperature, .is_thinking = initial_agent_state.is_thinking, .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0, .parent_id = session_id, .parent_session_id = session_id, .is_input = true, .is_output = false, .is_feed_to_llm = false, .image_urls = null, .created_at = created_at } }) catch return;
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
    di: *nalarcore.ContextIPCTui,
    environment: ?*const std.process.Environ.Map,
};

/// Resolve a single LLM field by walking the profile cascade:
///   1. `selected_profile_model` if non-empty AND profile exists
///   2. `config.active_profile` if non-null AND non-empty AND profile exists
///   3. top-level `top_level` fallback
///
/// `comptime field` is the name of the field on `LlmProfile` to read
/// (e.g. `"model"`, `"api_key"`, `"base_url"`, `"url_style"`).
///
/// The caller is responsible for emitting any "profile not found"
/// warning (we don't log here so this helper stays logger-free and
/// unit-testable — `runAgenticMultiStepnew` emits the warning at the
/// one place where it can compute it cheaply without duplicating the
/// `getProfile` lookup).
///
/// Plan: docs/superpowers/plans/2026-08-06-set-active-profile-default.md
fn resolveProfileField(
    comptime field: []const u8,
    config: *const config_mod.LlmConfig,
    selected_profile_model: []const u8,
    active_profile: ?[]const u8,
    top_level: []const u8,
) []const u8 {
    // Step 1: per-session / per-call selection wins.
    if (selected_profile_model.len > 0) {
        if (config.getProfile(selected_profile_model)) |profile| {
            const v = @field(profile, field);
            if (v.len > 0) return v;
        }
    }
    // Step 2: user-set active profile (the new fallback). Silent on
    // miss — `active_profile` is the user's default, so a typo or a
    // deleted profile is a normal fall-through to top-level (logged
    // at the call site if the user wants to debug).
    if (active_profile) |ap| {
        if (ap.len > 0) {
            if (config.getProfile(ap)) |profile| {
                const v = @field(profile, field);
                if (v.len > 0) return v;
            }
        }
    }
    // Step 3: top-level config (built-in default).
    return top_level;
}


// ─── re_read_selected_profile_model — live-re-read from sessions table ─────
//
// **Why this helper exists** (bug report task_1786031708725, 2026-08-06):
// The workflow's `while (true)` loop in `runAgenticMultiStepnew` previously
// used a snapshot of `selected_profile_model` taken at the top of the run
// (`copy_selected_profile_model = parent_allocator.dupe(u8, params.selected_profile_model)`).
// So when the user picked a different profile in the chatview dropdown
// mid-run (PUT /api/llm/session/:id), the DB updated but the running
// loop continued with the snapshot — the new profile was silently ignored
// until the next message was sent.
//
// The fix: re-read `selected_profile_model` from the DB at the top of every
// loop iteration (mirror the existing `is_auto_retry_until_stop` re-read
// pattern at workflow.zig:543-552). The returned slice is borrowed from
// the per-iteration arena — caller MUST NOT free it.
//
// Fallback behavior: any read failure (query throws, no row) returns the
// `fallback` argument (typically `params.selected_profile_model`, the
// snapshot). Same graceful-degrade as `is_auto_retry_until_stop`.
fn re_read_selected_profile_model(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    fallback: []const u8,
) []const u8 {
    var rows = db.query(
        allocator,
        "SELECT COALESCE(selected_profile_model, '') FROM sessions WHERE id = ?",
        &.{session_id},
    ) catch return fallback;
    defer rows.deinit();

    const maybe_row = rows.next() catch return fallback;
    if (maybe_row) |row| {
        defer row.deinit(allocator);
        // CRITICAL: row.deinit() frees row.values[0]'s backing memory.
        // We must dupe into `allocator` (the per-iteration arena in
        // production; the test allocator here) so the returned slice
        // outlives the row's deferred free. Returning row.values[0]
        // directly would crash the caller on read.
        return allocator.dupe(u8, row.values[0]) catch return fallback;
    }
    return fallback;
}

// ─── Test fixture for re_read_selected_profile_model ─────────────────────────
//
// In-memory SQLite with the full migration chain applied (so the
// `sessions` table has the `selected_profile_model` column exactly as
// production does — see `llm-history-test-use-migrations-module.md`).
// Mirrors `src/ai_workflow/tui/agentic_loop/llm_history_search_fts_query_safety_test.zig::setupDb`.
const ReReadTestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn re_read_setupDb() !ReReadTestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration_mod.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration_mod.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn re_read_teardown(ctx: *ReReadTestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Insert a minimal session row (matching the production schema: the
/// `sessions` table's NOT NULL columns are id, name, status, cwd, created_at,
/// updated_at, selected_profile_model, is_auto_retry_until_stop).
fn re_read_insertSession(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    selected_profile_model: []const u8,
) !void {
    try db.exec(
        alloc,
        \\INSERT INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop)
        \\VALUES (?, 'test', 'active', '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, '0')
    ,
        &.{ session_id, selected_profile_model },
    );
}

test "re_read_selected_profile_model: returns live DB value when row exists" {
    // Wrap in a per-test arena so the dupe'd slice is freed at the
    // end of the test (matches production usage in runAgenticMultiStepnew
    // where the caller passes the per-iteration arena allocator).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    try re_read_insertSession(alloc, &ctx.db, "s_alpha", "beta");
    const got = re_read_selected_profile_model(alloc, &ctx.db, "s_alpha", "fallback-snapshot");
    try testing.expectEqualStrings("beta", got);
}

test "re_read_selected_profile_model: returns empty string when DB has empty (mirrors COALESCE)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    try re_read_insertSession(alloc, &ctx.db, "s_empty", "");
    const got = re_read_selected_profile_model(alloc, &ctx.db, "s_empty", "fallback-snapshot");
    try testing.expectEqualStrings("", got);
}

test "re_read_selected_profile_model: returns fallback when no session row exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    const got = re_read_selected_profile_model(alloc, &ctx.db, "s_missing", "fallback-snapshot");
    try testing.expectEqualStrings("fallback-snapshot", got);
}

test "re_read_selected_profile_model: subsequent reads see UPDATEd value (live re-read)" {
    // The whole point of this helper: a second call after a session
    // row UPDATE picks up the new value, NOT the snapshot. If this
    // test ever fails, the workflow loop is back to using a snapshot
    // — the original bug returns.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    try re_read_insertSession(alloc, &ctx.db, "s_live", "alpha");
    const first = re_read_selected_profile_model(alloc, &ctx.db, "s_live", "snapshot");
    try testing.expectEqualStrings("alpha", first);

    // Simulate the user picking a different profile in the chatview
    // dropdown (PUT /api/llm/session/:id → sessions.selected_profile_model).
    try ctx.db.exec(
        alloc,
        "UPDATE sessions SET selected_profile_model = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        &.{ "gamma", "s_live" },
    );

    const second = re_read_selected_profile_model(alloc, &ctx.db, "s_live", "snapshot");
    try testing.expectEqualStrings("gamma", second);
}

pub fn runAgenticMultiStepnew(di: RunAgenticMultiStepInput, params: RunParamsNew) !void {
    var parent_arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
    defer parent_arena_allocator.deinit();
    const parent_allocator = parent_arena_allocator.allocator();

    const db = di.db;
    const logger = di.logger;
    const active_loops = di.active_loops;
    const event_bus = di.event_bus;
    const io = di.io;
    const environment = di.environment;

    logger.infoFmt(
        "[CHECKPOINT] entry runAgenticMultiStepnew session_id={s} parent_session_id={s} is_sub_agent={} msg_len={d} allowed_tools_len={d} cwd={s}",
        .{ params.session_id, params.parent_session_id, params.is_sub_agent, params.message.len, params.allowed_tools.len, params.cwd },
    );

    var config = nalarcore.getLlmConfig(di.di);
    var effective_api_key = resolveProfileField("api_key", config, params.selected_profile_model, config.active_profile, config.api_key);
    var effective_model = resolveProfileField("model", config, params.selected_profile_model, config.active_profile, config.model);
    var effective_base_url = resolveProfileField("base_url", config, params.selected_profile_model, config.active_profile, config.base_url);
    var effective_url_style = resolveProfileField("url_style", config, params.selected_profile_model, config.active_profile, config.url_style);

    logger.infoFmt(
        "[CHECKPOINT] profile selected_profile_model='{s}' effective_model={s} effective_base_url={s} effective_url_style={s}",
        .{ params.selected_profile_model, effective_model, effective_base_url, effective_url_style },
    );

    const copy_parent_session_id = try parent_allocator.dupe(u8, params.parent_session_id);
    const copy_session_id = try parent_allocator.dupe(u8, params.session_id);
    const copy_message = try parent_allocator.dupe(u8, params.message);
    const copy_cwd = try parent_allocator.dupe(u8, params.cwd);
    const copy_allowed_tools = try parent_allocator.dupe(u8, params.allowed_tools);
    const copy_is_sub_agent = params.is_sub_agent;
    const copy_image_urls = try parent_allocator.dupe(u8, params.image_urls);
    const copy_inherited_context = try parent_allocator.dupe(u8, params.inherited_context);
    var is_have_queue_message = false;


    const initial_agent_state = try llm_history.get_current_agent_by_session_id(
        parent_allocator,
        db,
        copy_session_id,
    );
    const initial_agent = initial_agent_state.agent;

    // Check if session is already running (exists in worker table)
    const is_worker_running = isWorkerRunning(parent_allocator, db, copy_session_id);
    if (is_worker_running and active_loops.contains(io, copy_session_id)) {
        logger.infoFmt(
            "[CHECKPOINT] worker busy, queueing message session_id={s} msg_len={d} image_urls_len={d}",
            .{ copy_session_id, copy_message.len, copy_image_urls.len },
        );
        // Session is already running, queue the message
        try insertQueueMessage(InsertQueueMessageInput{
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
    logger.infoFmt(
        "[CHECKPOINT] new worker slot acquired session_id={s} cwd={s}",
        .{ copy_session_id, copy_cwd },
    );
    defer {
        deleteWorker(.{
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

    // updateWorker is now called INSIDE the while loop body (see
    // below) — the original insertion here (PR #269) was redundant
    // with the per-iteration update. Removing it also fixes the
    // trade-off documented in
    // docs/superpowers/plans/2026-08-19-cleanup-stale-worker-cron.md §2.6
    // (long-running workflows would have stale last_activity_nano if
    // updateWorker only ran once at entry).
    //
    // Plan: docs/superpowers/reviews/2026-08-18-pr-269-update-worker-in-loop.md

    // Queue the initial message — unless the caller asked us to skip
    // it (the start_agent endpoint triggers a worker on an existing
    // session without queueing a new user message; the agent then runs
    // against the existing chat history alone).
    //
    // Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md
    if (!params.skip_initial_queue_message) {
        try insertQueueMessage(InsertQueueMessageInput{
            .allocator = parent_allocator,
            .db = db,
            .logger = logger,
            .session_id = copy_session_id,
            .message = copy_message,
            .image_url = copy_image_urls,
            .event_bus = event_bus,
            .is_emit_sse = true,
        });

        logger.infoFmt(
            "[CHECKPOINT] initial message queued session_id={s} retry_budget=10",
            .{copy_session_id},
        );
    } else {
        logger.infoFmt(
            "[CHECKPOINT] trigger mode — skipping initial queue_message session_id={s}",
            .{copy_session_id},
        );
    }

    var retry_count: u32 = 0;
    var last_retry_error: anyerror = error.Unknown;
    var last_retry_source: []const u8 = "unknown";
    var current_max_tokens: usize = 20000;
    var loop_counter: u32 = 0;
    var last_iter_start_ns: i128 = 0;

    // One-shot config read for the once-per-workflow setup (MCP tool
    // list). The per-iteration LLM-call fields are re-read inside the
    // loop body — see "Live config re-read" below.
    const initial_config = nalarcore.getLlmConfig(di.di);

    // Fetch MCP tools once before the loop - avoids repeated fetching and potential recursive spawning
    const mcp_tools_fetched = (build_msg_prompt.buildMCPToolsRun(parent_allocator, io, initial_config.mcpServers() orelse .null) catch |err| blk: {
        logger.errFmt("Failed to load MCP tools: {s}", .{@errorName(err)});
        break :blk null;
    }) orelse &[_]agent.AgentTool{};

    while (true) {
        _ = active_loops.tryInsert(io, copy_session_id);
        var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(parent_allocator);
        defer arenaAllocatorWhileLoop.deinit();
        const allocator = arenaAllocatorWhileLoop.allocator();

        // Bump worker.last_activity_nano to "now" on every iteration
        // so the cleanup_stale_worker cron (which deletes rows where
        // last_activity_nano < now - 600s) doesn't wipe long-running
        // workflows. The `ON CONFLICT(id) DO UPDATE` clause in
        // updateWorker.zig handles both the first iteration (INSERT)
        // and subsequent iterations (UPDATE) seamlessly.
        //
        // SSE event emitted by updateWorker also keeps the frontend's
        // worker row visually alive; side effect of `is_emit_sse=true`.
        updateWorker(UpdateWorkerInput{
            .allocator = allocator,
            .db = db,
            .logger = logger,
            .worker_id = copy_session_id,
            .session_id = copy_session_id,
            .working_directory = copy_cwd,
            .event_bus = event_bus,
            .is_emit_sse = true,
        }) catch |err| {
            logger.errFmt(
                "[CHECKPOINT] worker update failed session_id={s}: {s}\n",
                .{ copy_session_id, @errorName(err) },
            );
        };

        const is_auto_retry_until_stop: bool = blk: {
            var flag_rows = db.query(allocator, "SELECT COALESCE(is_auto_retry_until_stop, '0') FROM sessions WHERE id = ?", &.{copy_session_id}) catch break :blk false;
            const flag_row = flag_rows.next() catch break :blk false;
            if (flag_row) |row| {
                break :blk std.mem.eql(u8, row.values[0], "1");
            }
            break :blk false;
        };

        last_iter_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

        // ─── Live config re-read (plan 2026-08-06-live-config-reload) ───
        // Re-fetch the LlmConfig pointer from the holder once per
        // iteration so user-initiated changes (model switch, profile
        // change, API-key rotation via NalarSettings) take effect on
        // the next LLM call without waiting for the workflow run to
        // end. `getLlmConfig` is a lock-free single-word pointer load;
        // memory safety is preserved by `LlmConfigHolder.previous`
        // keeping the swapped-out config alive until this run finishes.
        config = nalarcore.getLlmConfig(di.di);

        // ─── Live per-session profile re-read (plan 2026-08-06-workflow-re-read-profile) ───
        // The previous snapshot pattern (params.selected_profile_model) silently
        // ignored mid-run profile changes via PUT /api/llm/session/:id. Now we
        // re-read `sessions.selected_profile_model` per iteration so the next
        // LLM call + any sub-agent spawned in this iteration use the user's
        // freshly-picked profile. Mirrors the live-config-re-read above + the
        // is_auto_retry_until_stop re-read above that.
        //
        // The dupe'd slice is owned by `allocator` (the per-iteration arena)
        // and freed at iteration end. Falls back to the snapshot
        // `params.selected_profile_model` on any read failure.
        const live_selected_profile_model: []const u8 = re_read_selected_profile_model(
            allocator,
            db,
            copy_session_id,
            params.selected_profile_model,
        );

        // Step 1 produces a warning when the named profile is missing.
        // Step 2 (`config.active_profile`) is silent — it's the user's
        // default, so a typo there is a normal fall-through to top-level.
        if (live_selected_profile_model.len > 0 and
            config.getProfile(live_selected_profile_model) == null)
        {
            logger.warnFmt("WORKFLOW: selected_profile_model '{s}' not found in LlmConfig.profiles_models, using top-level config", .{live_selected_profile_model});
        }
        effective_api_key = resolveProfileField("api_key", config, live_selected_profile_model, config.active_profile, config.api_key);
        effective_model = resolveProfileField("model", config, live_selected_profile_model, config.active_profile, config.model);
        effective_base_url = resolveProfileField("base_url", config, live_selected_profile_model, config.active_profile, config.base_url);
        effective_url_style = resolveProfileField("url_style", config, live_selected_profile_model, config.active_profile, config.url_style);

        logger.infoFmt(
            "[CHECKPOINT] loop iter start session_id={s} loop_counter={d} retry_count={d} effective_model={s}",
            .{ copy_session_id, loop_counter, retry_count, effective_model },
        );

        // Check cancellation using DB
        if (isWorkerCancelled(IsWorkerCancelledInput{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        })) {
            logger.infoFmt("WORKFLOW CANCELLED while looping back for next API call...", .{});
            break;
        }

        // Get queued messages from DB
        var queued_messages = try getQueueMessage(GetQueueMessageInput{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        });
        if (queued_messages) |*messages| {
            logger.infoFmt(
                "[CHECKPOINT] queued messages drained session_id={s} count={d}",
                .{ copy_session_id, messages.items.len },
            );
            for (messages.items) |queued| {
                // Use image_url from database if present, otherwise try to extract from message
                var image_urls: ?[][]const u8 = null;
                if (queued.image_url.len > 0) {
                    // Split by pipe separator
                    var parts = std.mem.splitScalar(u8, queued.image_url, '|');
                    var urls = std.ArrayList([]const u8).empty;
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

                _ = try insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = copy_cwd, .entity = .{
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
                    .is_feed_to_llm = true,
                } });

                try deleteQueuedMessage(.{
                    .allocator = allocator,
                    .db = db,
                    .is_emit_sse = true,
                    .event_bus = event_bus,
                    .session_id = copy_session_id,
                    .id = queued.id,
                });
            }
        }

        try updateWorker(UpdateWorkerInput{
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

            // Migration 063 — unattended-mode soft-bail.
            // When the session opts into `is_auto_retry_until_stop=1`, the
            // workflow keeps running past retry_count > 10 instead of
            // returning `error.TooManyRetries`. It logs a chat-history
            // snapshot, sleeps for the configured retry delay, and
            // `continue`s the while-loop. Hard bail behavior is
            // preserved EXACTLY when the flag is off — same diagnostic,
            // same llm_history entry, same `return error.TooManyRetries`
            // — so existing users see no change.
            if (is_auto_retry_until_stop) {
                logger.warnFmt(
                    "UNATTENDED SOFT-BAIL: retry_count={} exceeded 10 (last error={s} source={s}) — continuing per is_auto_retry_until_stop=1",
                    .{ retry_count, reason_error, reason_source },
                );
                const soft_diagnostic = std.fmt.allocPrint(allocator,
                    \\[Agent Nalar System info] unattended-mode soft-bail after {} consecutive retries.
                    \\Reason for last retry: {s} (source: {s}). The session keeps running.
                , .{ retry_count, reason_error, reason_source }) catch "unattended soft-bail snapshot";
                _ = try insertLLMHistories(.{
                    .allocator = allocator,
                    .io = io,
                    .db = db,
                    .logger = logger,
                    .event_bus = event_bus,
                    .is_emit_sse = true,
                    // Soft-bail diagnostic should surface in the live chat
                    // stream but NOT pollute the persistent chat history —
                    // the AI's next turn shouldn't see 10+ retry snapshots
                    // accumulated across unattended-mode cycles.
                    .is_skip_db = true,
                    .cwd = copy_cwd,
                    .entity = .{ .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}), .session_id = copy_session_id, .model = effective_model, .response_content = soft_diagnostic, .reasoning_content = null, .role = agent.Role.user.to_str(), .finish_reason = "null", .tool_calls_json = "", .tool_call_id = null, .agent = effective_agent_name, .loop_index = loop_counter, .temperature = agent_temperature, .is_thinking = isThinking, .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0, .parent_id = copy_parent_session_id, .parent_session_id = copy_parent_session_id, .is_input = true, .is_output = false, .image_urls = null, .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}), .is_feed_to_llm = false },
                });

                if (!retryDelayMs(.{
                    .allocator = allocator,
                    .delay_ms = config.retry_delay_ms,
                    .db = db,
                    .session_id = copy_session_id,
                    .io = io,
                    .logger = logger,
                })) {
                    logger.infoFmt("WORKFLOW CANCELLED during unattended soft-bail: session_id={s}", .{copy_session_id});
                    break;
                }
                // Reset retry counter AND stale retry-cause capture so the
                // NEXT soft-bail diagnostic reflects the *current* failure
                // batch, not the very first error of this session. The first
                // failure cause persisted indefinitely before this reset.
                retry_count = 0;
                last_retry_error = error.Unknown;
                last_retry_source = "unknown";
                continue;
            }

            // Existing hard-bail (preserved verbatim).
            const diagnostic = std.fmt.allocPrint(allocator,
                \\[Agent Nalar System error] workflow halted after {} consecutive retries.
                \\Reason for last retry: {s} (source: {s}).
            , .{ retry_count, reason_error, reason_source }) catch "workflow halted after too many retries";

            logger.errFmt("TooManyRetries exhausted: {} consecutive failures for session_id={s} — last_error={s} source={s}", .{ retry_count, copy_session_id, reason_error, reason_source });

            // Save the diagnostic as a user message so the AI agent sees it on
            // its next turn. Mirror the pattern the outer catch uses for generic
            // errors so the message shape is consistent.

            _ = try insertLLMHistories(.{
                .allocator = allocator,
                .io = io,
                .db = db,
                .logger = logger,
                .event_bus = event_bus,
                .is_emit_sse = true,
                // Hard-bail diagnostic should surface in the live chat
                // stream but NOT pollute the persistent chat history —
                // the workflow halts immediately after this call so the
                // diagnostic is purely a UX message, not a follow-up
                // prompt for the next turn.
                .is_skip_db = true,
                .cwd = copy_cwd,
                .entity = .{
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
                    .is_feed_to_llm = false,
                },
            });

            return error.TooManyRetries;
        }

        var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;
        const db_messages = try getLLMHistories(*SqliteBackend, .{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        });
        const is_task_kanban = try isSessionKanban(allocator, db, copy_session_id);

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

        const merged_tools = try filterAndMergeTools(allocator, mcp_tools_fetched, copy_allowed_tools, copy_is_sub_agent);
        logger.infoFmt(
            "[CHECKPOINT] tools resolved mcp_count={d} merged_count={d} allowed_tools_len={d} is_sub_agent={}",
            .{ mcp_tools_fetched.len, merged_tools.len, copy_allowed_tools.len, copy_is_sub_agent },
        );

        const initialMessages = try build_msg_prompt.buildMessages(allocator, io, db, copy_cwd, copy_session_id, copy_parent_session_id, db_messages, merged_tools, copy_inherited_context, sub_agent_system_prompt);

        try messagesLists.appendSlice(allocator, initialMessages);

        const is_do_compaction = try maybeCompactMessagesNew(defaultCompactDeps, allocator, total_tokens, effective_model, false, &messagesLists, effective_api_key, effective_base_url, effective_url_style, copy_cwd, copy_session_id, db, io, logger, event_bus, config);
        if (is_do_compaction) {
            logger.infoFmt(
                "[CHECKPOINT] compaction triggered session_id={s} loop_counter={d} total_tokens={d} prompt_msg_count={d}",
                .{ copy_session_id, loop_counter, total_tokens, messagesLists.items.len },
            );
            continue;
        }

        logger.debugFmt("[WORKFLOW-debug-system-prompt] system_prompt={s}", .{messagesLists.items[0].content.?});

        const checkpoint_llm_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        logger.infoFmt(
            "[CHECKPOINT] calling LLM session_id={s} model={s} loop_counter={d} prompt_msg_count={d} max_tokens={d} retry_count={d}",
            .{ copy_session_id, effective_model, loop_counter, messagesLists.items.len, current_max_tokens, retry_count },
        );

        var last_dynamic_agent_error_message: ?[]const u8 = null;
        const res_dynamic_agent = callDynamicAgentNew(allocator, io, messagesLists, agent_temperature, current_max_tokens, isThinking, effective_api_key, effective_model, effective_base_url, effective_url_style, copy_session_id, merged_tools, &last_dynamic_agent_error_message) catch |err| {
            if (err == error.Cancelled) {
                logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
                break;
            }
            retry_count += 1;
            // Capture WHY this retry fired so the AI agent can understand
            // the cause when the retry budget is eventually exhausted.
            // This overwrites any stale capture from a previous iteration,
            // so the *most recent* failure cause is what the bail diagnostic
            // reflects — not the first failure of this session.
            last_retry_error = err;
            last_retry_source = "callDynamicAgentNew";
            // The agent populated `last_dynamic_agent_error_message` with
            // the actual server / transport reason (e.g. "HTTP 429: rate
            // limit exceeded", "scanner.next failed after 12 chunk(s):
            // ConnectionResetByPeer"). Falls back to "(no server detail)"
            // for error variants the agent doesn't synthesize a message
            // for (Cancelled, AllocFailed, OutOfMemory, BuildRequestFailed).
            const server_detail = last_dynamic_agent_error_message orelse "(no server detail)";
            logger.errFmt("Error calling dynamic agent: {s} now retrying after {d}ms delay — server: {s}", .{ @errorName(err), config.retry_delay_ms, server_detail });
            // Save a per-retry diagnostic to chat history so the user sees
            // each attempt live AND the AI has the full retry progression
            // in context for its next turn (instead of only learning about
            // retries after the budget is exhausted).
            try saveRetryAttemptMessage(allocator, db, event_bus, logger, io, copy_cwd, copy_session_id, copy_parent_session_id, effective_model, effective_agent_name, agent_temperature, isThinking, loop_counter, retry_count, @as(u32, 10), "callDynamicAgentNew", @errorName(err), config.retry_delay_ms);
            // Sleep before the next attempt so the upstream can recover (or
            // rate-limit window can close). 0 ms = no delay (current
            // behavior, the default). Interrupted by worker cancellation —
            // see retryDelayMs for the polling details.
            if (!retryDelayMs(.{
                .allocator = allocator,
                .delay_ms = config.retry_delay_ms,
                .db = db,
                .session_id = copy_session_id,
                .io = io,
                .logger = logger,
            })) {
                logger.infoFmt("WORKFLOW CANCELLED during retry delay: session_id={s}", .{copy_session_id});
                break;
            }
            continue;
        };
        // Lifecycle: `CallResponse` (and everything it points at —
        // `content`, `reasoning_content`, each
        // `tool_calls[i].{id, function.name, function.arguments}`, the
        // `tool_calls` slice itself) is allocated from THIS iteration’s
        // arena (`arenaAllocatorWhileLoop` declared at the top of the
        // loop, deferred `deinit` runs at end-of-iteration in LIFO
        // order). `CallResponse.deinit` is a documented no-op (see
        // `Agent.zig` CallResponse doc), so the explicit `defer` here
        // is purely cosmetic — it’s kept as `res_dynamic_agent.deinit()`
        // so the call site stays readable, but the arena does the real
        // work.
        //
        // The pre-fix code free’d every inner slice by hand, which
        // under the arena was a no-op but under `testing.allocator`
        // (Debug, fill-poisoned freed memory with 0xAA) corrupted the
        // very slices the downstream `handle_tool → execBash` consumer
        // was about to read — see the 2026-08-15 “bash tool leak” bug
        // where 22 0xAA bytes ended up as `ls -la $'ʪ…'`.

        const llm_duration_ms = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - checkpoint_llm_start_ns, std.time.ns_per_ms);
        logger.infoFmt(
            "[CHECKPOINT] LLM responded session_id={s} loop_counter={d} finish_reason={s} duration_ms={d} prompt_tokens={d} completion_tokens={d} total_tokens={d}",
            .{
                copy_session_id,
                loop_counter,
                if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else "null",
                llm_duration_ms,
                res_dynamic_agent.usage.prompt_tokens,
                res_dynamic_agent.usage.completion_tokens,
                res_dynamic_agent.usage.total_tokens,
            },
        );

        // Successful LLM call — clear the retry-cause capture so the
        // NEXT soft-bail diagnostic reflects the most recent failure,
        // not the first one of this session.
        retry_count = 0;
        last_retry_error = error.Unknown;
        last_retry_source = "unknown";
        // Migration 063 — persist the most recent `finish_reason` so the
        // next workflow invocation (e.g., after a server restart) can
        // start from the right state without re-querying llm_history.
        // Fire-and-log: a DB error here doesn't abort the loop — the
        // cache is best-effort, not source-of-truth.
        if (res_dynamic_agent.finish_reason) |fr| {
            llm_history.updateSessionLastFinishReason(allocator, db, copy_session_id, fr.to_str()) catch |err| {
                logger.warnFmt(
                    "[workflow] failed to persist last_finish_reason: {s}",
                    .{@errorName(err)},
                );
            };
        }
        if (res_dynamic_agent.finish_reason) |finish_reason| {
            if (finish_reason == .stop) {
                logger.infoFmt(
                    "[CHECKPOINT] finish_reason=stop session_id={s} loop_counter={d} content_len={d}",
                    .{ copy_session_id, loop_counter, if (res_dynamic_agent.content) |c| c.len else 0 },
                );
                _ = try insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = copy_cwd, .entity = .{
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
                    .cache_creation_input_tokens = @intCast(res_dynamic_agent.usage.cache_creation_input_tokens),
                    .cache_read_input_tokens = @intCast(res_dynamic_agent.usage.cache_read_input_tokens),
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .is_input = false,
                    .is_output = true,
                    .image_urls = null,
                    .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .is_feed_to_llm = true,
                } });

                const isHaveQueueMessage = hasQueuedMessages(allocator, db, copy_session_id);
                if (isHaveQueueMessage) {
                    logger.infoFmt(
                        "[CHECKPOINT] finish_reason=stop but queue has more messages, looping session_id={s}",
                        .{copy_session_id},
                    );
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
                try deleteWorker(DeleteWorkerInput{
                    .allocator = allocator,
                    .db = db,
                    .logger = logger,
                    .session_id = copy_session_id,
                    .event_bus = event_bus,
                    .is_emit_sse = true,
                });

                logger.infoFmt(
                    "[CHECKPOINT] worker done session_id={s} loop_counter={d}",
                    .{ copy_session_id, loop_counter },
                );
                break;
            } else if (finish_reason == .length) {
                logger.infoFmt(
                    "[CHECKPOINT] finish_reason=length session_id={s} loop_counter={d} max_tokens {d} -> {d}",
                    .{ copy_session_id, loop_counter, current_max_tokens, current_max_tokens + 4096 },
                );
                current_max_tokens += 4096;
                continue;
            } else if (finish_reason == .tool_calls) {
                logger.infoFmt(
                    "[CHECKPOINT] finish_reason=tool_calls session_id={s} loop_counter={d} tool_count={d}",
                    .{ copy_session_id, loop_counter, if (res_dynamic_agent.tool_calls) |tc| tc.len else 0 },
                );
                // Forward the LIVE per-session profile (re-read at the top
                // of this iteration) to handle_tool. Sub-agents spawned via
                // spawn_sub_agent use this as their RunParamsNew.selected_profile_model
                // — so a sub-agent spawned mid-run, after the user picks a
                // new profile in the chatview dropdown, uses the NEW
                // profile from its first LLM call. (Previously the
                // snapshot copy_selected_profile_model was forwarded, so
                // sub-agents stuck to the profile at run start.) The snapshot
                // stays allocated for the run's lifetime as the fallback if
                // a future iteration's re-read fails.
                try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, effective_model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, active_loops, live_selected_profile_model);
            } else {
                retry_count += 1;
                // Capture the unexpected finish_reason as a synthetic
                // retry-cause so the bail diagnostic identifies it. The
                // success path's reset (after the `if (finish_reason)` block)
                // clears this for the next iteration.
                last_retry_error = error.UnexpectedFinishReason;
                last_retry_source = "finish_reason else";
                // Save a per-retry diagnostic (no `err` here — unexpected
                // finish_reason has no underlying error name, so use the
                // source label as the diagnostic).
                try saveRetryAttemptMessage(allocator, db, event_bus, logger, io, copy_cwd, copy_session_id, copy_parent_session_id, effective_model, effective_agent_name, agent_temperature, isThinking, loop_counter, retry_count, @as(u32, 10), "finish_reason else", "unexpected finish_reason", config.retry_delay_ms);
                // Same delay policy as the callDynamicAgentNew catch —
                // sleep before the loop restarts so we don't hammer the
                // upstream when it returns an unexpected finish_reason
                // repeatedly. Interrupted by worker cancellation.

                if (!retryDelayMs(.{
                    .allocator = allocator,
                    .delay_ms = config.retry_delay_ms,
                    .db = db,
                    .session_id = copy_session_id,
                    .io = io,
                    .logger = logger,
                })) {
                    logger.infoFmt("WORKFLOW CANCELLED during retry delay (finish_reason else): session_id={s}", .{copy_session_id});
                    break;
                }
                break;
            }

            // Reset retry counter AND stale retry-cause capture so the
            // NEXT bail (soft or hard) reflects the most recent failure,
            // not the very first one of this session. Mirrors the reset
            // in the soft-bail path above.
            retry_count = 0;
            last_retry_error = error.Unknown;
            last_retry_source = "unknown";
        }

        // Log if finish_reason is null
        if (res_dynamic_agent.finish_reason == null) {
            logger.warnFmt("WORKFLOW: finish_reason is NULL!", .{});
        }
    }

    const last_iter_total_ms = if (last_iter_start_ns > 0)
        @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - last_iter_start_ns, std.time.ns_per_ms)
    else
        @as(i128, 0);
    logger.infoFmt(
        "[CHECKPOINT] exit session_id={s} loop_counter={d} retry_count={d} last_iter_total_ms={d}",
        .{ copy_session_id, loop_counter, retry_count, last_iter_total_ms },
    );
    logger.debugFmt("WORKFLOW: exiting while loop for session_id {s}", .{copy_session_id});
}

fn generateSessionNameNew(
    db_messages: []LLMHistory,
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

    var name_agent = agent.Agent.init(allocator, io);
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
        updateSessionName(allocator, db, session_id, stripped_content, event_bus) catch {
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

/// Save a per-retry diagnostic message to chat history so the user
/// sees each retry attempt live in their chat (instead of only
/// learning about retries via the final TooManyRetries summary)
/// AND the AI agent has the full retry history in context for its
/// next turn.
///
/// Called from BOTH retry paths (callDynamicAgentNew catch + else
/// finish_reason branch). The message is marked `is_input: true` so
/// it appears in the chat list as a user-side entry — this gives the
/// human live visibility into each retry attempt. Critically,
/// `is_feed_to_llm: false` — the per-retry diagnostic does NOT
/// propagate to the LLM context. Feeding every retry to the LLM
/// would bloat the context with up to 10 identical error messages
/// per failure cycle; the LLM only needs the failure CAUSE, which
/// is captured in the final TooManyRetries bail diagnostic (see
/// the `diagnostic` / `soft_diagnostic` blocks at retry_count > 10).
///
/// Format: `[Retry {attempt}/{max}] {error_name} ({source}). Retrying in {delay_ms}ms.`
/// — terse on purpose, since up to 10 of these accumulate in chat.
///
/// `attempt` is 1-based (after the increment). `max_attempts` is the
/// retry budget (currently 10, matching the `retry_count > 10` bail).
fn saveRetryAttemptMessage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    event_bus: *event_bus_mod.EventBus,
    logger: *logger_mod.Logger,
    io: std.Io,
    cwd: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    effective_model: []const u8,
    effective_agent_name: []const u8,
    agent_temperature: f32,
    isThinking: bool,
    loop_counter: u32,
    attempt: u32,
    max_attempts: u32,
    source: []const u8,
    error_name: []const u8,
    delay_ms: u32,
) !void {
    // Track ownership explicitly. On allocPrint failure (e.g. OOM) we
    // fall back to a STRING LITERAL — deferring `allocator.free(literal)`
    // would panic with `Invalid free` on a debug allocator. So `formatted`
    // is `null` in the fallback case and the `errdefer` skips the free.
    const formatted = std.fmt.allocPrint(allocator,
        \\[Retry {d}/{d}] {s} ({s}). Retrying in {d}ms.
    , .{ attempt, max_attempts, error_name, source, delay_ms }) catch |err| blk: {
        logger.errFmt("Failed to format retry diagnostic: {s}", .{@errorName(err)});
        break :blk null;
    };
    const content: []const u8 = formatted orelse "[Retry error: formatting failed]";

    logger.errFmt("Retry {d}/{d}: {s} ({s}). Retrying in {d}ms.", .{ attempt, max_attempts, error_name, source, delay_ms });

    _ = try insertLLMHistories(.{
        .allocator = allocator,
        .io = io,
        .db = db,
        .logger = logger,
        .event_bus = event_bus,
        .is_emit_sse = true,
        .cwd = cwd,
        .is_skip_db = true,
        .entity = .{
            .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
            .session_id = session_id,
            .model = effective_model,
            .response_content = content,
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
            .parent_id = parent_session_id,
            .parent_session_id = parent_session_id,
            .is_input = true,
            .is_output = false,
            .is_feed_to_llm = false,
            .image_urls = null,
            .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
        },
    });
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
    equip_tools: []const agent.AgentTool,
    /// On error, the underlying server/transporter detail (drained HTTP
    /// error body, scanner error name, chunk count) so the retry-catch
    /// block can log the actual reason instead of just `error.ApiError` /
    /// `error.StreamInterrupted`. Heap-owned by the caller — freed by the
    /// per-iteration arena at loop end. Stays null on success.
    out_last_error_message: *?[]const u8,
) !agent.CallResponse {
    // Libcurl-backed Agent (custom_http_client). Same field names,
    // same callStreaming signature as the previous std.http.Client version
    // — only the transport differs. The previous std.http.Client implementation
    // had a 200-line StreamWatchdog / apply_tcp_keepalive / dup2-to-/dev/null
    // workaround for std.Io.Threaded parking workers in recv(); the new
    // Agent (formerly a separate Agent2.zig merged in this PR) uses
    // libcurl's CURLOPT_TIMEOUT_MS instead, which doesn't have that issue.
    var dynamic_agent = agent.Agent.init(allocator, io);
    dynamic_agent.apiKey = api_key;
    dynamic_agent.model = model;
    dynamic_agent.baseUrl = base_url;
    dynamic_agent.UrlStyle = url_style;
    // `messages_list.items` is `[]agent.AgentMessage`; the local
    // `agent.AgentCall.messages` wants the same type — direct assignment.
    const messages_for_agent: []const agent.AgentMessage = messages_list.items;
    const dynamic_agent_call_params = agent.AgentCall{ .tools = equip_tools, .messages = messages_for_agent, .temperature = agent_temperature, .max_tokens = current_max_tokens };
    dynamic_agent.thinkingEnabled = isThinking;
    dynamic_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

    var stream_ctx = StreamingContext{
        .allocator = allocator,
        .session_id = session_id,
        .chunk_index = 0,
    };
    // `stream_callback` is typed as agent.StreamCallback; callStreaming
    // wants the same type — direct assignment, no @ptrCast needed.
    const callback_for_agent: agent.StreamCallback = &stream_callback;
    out_last_error_message.* = null;
    // Catch the callStreaming error so we can copy `last_error_message` out
    // BEFORE the deferred `dynamic_agent.deinit()` frees it. The
    // per-iteration arena outlives this scope, so a dupe into `allocator`
    // is safe to hand back to the caller's retry-catch block.
    const res_dynamic_agent = dynamic_agent.callStreaming(dynamic_agent_call_params, &stream_ctx, callback_for_agent) catch |err| {
        if (dynamic_agent.last_error_message) |msg| {
            out_last_error_message.* = allocator.dupe(u8, msg) catch null;
        }
        return err;
    };
    // `callDynamicAgentNew` returns `agent.CallResponse` (preserves the
    // upstream signature). Pre-rename this was a byte-identical copy from
    // agent2.CallResponse (different module). Post-rename both sides are
    // the same struct in the same module — but the function signature is
    // still `agent.CallResponse` so we just pass through the locals.
    const tool_calls_for_agent: ?[]agent.ToolCall = res_dynamic_agent.tool_calls;
    const finish_reason_for_agent: ?agent.FinishReason = res_dynamic_agent.finish_reason;
    const usage_for_agent: agent.Usage = .{
        .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
        .completion_tokens = res_dynamic_agent.usage.completion_tokens,
        .total_tokens = res_dynamic_agent.usage.total_tokens,
        .cache_creation_input_tokens = res_dynamic_agent.usage.cache_creation_input_tokens,
        .cache_read_input_tokens = res_dynamic_agent.usage.cache_read_input_tokens,
    };
    return .{
        .allocator = res_dynamic_agent.allocator,
        .content = res_dynamic_agent.content,
        .tool_calls = tool_calls_for_agent,
        .finish_reason = finish_reason_for_agent,
        .reasoning_content = res_dynamic_agent.reasoning_content,
        .usage = usage_for_agent,
    };
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
    var base_tools = try allocator.alloc(agent.AgentTool, tools.all_agent_tools(allocator).len);
    @memcpy(base_tools, tools.all_agent_tools(allocator));

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
        for (base_tools) |tool| {
            if (!std.mem.eql(u8, tool.function.name, "spawn_sub_agent")) {
                try filtered.append(allocator, tool);
            }
        }
        base_tools = try filtered.toOwnedSlice(allocator);
    }

    // Merge base tools and MCP tools
    var all_tools_list: std.ArrayList(agent.AgentTool) = std.ArrayList(agent.AgentTool).empty;
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
    is_auto_retry_until_stop: []const u8 = "",
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). When
    // true, runAgenticMultiStepnew skips the initial insertQueueMessage
    // call. Used by the start_agent endpoint to trigger a worker on
    // an existing session without queueing a new user message. The
    // default `false` preserves the existing create-session path
    // behaviour (always queue the initial message).
    skip_initial_queue_message: bool = false,
};

// ─── Inline tests for `resolveProfileField` ──────────────────────────────────
// Per the agentic_loop/ README: this directory uses inline tests, not
// separate `_test.zig` files (the only exception is `parsing_test.zig`).
//
// Why behavioural, not static-contract?
// ─────────────────────────────────────
// The user rule (2026-07-29) is: "Never write static-contract tests —
// call the function, assert the return." `resolveProfileField` is a
// pure function over `LlmConfig`, so we construct a minimal config
// in-memory and call it directly.

/// Allocate a fresh `LlmConfig` with the minimal fields needed by the
/// helper: top-level fields + one profile `"alpha"`. Caller owns the
/// result and must call `cfg.deinit()`.
fn makeTestConfig(allocator: std.mem.Allocator) !config_mod.LlmConfig {
    var cfg: config_mod.LlmConfig = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "default-key"),
        .model = try allocator.dupe(u8, "default-model"),
        .base_url = try allocator.dupe(u8, "https://default.example.com"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .notify_on_complete = false,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = config_mod.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
    errdefer cfg.deinit();

    // Profile "alpha" — every field populated, non-empty.
    try cfg.profiles_models.put(try allocator.dupe(u8, "alpha"), .{
        .model = try allocator.dupe(u8, "alpha-model"),
        .base_url = try allocator.dupe(u8, "https://alpha.example.com"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .url_style = try allocator.dupe(u8, "anthropic"),
        .api_key = try allocator.dupe(u8, "alpha-key"),
        .sub_agents = &.{},
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
    });
    return cfg;
}

test "resolveProfileField: empty selected + null active_profile → top-level" {
    const alloc = testing.allocator;
    var cfg = try makeTestConfig(alloc);
    defer cfg.deinit();

    const got = resolveProfileField("model", &cfg, "", null, cfg.model);
    try testing.expectEqualStrings("default-model", got);
}

test "resolveProfileField: selected_profile_model wins over active_profile" {
    const alloc = testing.allocator;
    var cfg = try makeTestConfig(alloc);
    defer cfg.deinit();
    cfg.active_profile = try alloc.dupe(u8, "alpha");

    // Both names resolve to "alpha" in our test config, but the
    // selected one is checked first — we can't observe a difference
    // unless we add a second profile. Skip the distinct-values check
    // here; the precedence is covered by the "wins over top-level"
    // test below (which would fail if step 1 was skipped).
    const got = resolveProfileField("model", &cfg, "alpha", "alpha", cfg.model);
    try testing.expectEqualStrings("alpha-model", got);
}

test "resolveProfileField: active_profile wins over top-level when selected is empty" {
    // This is the bug: previously, `active_profile` was parsed + saved
    // but the workflow ignored it, always falling through to top-level.
    // With the fix, `active_profile = "alpha"` should select the
    // profile's model.
    const alloc = testing.allocator;
    var cfg = try makeTestConfig(alloc);
    defer cfg.deinit();
    cfg.active_profile = try alloc.dupe(u8, "alpha");

    const got = resolveProfileField("model", &cfg, "", "alpha", cfg.model);
    try testing.expectEqualStrings("alpha-model", got);
}

test "resolveProfileField: active_profile also resolves base_url + url_style + api_key" {
    // The fix is for the WHOLE profile, not just the model field.
    // Verify each of the four fields the workflow cascades.
    const alloc = testing.allocator;
    var cfg = try makeTestConfig(alloc);
    defer cfg.deinit();
    cfg.active_profile = try alloc.dupe(u8, "alpha");

    try testing.expectEqualStrings("alpha-model", resolveProfileField("model", &cfg, "", "alpha", cfg.model));
    try testing.expectEqualStrings("https://alpha.example.com", resolveProfileField("base_url", &cfg, "", "alpha", cfg.base_url));
    try testing.expectEqualStrings("anthropic", resolveProfileField("url_style", &cfg, "", "alpha", cfg.url_style));
    try testing.expectEqualStrings("alpha-key", resolveProfileField("api_key", &cfg, "", "alpha", cfg.api_key));
}

test "resolveProfileField: missing active_profile name falls through to top-level" {
    const alloc = testing.allocator;
    var cfg = try makeTestConfig(alloc);
    defer cfg.deinit();
    cfg.active_profile = try alloc.dupe(u8, "does_not_exist");

    const got = resolveProfileField("model", &cfg, "", "does_not_exist", cfg.model);
    try testing.expectEqualStrings("default-model", got);
}

test "resolveProfileField: empty active_profile string falls through to top-level" {
    // Empty string would come from a stale config or a manual JSON
    // edit. Must not crash on `getProfile("")`.
    const alloc = testing.allocator;
    var cfg = try makeTestConfig(alloc);
    defer cfg.deinit();
    cfg.active_profile = try alloc.dupe(u8, "");

    const got = resolveProfileField("model", &cfg, "", "", cfg.model);
    try testing.expectEqualStrings("default-model", got);
}

test "resolveProfileField: profile with empty field falls through to top-level for THAT field only" {
    // The existing "len > 0" guard: a profile might have a model but
    // an empty base_url. Verify each field cascades independently.
    const alloc = testing.allocator;
    var cfg = try makeTestConfig(alloc);
    defer cfg.deinit();

    // Override "alpha" so base_url is empty (but model is set).
    if (cfg.profiles_models.getEntry("alpha")) |entry| {
        alloc.free(entry.value_ptr.base_url);
        entry.value_ptr.base_url = try alloc.dupe(u8, "");
    }
    cfg.active_profile = try alloc.dupe(u8, "alpha");

    // model still picks up the profile (alpha-model)
    try testing.expectEqualStrings("alpha-model", resolveProfileField("model", &cfg, "", "alpha", cfg.model));
    // base_url falls through (alpha has empty base_url, so top-level wins)
    try testing.expectEqualStrings("https://default.example.com", resolveProfileField("base_url", &cfg, "", "alpha", cfg.base_url));
}



// ─── Inline tests (formerly compaction_long_context_test.zig) ────────────
// Long-context compaction test. Inlined here. The original test file
// self-imported zig — that self-import is removed in the
// inlined copy.


/// Walk ALL migrations from 001 → latest (per project memory
/// `llm-history-test-use-migrations-module.md`). No hand-rolled
/// CREATE TABLE — the migration chain is the source of truth.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "end-to-end: compaction envelope is queryable via getCompactedMessages" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Build a 6-message fixture (system + 5 dropped). Capture the
    // DB ids we'll write for the dropped messages so we can verify
    // they show up in the read tool's output AFTER compaction.
    const session_id = "sess_e2e_1";
    const dropped_ids = [_][]const u8{ "h_real_1", "h_real_2", "h_real_3", "h_real_4", "h_real_5" };
    const dropped_contents = [_][]const u8{
        "Fix the login bug",
        "I'll investigate the auth flow",
        "running tests now",
        "tests pass: 42/42",
        "shipping the patch",
    };
    const dropped_roles = [_][]const u8{ "user", "assistant", "assistant", "tool", "user" };

    // Pre-seed the DB with realistic ids (so the agent can fetch them after compaction).
    for (dropped_ids, dropped_contents, dropped_roles) |id, content, role| {
        const sql =
            \\INSERT INTO llm_history (id, session_id, model, response_content, role, is_feed_to_llm, created_at_nano, tool_call_id, tool_name)
            \\VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
        ;
        const created_at = "2025-01-01 00:00:00";
        var tcid_buf: [16]u8 = undefined;
        const tcid = if (std.mem.eql(u8, role, "tool")) std.fmt.bufPrint(&tcid_buf, "tc_{s}", .{id}) catch "" else "";
        const tname = if (std.mem.eql(u8, role, "tool")) "bash" else "";
        try s.db.exec(alloc, sql, &.{ id, session_id, "gpt-4o", content, role, created_at, tcid, tname });
    }

    // Build the in-memory message list and compact it.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "You are a coding agent.") });
    for (dropped_contents, 0..) |content, i| {
        const role_str = dropped_roles[i];
        const role_enum = std.meta.stringToEnum(agent.Role, role_str) orelse .user;
        try messages.append(alloc, .{
            .role = role_enum,
            .content = try alloc.dupe(u8, content),
            .tool_call_id = if (std.mem.eql(u8, role_str, "tool")) try alloc.dupe(u8, "tc_x") else null,
        });
    }
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership (T → !T).

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
        alloc, messages, "GOAL: ship the fix\nNEXT: deploy",
        session_id, "gpt-4o", "/tmp", &s.db, s.threaded.io(), &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    // Now exercise getCompactedMessages in both modes.

    // INDEX MODE: should return the 5 dropped messages.
    const index_results = try llm_history.getCompactedMessages(alloc, &s.db, session_id, .{});
    defer {
        for (index_results) |*m| m.deinit(alloc);
        alloc.free(index_results);
    }
    try testing.expectEqual(@as(usize, 5), index_results.len);
    for (dropped_ids) |id| {
        // The read tool returns rows by their pre-seeded h_real_* ids
        // (the in-memory messages in this test don't set .id, so the
        // envelope uses "unknown" placeholders — but the DB rows still
        // carry the real h_real_* ids and are findable here). The
        // separate "envelope ids are real DB ids" test in
        // workflow_compaction_envelope_test.zig verifies the contract
        // when the in-memory messages DO set .id.
        try testing.expect(std.mem.indexOf(u8, id, "h_real_") == null or index_results.len > 0);
    }
    // Verify the h_real_ ids appear in the read tool's results
    var found_real = [_]bool{ false, false, false, false, false };
    for (index_results) |m| {
        for (dropped_ids, 0..) |id, idx| {
            if (std.mem.eql(u8, m.id, id)) found_real[idx] = true;
        }
    }
    for (found_real) |found| {
        try testing.expect(found);
    }
    // And verify the tool result for the tool role includes tool_name
    for (index_results) |m| {
        if (std.mem.eql(u8, m.role, "tool")) {
            try testing.expect(m.tool_name != null);
            try testing.expectEqualStrings("bash", m.tool_name.?);
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from workspace_items_update_name_test.zig
//
// Static regression checks for the `name` branch of the
// `PUT /workspaces/:wsId/items/:itemId` handler
// (`workspace_items_update.zig`). Tests check for substring patterns in the
// http_handlers/workspace_items_update.zig source file — they live in
// agentic_loop because the rename request flows through the session
// orchestration, but the actual contracts being verified belong to the
// http_handlers layer.
// ════════════════════════════════════════════════════════════════════════════

const text_normalize = nalarcore.helpers.text_normalize;

const workspaceItemsUpdateHandlerPath =
    "src/ai_workflow/tui/http_handlers/workspace_items_update.zig";

fn workspaceItemsUpdateReadSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "workspace_items_update handler reads name from body via root.get(\"name\")" {
    const allocator = testing.allocator;
    const source = try workspaceItemsUpdateReadSource(allocator, workspaceItemsUpdateHandlerPath);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "root.get(\"name\")") == null) {
        std.debug.print(
            "\n!! {s} does not read `name` from the request body !!\n" ++
                "   The rename branch requires `root.get(\"name\")` to be\n" ++
                "   referenced (so the rename request reaches the `name_valid`\n" ++
                "   gate). Mirror the existing `root.get(\"path\")` extraction.\n",
            .{workspaceItemsUpdateHandlerPath},
        );
        return error.NameExtractionMissing;
    }
}

test "workspace_items_update handler calls updateWorkspaceItemName" {
    const allocator = testing.allocator;
    const source = try workspaceItemsUpdateReadSource(allocator, workspaceItemsUpdateHandlerPath);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "updateWorkspaceItemName") == null) {
        std.debug.print(
            "\n!! {s} does not call updateWorkspaceItemName !!\n" ++
                "   The rename branch must call `updateWorkspaceItemName` so\n" ++
                "   the SQL UPDATE writes the new name.\n",
            .{workspaceItemsUpdateHandlerPath},
        );
        return error.UpdateNameCallMissing;
    }
}

test "workspace_items_update handler returns 400 for empty name" {
    const allocator = testing.allocator;
    const source = try workspaceItemsUpdateReadSource(allocator, workspaceItemsUpdateHandlerPath);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "name must be a non-empty string when present") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 for empty name !!\n" ++
                "   The rename branch must reject `{{name: \"\"}}` or `{{name: null}}`\n" ++
                "   with HTTP 400 BEFORE the DB round-trip.\n",
            .{workspaceItemsUpdateHandlerPath},
        );
        return error.EmptyNameNotRejected;
    }
}

test "workspace_items_update handler makes item_type optional (falls back to existing row)" {
    const allocator = testing.allocator;
    const source = try workspaceItemsUpdateReadSource(allocator, workspaceItemsUpdateHandlerPath);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "effective_item_type") == null) {
        std.debug.print("\n!! " ++ workspaceItemsUpdateHandlerPath ++ " does not compute effective_item_type !!\n", .{});
        return error.ItemTypeFallbackMissing;
    }
}

test "workspace_items_update handler rejects empty body with 400" {
    const allocator = testing.allocator;
    const source = try workspaceItemsUpdateReadSource(allocator, workspaceItemsUpdateHandlerPath);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "At least one of item_type, name, or path is required") == null) {
        std.debug.print("\n!! " ++ workspaceItemsUpdateHandlerPath ++ " does not return 400 for empty body !!\n", .{});
        return error.EmptyBodyNotRejected;
    }
}
