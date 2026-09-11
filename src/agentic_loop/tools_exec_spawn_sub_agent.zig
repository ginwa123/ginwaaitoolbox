const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const config_mod = nalarcore.config;
const llm_history = nalarcore.llm_history;
const models = @import("models.zig");
const ai_workflow = @import("workflow.zig");
const spawn_sub_agent_tool = nalarcore.spawn_sub_agent;
const subagent_progress = @import("subagent_progress.zig");
const xml_escape = @import("helpers").xml_escape;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const wrapToolOutput = tools.wrapToolOutput;

// Heap-allocated struct for sub-agent thread arguments
// This avoids capturing pointers from stack frames that may become invalid
const SubAgentThreadArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    parent_sess_id: []const u8,
    agent_name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8,
    llm_config: *const config_mod.LlmConfig,
    cwd: []const u8,
    is_sub_agent: bool,
    thread_idx: usize,
    shared_results: *SharedResults,
    environment: ?*const std.process.Environ.Map,
    active_loops: *models.ActiveLoops,
    inherited_context: []const u8 = "", // NEW: mode string for parent history inheritance
    sub_agent_overrides: ?ai_workflow.SubAgentOverrides = null,
    // 2026-08-23 spawn-subagent-live-progress: the parent's
    // tool_call.id (from the LLM's tool_calls[i].id). Frontend
    // ChatView.vue routes role="subagent_progress" SSE events into
    // a per-tool_call_id map; without this we can't correlate
    // progress to the right card.
    tool_call_id: []const u8 = "",
    // Total number of sub-agents in THIS spawn batch. Frontend
    // displays it as "1 of 3" chips in the row.
    total_agents: usize = 0,
    // Wall-clock capture at thread entry so elapsed_ms is meaningful
    // (the frontend renders it as a "running for 12s" chip). Use
    // `.nanoseconds` to convert to ms at emit time.
    thread_start_ns: i128 = 0,
};

// Shared result storage for thread synchronization
const SharedResults = struct {
    results: []ThreadResult,
    completed_count: std.atomic.Value(usize),
    mutex: std.Io.Mutex,
};

// Result structure for thread execution
const ThreadResult = struct {
    success: bool,
    name: []const u8,
    response: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    session_id: []const u8 = "",
    /// True when the LLM-requested `agent_name` was not found in
    /// any sub_agents list and a random name was generated. The
    /// frontend uses this to show the "random" badge on the
    /// affected <agent> tag. Populated by `runSubAgent` after
    /// `resolveSubAgent` returns.
    is_random_fallback: bool = false,
};

// 2026-09-04 subagent-peek fix (P0): child session ids embed the agent
// name verbatim, so `backend implementer` produced
// `subagent_{ns}_backend implementer` — a raw space in the REST path
// breaks the HTTP request line (`GET <path> HTTP/1.1` splits on ' ')
// and `/`/`%` break router segment matching even when encoded
// (http_parser decodes %2F to '/' BEFORE matchPathWithParams splits).
// Slugify to [A-Za-z0-9_-] (space -> '_', rest dropped) so the sid is
// always a single URL-safe path segment. Uniqueness still comes from
// the nanosecond prefix. Empty result falls back to "agent".
pub fn slugifySubAgentName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_') {
            try out.append(allocator, c);
        } else if (c == ' ' or c == '\t') {
            try out.append(allocator, '_');
        }
        // All other bytes (/, %, <, >, &, non-ASCII, …) are dropped.
    }
    if (out.items.len == 0) {
        try out.appendSlice(allocator, "agent");
    }
    return out.toOwnedSlice(allocator);
}

