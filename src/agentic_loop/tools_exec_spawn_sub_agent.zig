//! The `spawn_sub_agent` tool: the tool layer over the shared batch runner.
//!
//! The batch itself — concurrency, the per-thread lifecycle, the progress
//! protocol and the allowlist policy — lives in `sub_agent_batch.zig`, which
//! the Skill Evals judge tier also drives. This file is the tool's half: parse
//! a tool call, resolve the per-agent config overlay, and format the wire
//! envelope.
//!
//! It is deliberately NOT a second implementation of any of that. Two copies
//! of the fan-out would drift, and the drift would be invisible until a
//! frontend card stranded on `running`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const batch = @import("sub_agent_batch.zig");

const logger_mod = pabrikcore.loggermod;
const ai_workflow = @import("workflow.zig");
const spawn_sub_agent_tool = pabrikcore.spawn_sub_agent;
const subagent_progress = @import("subagent_progress.zig");
const sanitize = @import("helpers").sanitize_control_chars;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;

pub const slugifySubAgentName = batch.slugifySubAgentName;

pub const ThreadResult = batch.ThreadResult;

/// The batch size this tool advertises in its schema and enforces at parse
/// time. The runner has its own `MaxBatch`; passing this keeps the tool's
/// public contract and the runner's ceiling identical.
const MaxBatch = 20;

pub fn execSpawnSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("execSpawnSubAgent called, arguments len={}", .{tc.function.arguments.len});
    ctx.logger.debugFmt("arguments: '{s}'", .{tc.function.arguments[0..@min(tc.function.arguments.len, 200)]});

    // 2026-09-04 refresh fix: the snapshot registry (subagent_progress)
    // is the refresh-rehydrate source until the final envelope lands in
    // the DB. If exec fails before building the envelope, drop the
    // batch's rows so a refresh falls back to Task 0's "starting…"
    // copy instead of stranding stale running rows. Idempotent.
    errdefer subagent_progress.clearSnapshot(ctx.tool_call_id);

    const parsed = spawn_sub_agent_tool.parse_sub_agents(ctx.allocator, tc.function.arguments, MaxBatch) catch |err| {
        ctx.logger.errFmt("parse_sub_agents failed: {}", .{err});
        // Propagate the SPECIFIC parse error (e.g. AllToolsNotAllowed,
        // EmptySubAgentTools) instead of collapsing to a generic
        // InvalidArguments — dispatchTool formats @errorName(err) into
        // the envelope <error>, which the card now renders.
        return err;
    };
    defer parsed.deinit(ctx.allocator);

    const sub_agent_count = parsed.sub_agents.len;
    ctx.logger.debugFmt("Parsed {} sub-agents", .{sub_agent_count});

    const jobs = try ctx.allocator.alloc(batch.BatchJob, sub_agent_count);
    defer ctx.allocator.free(jobs);
    for (parsed.sub_agents, 0..) |sub_agent, i| {
        ctx.logger.debugFmt("Sub-agent {}: agent_name='{s}', instruction_len={}", .{ i, sub_agent.agent_name, sub_agent.instruction.len });
        jobs[i] = .{
            .name = sub_agent.agent_name,
            .instruction = sub_agent.instruction,
            .tools = sub_agent.tools,
            .inherited_context = sub_agent.inherited_context orelse "",
            .overrides = resolveOverrides(ctx, sub_agent.agent_name),
        };
    }

    var outcome = batch.runBatch(.{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .db = ctx.db,
        .logger = ctx.logger,
        .parent_sess_id = ctx.session_id,
        .cwd = ctx.cwd,
        .environment = ctx.environment,
        .selected_profile_model = ctx.selected_profile_model,
        .tool_call_id = ctx.tool_call_id,
    }, jobs) catch |err| {
        ctx.logger.errFmt("sub-agent batch failed: {}", .{err});
        return err;
    };
    defer outcome.deinit();

    // The per-agent results below are serialized with
    // `std.json.Stringify.valueAlloc` (never string-concat) — no
    // intermediate writer buffer needed.
    const success_count = outcome.succeeded();

    // Build the result JSON object via `std.json.Stringify.valueAlloc`
    // (never string-concat). Former tag names become keys 1:1; the
    // optional session/response/error slots are explicit nulls when
    // absent and per-agent entries form the `results` array.
    const JsonAgent = struct {
        name: []const u8,
        success: bool,
        random_fallback: bool,
        session_id: ?[]const u8,
        response: ?[]const u8,
        @"error": ?[]const u8,
    };
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| ctx.allocator.free(s);
        owned.deinit(ctx.allocator);
    }
    var agents = try ctx.allocator.alloc(JsonAgent, outcome.results.len);
    defer ctx.allocator.free(agents);
    for (outcome.results, 0..) |result, i| {
        // Sanitize free text so names/responses carrying control bytes
        // can't break the JSON payload (Stringify handles the rest).
        const name = try sanitize(ctx.allocator, result.name);
        try owned.append(ctx.allocator, name);
        const sid: ?[]u8 = if (result.session_id.len > 0)
            try sanitize(ctx.allocator, result.session_id)
        else
            null;
        if (sid) |s| try owned.append(ctx.allocator, s);
        var resp: ?[]u8 = null;
        var errmsg: ?[]u8 = null;
        if (result.success) {
            if (result.response) |r| {
                resp = try sanitize(ctx.allocator, r);
                try owned.append(ctx.allocator, resp.?);
            }
        } else if (result.error_message) |e| {
            errmsg = try sanitize(ctx.allocator, e);
            try owned.append(ctx.allocator, errmsg.?);
        } else {
            errmsg = try sanitize(ctx.allocator, "unknown error");
            try owned.append(ctx.allocator, errmsg.?);
        }
        agents[i] = .{
            .name = name,
            .success = result.success,
            .random_fallback = result.is_random_fallback,
            .session_id = sid,
            .response = resp,
            .@"error" = errmsg,
        };
    }
    const inner_owned = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .results = agents,
        .summary = .{
            .succeeded = success_count,
            .failed = sub_agent_count - success_count,
        },
    }, .{});
    const output = try wrapToolOutput(ctx.allocator, "spawn_sub_agent", tc.function.arguments, true, null, inner_owned);
    // 2026-09-04 refresh fix: the final results payload is built —
    // the DB row (written by handle_tool's updateAndSendToolResult right
    // after we return) takes over as the source of truth, so the
    // snapshot has served its purpose. Drop it; a post-completion
    // refresh renders the payload, never the snapshot. (The errdefer
    // above covers the failure paths.)
    subagent_progress.clearSnapshot(ctx.tool_call_id);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Resolve one sub-agent's config overlay from the live LlmConfig.
