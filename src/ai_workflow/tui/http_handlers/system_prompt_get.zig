//! GET /test/system-prompt/:session_id
//!
//! Returns ONLY the system prompt that would be sent to the LLM for the
//! given session, rendered through the same `buildMessages` pipeline the
//! production workflow uses (`workflow.zig:509`). This is a debug/inspection
//! endpoint — it does NOT make any LLM call; it just runs the prompt-build
//! path and extracts the `role: .system` message.
//!
//! Why a separate endpoint (instead of reading `llm_history.response_content`):
//! `response_content` only stores the assistant's reply per turn. The actual
//! system prompt is rendered per-request from many sources (skills,
//! memories, background processes, agent content, activity, sub-agents,
//! workspace context, inherited parent history). Inspecting it requires
//! running the full `buildMessages` stack — exactly what this endpoint does.
//!
//! Response shape: `{"session_id":"...","system_prompt":"...","size_bytes":N}`.
//!
//! Errors:
//!   - 400 missing `:session_id` path param
//!   - 404 session not found in DB
//!   - 500 DB failure, buildMessages failure, JSON serialization failure
//!
//! See `src/ai_workflow/tui/http_handlers/session_compact.zig` for the
//! closest sibling (same singleton + buildMessages pattern, but the compact
//! handler proceeds to run compaction afterwards — this one stops after
//! reading the system message).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const llm_history = nalarcore.llm_history;
const agent = nalarcore.agent;
const tool_models = nalarcore.tool_models;

const buildMessages = @import("../build_messages_for_agent_prompt.zig").buildMessages;

/// JSON response struct. `size_bytes` is the byte length of the rendered
/// `system_prompt` so callers can sanity-check they got a non-empty prompt
/// without re-counting bytes on the client.
const SystemPromptResponse = struct {
    session_id: []const u8,
    system_prompt: []const u8,
    size_bytes: u32,
};

pub fn systemPromptGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse "";
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    }

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;
    const io = di.io;

    // Recover the working directory from the session row. A missing row
    // is a 404 — we cannot build a meaningful system prompt without a cwd
    // (the memory loader + workspace context both depend on it).
    const cwd = blk: {
        const session_row_opt = llm_history.get_session(allocator, sqlite_db, session_id) catch null;
        if (session_row_opt) |session| {
            if (session.cwd.len > 0) {
                break :blk try allocator.dupe(u8, session.cwd);
            }
        }
        break :blk null;
    };
    if (cwd == null) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session not found" }),
        });
    }
    const cwd_str: []const u8 = cwd.?;

    // Load the DB-stored message history (same shape `workflow.zig` uses
    // before calling buildMessages). An empty history is fine — buildMessages
    // still emits the system message alone.
    const db_messages = llm_history.getMessages(allocator, sqlite_db, session_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "getMessages failed" }),
        });
    };

    // Mirrors workflow.zig:509's call shape: empty parent_session_id,
    // empty inherited_context, empty activeAgentContent (which falls back
    // to BuildDynamicAgentContent — the main-agent flow's source of truth
    // via the session_agents table). This is the "what does the main
    // agent see" view.
    //
    // buildMessages' 10-arg signature (build_messages_for_agent_prompt.zig:23):
    //   1. allocator, 2. io, 3. db, 4. cwd, 5. session_id,
    //   6. parent_session_id, 7. historyMessages, 8. tools,
    //   9. inherited_context_mode, 10. activeAgentContent
    const merged_tools: []tool_models.AgentTool = &.{};
    const messages = buildMessages(
        allocator,
        io,
        sqlite_db,
        cwd_str,
        session_id,
        "",
        db_messages,
        merged_tools,
        "",
        "",
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages failed" }),
        });
    };
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    // buildMessages always emits messages[0] as the system message (see
    // build_messages_for_agent_prompt.zig:131). Defensive: also check
    // the role so we never silently leak a different role's content.
    if (messages.len == 0 or messages[0].role != .system) {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages returned no system message" }),
        });
    }

    const system_prompt = messages[0].content orelse "";

    const response = SystemPromptResponse{
        .session_id = session_id,
        .system_prompt = system_prompt,
        .size_bytes = @intCast(system_prompt.len),
    };
    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}