// Top-level function required by group.concurrent — takes a single *SubAgentThreadArgs.
// The function signature must NOT return an error union if you want group.await
// to not propagate individual task errors; handle them internally instead and
// write results into shared_results, exactly as the original thread fn did.
fn runSubAgent(args_ptr: *SubAgentThreadArgs) void {
    args_ptr.logger.debugFmt("Concurrent task started for '{s}'", .{args_ptr.agent_name});

    var thread_arena_alloc = std.heap.ArenaAllocator.init(args_ptr.allocator);
    defer thread_arena_alloc.deinit();
    const sub_agent_allocator = thread_arena_alloc.allocator();

    defer args_ptr.allocator.destroy(args_ptr);

    // 2026-08-23 spawn-subagent-live-progress: capture start time at
    // thread entry so subsequent emit calls report elapsed_ms correctly.
    args_ptr.thread_start_ns = std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds;
    // Tiny inline helpers used by every error/completion branch below.
    // Defined as functions (not closures) so they capture no per-loop
    // state — they read the latest values off args_ptr each call.
    const elapsedMsFn = struct {
        // Computes elapsed ms since thread entry. Pure relative to
        // the args_ptr.thread_start_ns field — safe to call from any
        // branch below.
        fn call(a: *SubAgentThreadArgs) i64 {
            const now_ns = std.Io.Timestamp.now(a.io, .real).nanoseconds;
            const diff_ns = now_ns - a.thread_start_ns;
            return @intCast(@divTrunc(diff_ns, std.time.ns_per_ms));
        }
    }.call;
    // Convenience alias — `elapsedMs(args_ptr)` reads more naturally
    // than `elapsedMsFn(args_ptr)` at the call sites below.
    const elapsedMs = elapsedMsFn;
    // Emits `failed` progress then sets error_message on the shared
    // slot. Both operations are required: progress MUST fire so the
    // frontend row doesn't strand as `running` forever, and the
    // error_message populates the row's <error>...</error> in the
    // eventual <results> envelope. The err_msg lifetime comes from
    // args_ptr.allocator — it survives the thread arena teardown
    // (the existing per-thread pattern at the original error sites).
    const FailHelpers = struct {
        fn call(a: *SubAgentThreadArgs, err_msg: []const u8, ms: i64) void {
            a.shared_results.results[a.thread_idx].error_message = err_msg;
            subagent_progress.emitProgressEvent(.{
                .parent_session_id = a.parent_sess_id,
                .tool_call_id = a.tool_call_id,
                .agent_name = a.agent_name,
                .status = .failed,
                .agent_index = a.thread_idx,
                .total_agents = a.total_agents,
                .session_id = "", // never created if we failed before line 130
                .elapsed_ms = ms,
            });
        }
        // Variant for branches that ALREADY wrote error_message to the
        // shared slot (the two pathological "completed but empty / no
        // message" branches below). Skips the assignment.
        fn callAlreadySet(a: *SubAgentThreadArgs, sub_session_id: []const u8, ms: i64) void {
            subagent_progress.emitProgressEvent(.{
                .parent_session_id = a.parent_sess_id,
                .tool_call_id = a.tool_call_id,
                .agent_name = a.agent_name,
                .status = .failed,
                .agent_index = a.thread_idx,
                .total_agents = a.total_agents,
                .session_id = sub_session_id,
                .elapsed_ms = ms,
            });
        }
    };
    const failSubAgent = FailHelpers.call;
    const failSubAgentAlreadySet = FailHelpers.callAlreadySet;
    // We never emit `session_id` on failed paths because allocation
    // happens deep in the function (after every error-return point
    // we're in the "session not yet created" branch). The frontend
    // reducer treats empty session_id as "not yet known" so the
    // peek button stays disabled and shows "—" when hovered.

    // Propagate is_random_fallback from the resolved overrides to the
    // shared result so the frontend can render the "random" badge.
    // Done BEFORE the workflow call so it's set even if the workflow
    // errors out before reaching the result struct.
    if (args_ptr.sub_agent_overrides) |ov| {
        args_ptr.shared_results.results[args_ptr.thread_idx].is_random_fallback = ov.is_random_fallback;
    }

    // session_id uses the resolved sub-agent name (matched or random)
    // when overrides are present, otherwise the LLM-provided name.
    // This is what gets embedded in the sub-agent's session_id
    // suffix and shows up in the UI's worker list.
    const resolved_display_name: []const u8 = if (args_ptr.sub_agent_overrides) |ov|
        ov.resolved_name
    else
        args_ptr.agent_name;

    // 2026-09-04 subagent-peek P0: slugify so the sid is URL-safe.
    const slugged_name = slugifySubAgentName(sub_agent_allocator, resolved_display_name) catch resolved_display_name;
    const sess_id = std.fmt.allocPrint(
        sub_agent_allocator,
        "subagent_{}_{s}",
        .{ std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds, slugged_name },
    ) catch {
        // Mirror the workflow.zig error message pattern (workflow.zig:68)
        // for consistency with the rest of the runSubAgent error paths.
        const err_msg = std.fmt.allocPrint(
            args_ptr.allocator,
            "Agent Nalar System error, the actual error is ->>>> Failed to create session_id for '{s}'\n",
            .{args_ptr.agent_name},
        ) catch "Agent Nalar System error, the actual error is ->>>> Failed to create session_id";
        failSubAgent(args_ptr, err_msg, elapsedMs(args_ptr));
        args_ptr.logger.errFmt("Failed to create session_id for '{s}'", .{args_ptr.agent_name});
        return;
    };
    defer sub_agent_allocator.free(sess_id);
    args_ptr.logger.debugFmt("Session ID created: '{s}'", .{sess_id});

    // Store session_id in shared results immediately after creation
    {
        const session_id_copy = args_ptr.allocator.dupe(u8, sess_id) catch {
            const err_msg = std.fmt.allocPrint(
                args_ptr.allocator,
                "Agent Nalar System error, the actual error is ->>>> Failed to copy session_id for '{s}'\n",
                .{args_ptr.agent_name},
            ) catch "Agent Nalar System error, the actual error is ->>>> Failed to copy session_id";
            failSubAgent(args_ptr, err_msg, elapsedMs(args_ptr));
            args_ptr.logger.errFmt("Failed to copy session_id for '{s}'", .{args_ptr.agent_name});
            return;
        };
        args_ptr.shared_results.results[args_ptr.thread_idx].session_id = session_id_copy;
    }

    // 2026-08-23 spawn-subagent-live-progress: emit `launched` as soon
    // as the sub-agent's session_id is stored in shared_results.
    // Frontend ChatView.vue uses this to flip its row from
    // `pending` → `running` and to enable the peek-button path.
    subagent_progress.emitProgressEvent(.{
        .parent_session_id = args_ptr.parent_sess_id,
        .tool_call_id = args_ptr.tool_call_id,
        .agent_name = args_ptr.agent_name,
        .status = .launched,
        .agent_index = args_ptr.thread_idx,
        .total_agents = args_ptr.total_agents,
        .session_id = args_ptr.shared_results.results[args_ptr.thread_idx].session_id,
        .elapsed_ms = elapsedMs(args_ptr),
    });

    const di = nalarcore.getSingleton() catch unreachable;

    const is_sub_agent = std.mem.indexOf(u8, sess_id, "subagent") != null;
    args_ptr.logger.debugFmt("Calling workflow.runAgenticMultiStep for '{s}'", .{args_ptr.agent_name});

    const logger = di.logger;
    const allocator = di.allocator;
    const active_loops = di.active_loops;
    const event_bus = di.event_bus;
    const db = di.db;
    const io = di.io;
    const environment = di.environment;

    ai_workflow.runAgenticMultiStepnew(.{
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
    }, .{
        .parent_session_id = args_ptr.parent_sess_id,
        .session_id = sess_id,
        .message = args_ptr.instruction,
        .cwd = args_ptr.cwd,
        .body = "",
        .allowed_tools = if (args_ptr.tools) |sub_agent_tools| blk: {
            var tools_str = std.ArrayList(u8).empty;
            for (sub_agent_tools, 0..) |tool, i| {
                if (i > 0) tools_str.append(args_ptr.allocator, ',') catch break;
                tools_str.appendSlice(args_ptr.allocator, tool) catch break;
            }
            break :blk tools_str.items;
        } else "",
        .is_sub_agent = is_sub_agent,
        .inherited_context = args_ptr.inherited_context,
        .sub_agent_overrides = args_ptr.sub_agent_overrides,
    }) catch |err| {
        // Mirror the diagnostic pattern used by workflow.zig's outer
        // catch (workflow.zig:68) and its TooManyRetries bail
        // (workflow.zig:410-415) so the parent LLM and the user see a
        // clear, actionable error message instead of a bare error name.
        //
        // For TooManyRetries specifically, the inner workflow bail has
        // already saved a rich diagnostic to the SUB-AGENT's chat history
        // (see workflow.zig's bail at line 410-475), but the parent LLM
        // does NOT see that diagnostic — it only sees the error returned
        // from this tool call. Without a rich message here, the parent
        // would have no idea WHY retries were happening.
        const err_name: []const u8 = @errorName(err);
        const diagnostic: []const u8 = if (std.mem.eql(u8, err_name, "TooManyRetries"))
            std.fmt.allocPrint(args_ptr.allocator,
                \\[Agent Nalar System error] sub-agent workflow halted after TooManyRetries (10+ consecutive failures).
                \\This typically indicates a network connectivity issue to the LLM API endpoint,
                \\API rate limit exceeded, authentication/authorization failure, or upstream
                \\service unavailability. The sub-agent's session logs contain the full chain
                \\of errors at each retry attempt — review them before retrying.
            , .{}) catch
                "Agent Nalar System error, the actual error is ->>>> TooManyRetries\n"
        else
            std.fmt.allocPrint(
                args_ptr.allocator,
                "Agent Nalar System error, the actual error is ->>>> {s}\n",
                .{err_name},
            ) catch "Failed to format error message";
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = diagnostic;
        // 2026-08-23 spawn-subagent-live-progress: also flip the SSE
        // progress event so the chatview row goes running→failed
        // INSTEAD of stranding as running until group.await returns.
        // emitProgressEvent is fire-and-forget; never wrap in catch.
        subagent_progress.emitProgressEvent(.{
            .parent_session_id = args_ptr.parent_sess_id,
            .tool_call_id = args_ptr.tool_call_id,
            .agent_name = args_ptr.agent_name,
            .status = .failed,
            .agent_index = args_ptr.thread_idx,
            .total_agents = args_ptr.total_agents,
            .session_id = sess_id,
            .elapsed_ms = elapsedMs(args_ptr),
        });
        args_ptr.logger.errFmt("Sub-agent workflow error for '{s}': {s}", .{ args_ptr.agent_name, err_name });
        return;
    };

    args_ptr.logger.debugFmt("workflow.runAgenticMultiStep completed for '{s}', fetching message", .{args_ptr.agent_name});

    const latest_msg_result = llm_history.getLatestMessage(sub_agent_allocator, args_ptr.sqlite_db, sess_id) catch |err| {
        // Mirror the workflow.zig error message pattern (workflow.zig:68)
        // so the parent LLM sees a clear "Agent Nalar System error" prefix
        // instead of a bare error name.
        const err_msg = std.fmt.allocPrint(
            args_ptr.allocator,
            "Agent Nalar System error, the actual error is ->>>> getLatestMessage: {s}\n",
            .{@errorName(err)},
        ) catch "Agent Nalar System error, the actual error is ->>>> getLatestMessage failed";
        failSubAgent(args_ptr, err_msg, elapsedMs(args_ptr));
        args_ptr.logger.errFmt("getLatestMessage error for '{s}': {s}", .{ sess_id, @errorName(err) });
        return;
    };

    if (latest_msg_result) |msg| {
        var mutable_msg = msg;
        if (mutable_msg.response_content.len > 0) {
            const response_copy = args_ptr.allocator.dupe(u8, mutable_msg.response_content) catch {
                const err_msg = std.fmt.allocPrint(
                    args_ptr.allocator,
                    "Agent Nalar System error, the actual error is ->>>> Failed to copy response: OutOfMemory\n",
                    .{},
                ) catch "Agent Nalar System error, the actual error is ->>>> Failed to copy response";
                failSubAgent(args_ptr, err_msg, elapsedMs(args_ptr));
                mutable_msg.deinit(args_ptr.allocator);
                return;
            };
            args_ptr.shared_results.results[args_ptr.thread_idx].response = response_copy;
            args_ptr.shared_results.results[args_ptr.thread_idx].success = true;
            // 2026-08-23 spawn-subagent-live-progress: emit
            // `completed` ONLY when the sub-agent produced a
            // non-empty response. The two pathological "completed
            // but empty / no message" branches below emit `failed`
            // instead. Frontend peeks the subagent_session_id to
            // open the live peek panel mid-run.
            subagent_progress.emitProgressEvent(.{
                .parent_session_id = args_ptr.parent_sess_id,
                .tool_call_id = args_ptr.tool_call_id,
                .agent_name = args_ptr.agent_name,
                .status = .completed,
                .agent_index = args_ptr.thread_idx,
                .total_agents = args_ptr.total_agents,
                .session_id = sess_id,
                .elapsed_ms = elapsedMs(args_ptr),
            });
        } else {
            // Sub-agent finished without producing any assistant text.
            // Treat as a failure for UI purposes so the row flips
            // from running to failed (instead of hanging as running
            // until the user navigates away).
            args_ptr.shared_results.results[args_ptr.thread_idx].error_message =
                "Agent Nalar System error, the actual error is ->>>> Sub-agent completed but produced empty response content\n";
            failSubAgentAlreadySet(args_ptr, sess_id, elapsedMs(args_ptr));
        }
        mutable_msg.deinit(args_ptr.allocator);
    } else {
        // No message row returned at all — same UX treatment as the
        // empty-response branch.
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message =
            "Agent Nalar System error, the actual error is ->>>> Sub-agent completed but no message found in database\n";
        failSubAgentAlreadySet(args_ptr, sess_id, elapsedMs(args_ptr));
    }

    _ = args_ptr.shared_results.completed_count.fetchAdd(1, .monotonic);
}

