const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const llm_history = nalarcore.llm_history;
const config = nalarcore.config;
const agent = nalarcore.agent;
const tool_models = nalarcore.tool_models;
const http_response = nalarcore.http_response;
const workflow = nalarcore.ai_mod.ai_workflow;
const buildMessages = @import("../agentic_loop/prompts_build_messages_for_agent_prompt.zig").buildMessages;


/// Trigger session compaction directly (synchronous - blocks until done)
/// Path param: session_id
/// Returns JSON with result
pub fn sessionCompactHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;
    const io = di.io;
    const logger = di.logger;

    // Recover the working directory from the session row. A missing row
    // is non-fatal — fall back to "." so the compact agent can still
    // attempt a compaction. (Per the per-request arena convention in
    // this codebase, the SessionDetail returned by get_session does not
    // need an explicit deinit here — the arena reaps it on request end.)
    const cwd = blk: {
        const session_row_opt = llm_history.get_session(allocator, sqlite_db, session_id) catch null;
        if (session_row_opt) |session| {
            if (session.cwd.len > 0) {
                break :blk try allocator.dupe(u8, session.cwd);
            }
        }
        break :blk try allocator.dupe(u8, ".");
    };

    // Pull the LLM credentials from the live config (read-only borrows).
    const live_cfg = nalarcore.getLlmConfig(di);
    const api_key = live_cfg.api_key;
    const model = live_cfg.model;
    const base_url = live_cfg.base_url;
    // url_style must be propagated to `maybeCompactMessagesNew` so the
    // CompactionAgent sends the SAME wire format as the calling
    // session — otherwise an `url_style: "anthropic"` profile sends
    // an OpenAI-shaped JSON body to an Anthropic endpoint and the
    // compaction silently fails (returns null from callCompactAgent).
    // For the manual `Compact` button the user clicks from the UI,
    // this fixes the same root cause as the workflow.zig propagation
    // fix (PR companion).
    const url_style = live_cfg.url_style;

    // 2026-08-21-fix-ui-context-window — resolve the session's selected
    // profile so the compaction decision honors the profile's
    // `max_capacity_tokens` / `compaction_threshold_percent` overrides,
    // matching the workflow loop and the (now profile-aware) chat footer.
    // Graceful degrade: empty/unknown profile → null → old cascade.
    //
    // `LlmProfile` is nested inside `LlmConfig` — use the qualified path
    // `config.LlmConfig.LlmProfile`. Bare `config.LlmProfile` compiles
    // in `zig build test` (lib mode) but Zig 0.16's `zig build-exe`
    // rejects it because the root module only exposes the `Config`
    // struct under `modules.config`. Same fix as session_messages_get.zig.
    const compact_profile: ?config.LlmConfig.LlmProfile = blk: {
        const profile_name = llm_history.getSessionProfileName(allocator, sqlite_db, session_id) catch "";
        if (profile_name.len > 0) {
            if (live_cfg.getProfile(profile_name)) |p| break :blk p;
        }
        break :blk null;
    };

    // Load the DB-stored message history and turn it into the in-memory
    // agent-message form that the compact agent operates on.
    const db_messages = llm_history.getMessages(allocator, sqlite_db, session_id) catch |err| {
        logger.errFmt("[COMPACTION] getMessages failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "getMessages failed" }) });
    };

    var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;

    const merged_tools: []tool_models.AgentTool = &.{};
    const initialMessages = buildMessages(allocator, io, sqlite_db, cwd, session_id, "", db_messages, merged_tools, "") catch |err| {
        logger.errFmt("[COMPACTION] buildMessages failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages failed" }) });
    };
    try messagesLists.appendSlice(allocator, initialMessages);

    // Compute the max total_tokens across the loaded messages. Fed to
    // maybeCompactMessagesNew for diagnostic logging; the threshold
    // check itself is bypassed by `force=true` because the caller
    // explicitly requested compaction via this HTTP endpoint.
    var total_tokens: u32 = 0;
    for (db_messages) |msg| {
        if (msg.total_tokens > total_tokens) total_tokens = msg.total_tokens;
    }

    // Manual endpoint: force compaction regardless of the auto-threshold.
    messagesLists = workflow.maybeCompactMessagesNew(
        workflow.defaultCompactDeps,
        allocator,
        total_tokens,
        model,
        true,
        messagesLists,
        api_key,
        base_url,
        url_style,
        cwd,
        session_id,
        sqlite_db,
        io,
        logger,
        // Manual endpoint — pass the singleton's event_bus when one
        // is reachable; the DB write happens regardless, and `null`
        // would just skip the SSE fanout to subscribers of this
        // manual compact action. Production callers inside the HTTP
        // server always have the singleton initialized (it lives
        // for the full process lifetime, set in main.zig:124).
        // Reuse the `di` we already fetched above instead of doing
        // a second `getSingleton()` round-trip.
        di.event_bus,
        live_cfg,
        if (compact_profile) |*p| p else null,
    ) catch |err| {
        logger.errFmt("[COMPACTION] manual compaction failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "compaction failed" }) });
    };

    logger.infoFmt("[COMPACTION] manual compaction completed for session {s}", .{session_id});
    const success_data = try std.json.Stringify.valueAlloc(allocator, .{ .success = true, .message = "Compaction completed" }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = success_data });
}



fn useCase() !void {

}