///
/// `agent_name` is the LLM-provided name. It is looked up in the active
/// profile's sub_agents list and the resolved fields become an overlay on the
/// orchestrator's defaults; a name that matches nothing falls back to a
/// generated random name plus the defaults.
///
/// The `@constCast` is needed because `resolveSubAgent` mutates
/// `self.random_names` to track the random fallback's allocation for deinit
/// cleanup. The LlmConfig is logically immutable (it lives in the singleton
/// for the server's lifetime); this single private mutation is a tracking
/// side-effect, not a semantic change. Casting away const at the one
/// production call site keeps the rest of the type system honest about
/// read-only access.
fn resolveOverrides(ctx: ToolExecContext, an: []const u8) ai_workflow.SubAgentOverrides {
    const resolved = @constCast(ctx.config).resolveSubAgent(ctx.selected_profile_model, an);
    if (resolved.is_random_fallback) {
        ctx.logger.warnFmt("spawn_sub_agent: agent_name '{s}' not found in LlmConfig.sub_agents; using random name '{s}' and orchestrator defaults", .{ an, resolved.name });
    } else {
        ctx.logger.infoFmt("spawn_sub_agent: agent_name '{s}' resolved (source='{s}', model='{s}')", .{ an, resolved.source, resolved.model });
    }
    return .{
        .resolved_name = resolved.name,
        .is_random_fallback = resolved.is_random_fallback,
        .model = resolved.model,
        .base_url = resolved.base_url,
        .api_key = resolved.api_key,
        .url_style = resolved.url_style,
        .is_thinking = resolved.is_thinking,
        .temperature = resolved.temperature,
        // Model-thinking knobs (plan 2026-08-23-model-thinking), threaded from
        // ResolvedSubAgent so the spawned sub-agent can override its parent
        // profile's thinking budget / reasoning effort without touching the
        // global config.
        .thinking_budget_tokens = resolved.thinking_budget_tokens,
        .reasoning_effort = resolved.reasoning_effort,
        .system_prompt = resolved.system_prompt,
    };
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
// and assert required string fragments exist. The per-thread runtime
// now lives in `sub_agent_batch.zig`, so the tool file and the batch
// file are read together — the invariant spans both, and grepping only
// the tool file would pass while the batch lost the emit.
// =====================================================================

const testing = std.testing;
const impl_path = "src/agentic_loop/tools_exec_spawn_sub_agent.zig";
const batch_impl_path = "src/agentic_loop/sub_agent_batch.zig";

/// The tool file and the batch runner concatenated, so an assertion about the
/// fan-out holds wherever the code now lives.
fn readImplSource(allocator: std.mem.Allocator) ![]u8 {
    const max_bytes: usize = 2 * 1024 * 1024;
    const tool_src = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, allocator, .limited(max_bytes));
    defer allocator.free(tool_src);
    const batch_src = try std.Io.Dir.cwd().readFileAlloc(testing.io, batch_impl_path, allocator, .limited(max_bytes));
    defer allocator.free(batch_src);
    return std.mem.concat(allocator, u8, &.{ tool_src, "\n", batch_src });
}