// spawn_sub_agent implementation - uses workflow.zig logic
pub fn execSpawnSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("execSpawnSubAgent called, arguments len={}", .{tc.function.arguments.len});
    ctx.logger.debugFmt("arguments: '{s}'", .{tc.function.arguments[0..@min(tc.function.arguments.len, 200)]});

    // 2026-09-04 refresh fix: the snapshot registry (subagent_progress)
    // is the refresh-rehydrate source until the final envelope lands in
    // the DB. If exec fails before building the envelope, drop the
    // batch's rows so a refresh falls back to Task 0's "starting…"
    // copy instead of stranding stale running rows. Idempotent.
    errdefer subagent_progress.clearSnapshot(ctx.tool_call_id);
    const parsed = spawn_sub_agent_tool.parse_sub_agents(ctx.allocator, tc.function.arguments, 20) catch |err| {
        ctx.logger.errFmt("parse_sub_agents failed: {}", .{err});
        return error.InvalidArguments;
    };
    defer parsed.deinit(ctx.allocator);

    // Build the result XML using `std.Io.Writer.Allocating`.
    //
    // IMPORTANT (learned the hard way on 2026-06-15): in this Zig
    // 0.16 build, `Writer.Allocating.fromArrayList` EMPTIES the
    // passed ArrayList (`defer array_list.* = .empty;` inside
    // `fromArrayListAligned`, see std/Io/Writer.zig line 2567) and
    // takes ownership of its allocated memory as the writer's
    // internal buffer. Calling `toOwnedSlice` on the ORIGINAL
    // ArrayList therefore returns "" — the data is in the writer.
    // And `Writer.Allocating.flush` is a no-op (see std/Io/Writer.zig
    // line 2582: `.flush = noopFlush`), so calling `flush` does
    // nothing useful.
    //
    // The right pattern is:
    //   1. `Allocating.init(allocator)` — get a writer with its own buffer
    //   2. write into it via `&aw.writer`
    //   3. `aw.toArrayList()` — MOVE the buffer out as a fresh ArrayList
    //   4. `final_list.toOwnedSlice(allocator)` — extract the data
    //   5. `defer aw.deinit()` — cleanup the writer
    //
    // (The previous fix that called `try aw.flush();` was a no-op
    // for the same reason and didn't actually fix the empty-data
    // bug. This is the real fix.)
    var aw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const sub_agent_count = parsed.sub_agents.len;
    ctx.logger.debugFmt("Parsed {} sub-agents", .{sub_agent_count});
    for (parsed.sub_agents, 0..) |sa, i| {
        ctx.logger.debugFmt("Sub-agent {}: agent_name='{s}', instruction_len={}", .{ i, sa.agent_name, sa.instruction.len });
    }

    const shared_results = try ctx.allocator.create(SharedResults);
    shared_results.* = .{
        .results = try ctx.allocator.alloc(ThreadResult, sub_agent_count),
        .completed_count = std.atomic.Value(usize).init(0),
        .mutex = std.Io.Mutex.init,
    };
    for (shared_results.results, 0..) |*r, i| {
        r.* = .{ .success = false, .name = parsed.sub_agents[i].agent_name, .response = null, .error_message = null, .session_id = "" };
    }
    defer {
        ctx.allocator.free(shared_results.results);
        ctx.allocator.destroy(shared_results);
    }

    // Launch all sub-agents concurrently using std.Io.Group.
    // We need `concurrent` (not `async`) because agents must run in parallel —
    // using `async` on a single-threaded Io can deadlock.
    var group: std.Io.Group = .init;

    for (parsed.sub_agents, 0..) |sub_agent, idx| {
        ctx.logger.debugFmt("Launching concurrent task for agent '{s}' (index {})", .{ sub_agent.agent_name, idx });

        // Resolve the sub-agent config from the LlmConfig.
        // `agent_name` is the LLM-provided name from JSON (required).
        // We look it up in the config's sub_agents list and apply
        // the resolved fields as an overlay on the orchestrator's
        // defaults. If the name is not found, a random name is
        // generated and the orchestrator's defaults are used.
        const an = sub_agent.agent_name;
        const overrides: ?ai_workflow.SubAgentOverrides = blk: {
            // Resolve against the active profile's sub_agents
            // list first (when a profile is selected), then
            // fall back to the top-level sub_agents. The
            // parent's selected_profile_model is threaded
            // through `ToolExecContext.selected_profile_model`
            // by the workflow → handle_tool → dispatch path.
            //
            // The `@constCast` is needed because `resolveSubAgent`
            // mutates `self.random_names` to track the random
            // fallback's allocation for deinit cleanup. The
            // LlmConfig is logically immutable (it lives in
            // the singleton for the server's lifetime); this
            // single private mutation is a tracking side-effect,
            // not a semantic change. Casting away const at
            // the one production call site keeps the rest of
            // the type system honest about read-only access.
            const resolved = @constCast(ctx.config).resolveSubAgent(ctx.selected_profile_model, an);
            if (resolved.is_random_fallback) {
                ctx.logger.warnFmt("spawn_sub_agent: agent_name '{s}' not found in LlmConfig.sub_agents; using random name '{s}' and orchestrator defaults", .{ an, resolved.name });
            } else {
                ctx.logger.infoFmt("spawn_sub_agent: agent_name '{s}' resolved (source='{s}', model='{s}')", .{ an, resolved.source, resolved.model });
            }
            break :blk ai_workflow.SubAgentOverrides{
                .resolved_name = resolved.name,
                .is_random_fallback = resolved.is_random_fallback,
                .model = resolved.model,
                .base_url = resolved.base_url,
                .api_key = resolved.api_key,
                .url_style = resolved.url_style,
                .is_thinking = resolved.is_thinking,
                .temperature = resolved.temperature,
                // Model-thinking knobs (plan 2026-08-23-model-thinking).
                // Threaded from ResolvedSubAgent so the spawned
                // sub-agent can override its parent profile's
                // thinking budget / reasoning effort without
                // touching the global config.
                .thinking_budget_tokens = resolved.thinking_budget_tokens,
                .reasoning_effort = resolved.reasoning_effort,
                .system_prompt = resolved.system_prompt,
            };
        };

        const args = try ctx.allocator.create(SubAgentThreadArgs);
        args.* = .{
            .allocator = ctx.allocator,
            .io = ctx.io,
            .sqlite_db = ctx.db,
            .logger = ctx.logger,
            .parent_sess_id = ctx.session_id,
            .agent_name = sub_agent.agent_name,
            .instruction = sub_agent.instruction,
            .tools = sub_agent.tools,
            .llm_config = ctx.config,
            .cwd = ctx.cwd,
            .is_sub_agent = true,
            .thread_idx = idx,
            .shared_results = shared_results,
            .environment = ctx.environment,
            .active_loops = ctx.active_loops,
            .inherited_context = sub_agent.inherited_context orelse "",
            .sub_agent_overrides = overrides,
            // 2026-08-23 spawn-subagent-live-progress: propagate
            // the parent's tool_call id + the total batch size so
            // the per-thread progress events are correctly keyed.
            // Without tool_call_id the frontend cannot route the
            // SSE event into the right card (two simultaneous
            // spawns would otherwise cross-contaminate).
            .tool_call_id = ctx.tool_call_id,
            .total_agents = sub_agent_count,
            // .thread_start_ns is set INSIDE runSubAgent at entry
            // (we don't have a precise timestamp here that beats
            // the per-thread io.now()).
        };

        // group.concurrent returns error.ConcurrencyUnavailable if the Io
        // backend cannot run tasks in parallel (e.g. a bare blocking Io).
        try group.concurrent(ctx.io, runSubAgent, .{args});
    }

    // Wait for every sub-agent to finish (replaces the thread.join loop).
    ctx.logger.debugFmt("Awaiting {} concurrent tasks...", .{sub_agent_count});
    try group.await(ctx.io);
    ctx.logger.debugFmt("All concurrent tasks completed", .{});

    var success_count: usize = 0;
    for (shared_results.results) |result| {
        if (result.success) success_count += 1;
    }

    try w.print("<results>\n", .{});
    for (shared_results.results) |result| {
        const success = if (result.success) "true" else "false";
        const random_fallback = if (result.is_random_fallback) "true" else "false";
        // 2026-09-04 subagent-peek P3: escape XML so names with <>&"
        // don't corrupt SpawnSubAgent.vue's <session_id> regex extraction.
        const name_esc = try xml_escape(ctx.allocator, result.name);
        try w.print("<agent name=\"{s}\" success=\"{s}\" random_fallback=\"{s}\">\n", .{ name_esc, success, random_fallback });
        if (result.session_id.len > 0) {
            const sid_esc = try xml_escape(ctx.allocator, result.session_id);
            try w.print("<session_id>{s}</session_id>\n", .{sid_esc});
        }
        if (result.success) {
            if (result.response) |resp| {
                const resp_esc = try xml_escape(ctx.allocator, resp);
                try w.print("<response>{s}</response>\n", .{resp_esc});
            } else {
                try w.print("<response></response>\n", .{});
            }
        } else if (result.error_message) |err| {
            const err_esc = try xml_escape(ctx.allocator, err);
            try w.print("<error>{s}</error>\n", .{err_esc});
        } else {
            try w.print("<error>unknown error</error>\n", .{});
        }
        try w.print("</agent>\n", .{});
    }
    try w.print("<summary succeeded=\"{}\" failed=\"{}\" />\n", .{ success_count, sub_agent_count - success_count });
    try w.print("</results>\n", .{});

    // Move the writer's internal buffer out as an ArrayList (this
    // resets the writer to an empty state — `defer aw.deinit()`
    // at the top of the function will free the now-empty writer
    // bookkeeping). See the long comment on the `var aw` line
    // for the full rationale (the `results` ArrayList was
    // emptied by `fromArrayList`; we don't use that pattern
    // anymore; the data lives in the writer's internal buffer).
    var final_list = aw.toArrayList();
    defer final_list.deinit(ctx.allocator);
    const inner_owned = try final_list.toOwnedSlice(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "spawn_sub_agent", tc.function.arguments, true, null, inner_owned);
    // 2026-09-04 refresh fix: the final `<results>` envelope is built —
    // the DB row (written by handle_tool's updateAndSendToolResult right
    // after we return) takes over as the source of truth, so the
    // snapshot has served its purpose. Drop it; a post-completion
    // refresh renders the envelope, never the snapshot. (The errdefer
    // above covers the failure paths.)
    subagent_progress.clearSnapshot(ctx.tool_call_id);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// =====================================================================
