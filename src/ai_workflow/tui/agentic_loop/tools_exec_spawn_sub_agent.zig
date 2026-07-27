const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const config_mod = nalarcore.config;
const llm_history = nalarcore.llm_history;
const models = @import("../models.zig");
const ai_workflow = @import("workflow.zig");
const spawn_sub_agent_tool = nalarcore.spawn_sub_agent;
const tools = mod.tools;
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

    const sess_id = std.fmt.allocPrint(
        sub_agent_allocator,
        "subagent_{}_{s}",
        .{ std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds, resolved_display_name },
    ) catch {
        // Mirror the workflow.zig error message pattern (workflow.zig:68)
        // for consistency with the rest of the runSubAgent error paths.
        const err_msg = std.fmt.allocPrint(
            args_ptr.allocator,
            "Agent Nalar System error, the actual error is ->>>> Failed to create session_id for '{s}'\n",
            .{args_ptr.agent_name},
        ) catch "Agent Nalar System error, the actual error is ->>>> Failed to create session_id";
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
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
            args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
            args_ptr.logger.errFmt("Failed to copy session_id for '{s}'", .{args_ptr.agent_name});
            return;
        };
        args_ptr.shared_results.results[args_ptr.thread_idx].session_id = session_id_copy;
    }

    const di = nalarcore.getSingleton() catch unreachable;

    const is_sub_agent = std.mem.indexOf(u8, sess_id, "subagent") != null;
    args_ptr.logger.debugFmt("Calling workflow.runAgenticMultiStep for '{s}'", .{args_ptr.agent_name});

    const logger = di.logger;
    const allocator = di.allocator;
    const active_loops = di.active_loops;
    const event_bus = di.event_bus;
    const db = di.db;
    const io = di.io;
    const config = nalarcore.getLlmConfig(di);
    const environment = di.environment;

    ai_workflow.runAgenticMultiStepnew(.{
        .allocator = allocator,
        .db = db,
        .io = io,
        .logger = logger,
        .event_bus = event_bus,
        .active_loops = active_loops,
        .llm_config = config,
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
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
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
                args_ptr.shared_results.results[args_ptr.thread_idx].error_message = err_msg;
                mutable_msg.deinit(args_ptr.allocator);
                return;
            };
            args_ptr.shared_results.results[args_ptr.thread_idx].response = response_copy;
            args_ptr.shared_results.results[args_ptr.thread_idx].success = true;
        } else {
            args_ptr.shared_results.results[args_ptr.thread_idx].error_message =
                "Agent Nalar System error, the actual error is ->>>> Sub-agent completed but produced empty response content\n";
        }
        mutable_msg.deinit(args_ptr.allocator);
    } else {
        args_ptr.shared_results.results[args_ptr.thread_idx].error_message =
            "Agent Nalar System error, the actual error is ->>>> Sub-agent completed but no message found in database\n";
    }

    _ = args_ptr.shared_results.completed_count.fetchAdd(1, .monotonic);
}

// spawn_sub_agent implementation - uses workflow.zig logic
pub fn execSpawnSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("execSpawnSubAgent called, arguments len={}", .{tc.function.arguments.len});
    ctx.logger.debugFmt("arguments: '{s}'", .{tc.function.arguments[0..@min(tc.function.arguments.len, 200)]});

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
        try w.print("<agent name=\"{s}\" success=\"{s}\" random_fallback=\"{s}\">\n", .{ result.name, success, random_fallback });
        if (result.session_id.len > 0) {
            try w.print("<session_id>{s}</session_id>\n", .{result.session_id});
        }
        if (result.success) {
            if (result.response) |resp| {
                try w.print("<response>{s}</response>\n", .{resp});
            } else {
                try w.print("<response></response>\n", .{});
            }
        } else if (result.error_message) |err| {
            try w.print("<error>{s}</error>\n", .{err});
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
    return ToolExecResult{ .output = output, .output_allocated = true };
}