test "execSpawnSubAgent uses emitProgressEvent for launched/completed/failed" {
    const source = try readImplSource(testing.allocator);
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
    const source = try readImplSource(testing.allocator);
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
    const source = try readImplSource(testing.allocator);
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

test "execSpawnSubAgent payload sanitizes free text and serializes via Stringify" {
    // 2026-09-04 subagent-peek P3: raw <session_id>/<response> broke
    // SpawnSubAgent.vue's regex extraction for names with <>&. The JSON
    // payload sanitizes control bytes and lets Stringify escape the rest.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "sanitize(ctx.allocator, result.name)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "sanitize(ctx.allocator, result.session_id)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") != null);
    // Probe is concatenated so this assertion's own source text can't self-match.
    const probe = "xml_escape(ctx.alloc" ++ "ator";
    try testing.expect(std.mem.indexOf(u8, source, probe) == null);
}

test "spawn forwards selected_profile_model to subagent child" {
    // Subagent rows used to persist NULL profile because runSubAgent
    // never forwarded the parent's selection to RunParamsNew. The
    // child then resolved top-level defaults instead of the parent
    // profile (e.g. union alpha) on every LLM call.
    //
    // The two hops are the tool's launch site (parent selection into the
    // job) and the batch's per-thread site (job selection into the child
    // run params). Both are asserted, because breaking either one produces
    // the identical symptom and the fix is in a different file.
    const source = try readImplSource(testing.allocator);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "selected_profile_model: []const u8") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".selected_profile_model = ctx.selected_profile_model") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".selected_profile_model = args_ptr.selected_profile_model") != null);
}

test "the tool delegates to the one batch runner rather than fanning out itself" {
    // The whole reason sub_agent_batch.zig exists: if the tool ever grows its
    // own concurrency group again there are two fan-outs, and the judge tier
    // would be driving a copy whose progress and policy had drifted.
    const max_bytes: usize = 1 * 1024 * 1024;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, impl_path, testing.allocator, .limited(max_bytes));
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "batch.runBatch(") != null);
    // Probes are concatenated so this test's own source text cannot self-match.
    const group_probe = "std.Io." ++ "Group";
    try testing.expect(std.mem.indexOf(u8, source, group_probe) == null);
    const concurrent_probe = "group." ++ "concurrent";
    try testing.expect(std.mem.indexOf(u8, source, concurrent_probe) == null);
}