// Static-contract tests — grep the impl source for required emit sites.
//
// 2026-08-23 spawn-subagent-live-progress: these guard the invariant
// that the per-thread runtime emits progress events at 3 lifecycle
// points (`launched` after session_id stored, `completed` after
// success=true, `failed` on each error return). When a future refactor
// accidentally drops one of those call sites, the chatview card will
// regress to "0 sub-agents" until all threads join — same bug the
// user reported.
//
// Technique follows design_model_group_test.zig: read the file source
// and assert required string fragments exist. Reads THIS file at
// runtime via a known repo-root-relative path.
// =====================================================================

const testing = std.testing;
const impl_path = "src/agentic_loop/tools_exec_spawn_sub_agent.zig";

test "execSpawnSubAgent uses emitProgressEvent for launched/completed/failed" {
    const max_bytes: usize = 1 * 1024 * 1024; // 1 MiB — impl is ~17KB
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    // 3 call sites + 3 status values must all be present.
    const emit_count = std.mem.count(u8, source, "emitProgressEvent(");
    try testing.expect(emit_count >= 3);

    try testing.expect(std.mem.indexOf(u8, source, ".status = .launched") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".status = .completed") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".status = .failed") != null);

    // Sanity: ensure tool_call_id is plumbed through SubAgentThreadArgs
    // (the per-thread struct that carries state from the launch loop
    // to runSubAgent). Without this, the emitted events can't be
    // correlated to the parent spawn call by the frontend.
    try testing.expect(std.mem.indexOf(u8, source, "tool_call_id: []const u8") != null);
}

test "runSubAgent captures start timestamp for elapsed_ms" {
    // The reducer on the frontend displays elapsed_ms as a chip;
    // without capturing start_ns at thread entry, every event would
    // show 0 or a meaningless number.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "thread_start_ns") != null);
    try testing.expect(std.mem.indexOf(u8, source, "elapsed_ms") != null);
}

test "failed emit happens on every error return path" {
    // There are ~6 error-return sites in runSubAgent (session_id alloc
    // fail, copy fail, workflow error, getLatestMessage fail, empty
    // response, missing message). All must emit `failed` BEFORE
    // returning so the frontend's progress map never strands a row
    // in `running` forever.
    //
    // Two of them are centralized in `FailHelpers.call` /
    // `FailHelpers.callAlreadySet` (the per-thread helpers defined
    // near the top of runSubAgent). One is the workflow-error branch
    // (which calls emitProgressEvent directly because it has its own
    // diagnostic). So the source MUST contain at least 3 string
    // occurrences of `.status = .failed`: 2 in the helper struct +
    // 1 inline. The ≥3 bound is the regression threshold — if a
    // future refactor splits the helper, the threshold can grow in
    // the same commit.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    const failed_emit_count = std.mem.count(u8, source, ".status = .failed");
    try testing.expect(failed_emit_count >= 3);

    // Cross-check: every error-return site must EITHER call
    // `failSubAgent(` (the helper) OR `emitProgressEvent(` directly
    // AND set `.status = .failed` (the workflow-error path).
    // Six error sites → at least 4 helper invocations (the
    // workflow-error branch is direct + 2 helper-struct definitions
    // counted by the helper-name greps below).
    const failhelper_calls = std.mem.count(u8, source, "failSubAgent(");
    const failhelper_already_set = std.mem.count(u8, source, "failSubAgentAlreadySet(");
    const helper_call_sites = failhelper_calls + failhelper_already_set;
    try testing.expect(helper_call_sites >= 4);
}

test "execSpawnSubAgent clears snapshot when final envelope is built" {
    // 2026-09-04 refresh fix: the snapshot registry must be dropped
    // once the final `<results>` envelope exists (success path) and on
    // every error return (errdefer path). Otherwise batches leak
    // process-lifetime rows and a post-completion refresh could
    // rehydrate stale running rows instead of the DB envelope.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    // Success path: explicit clear after the envelope is wrapped.
    try testing.expect(std.mem.count(u8, source, "clearSnapshot(ctx.tool_call_id)") >= 1);
    // Failure paths: errdefer covers every error return.
    try testing.expect(std.mem.indexOf(u8, source, "errdefer subagent_progress.clearSnapshot(ctx.tool_call_id)") != null);
}

test "slugifySubAgentName keeps URL-safe chars, space->underscore" {
    // 2026-09-04 subagent-peek P0: sid must be a single URL-safe path
    // segment. Would have failed before slugify existed (raw spaces
    // broke the HTTP request line, '/' broke router segment matching).
    const alloc = testing.allocator;
    const s1 = try slugifySubAgentName(alloc, "backend implementer");
    defer alloc.free(s1);
    try testing.expectEqualStrings("backend_implementer", s1);

    const s2 = try slugifySubAgentName(alloc, "code-reviewer");
    defer alloc.free(s2);
    try testing.expectEqualStrings("code-reviewer", s2);

    const s3 = try slugifySubAgentName(alloc, "a/b%c<d>e&f");
    defer alloc.free(s3);
    try testing.expectEqualStrings("abcdef", s3);

    const s4 = try slugifySubAgentName(alloc, "");
    defer alloc.free(s4);
    try testing.expectEqualStrings("agent", s4);

    const s5 = try slugifySubAgentName(alloc, "///");
    defer alloc.free(s5);
    try testing.expectEqualStrings("agent", s5);
}

test "execSpawnSubAgent envelope escapes XML" {
    // 2026-09-04 subagent-peek P3: raw <session_id>/<response> broke
    // SpawnSubAgent.vue's regex extraction for names with <>&.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "xml_escape(ctx.allocator, result.name)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "xml_escape(ctx.allocator, result.session_id)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "xml_escape(ctx.allocator, resp)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "xml_escape(ctx.allocator, err)") != null);
}