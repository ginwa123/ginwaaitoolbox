const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const helpers = @import("helpers");
const ai_mod = nalarcore.ai_mod;
const config = nalarcore.config;
const llm_history = ai_mod.llm_history;

/// Get messages for a session
pub fn sessionMessagesHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    const limit_str = req.query.get("limit") orelse "100";
    const cursor = req.query.get("cursor");
    const sort_by_str = req.query.get("sort_by") orelse "created_at";
    const direction_str = req.query.get("direction") orelse "asc";
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 100;

    // Determine sort direction (default: asc)
    const is_desc = std.mem.eql(u8, direction_str, "desc");

    // Parse sort_by parameter and combine with direction
    const sort_spec: llm_history.SortSpec = blk: {
        if (std.mem.eql(u8, sort_by_str, "id")) {
            break :blk if (is_desc)
                llm_history.SortSpec{ .id_desc = {} }
            else
                llm_history.SortSpec{ .id_asc = {} };
        } else if (std.mem.eql(u8, sort_by_str, "role")) {
            break :blk if (is_desc)
                llm_history.SortSpec{ .role_desc = {} }
            else
                llm_history.SortSpec{ .role_asc = {} };
        } else {
            // Default to created_at
            break :blk if (is_desc)
                llm_history.SortSpec{ .created_at_desc = {} }
            else
                llm_history.SortSpec{ .created_at_asc = {} };
        }
    };

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 2026-08-21-fix-ui-context-window — resolve the session's selected
    // profile so the response's `max_capacity_total_tokens` honors the
    // profile's `max_capacity_tokens` override (cascade step 2 in
    // `maxCapacityForModel`). Previously this handler passed no profile,
    // so the chat footer always showed the built-in per-model default
    // (e.g. 500,000) even when the selected profile overrode the window
    // (e.g. 950,000). Graceful degradation: empty name / unknown profile
    // → null → Defaults-tab → built-in default (old behavior).
    //
    // `LlmProfile` is nested inside `LlmConfig` — refer to it as
    // `config.LlmConfig.LlmProfile`. The bare `nalarcore.config.LlmProfile`
    // path compiles in `zig build test` (lib module lookup) but Zig 0.16's
    // `zig build-exe` (exe module lookup) rejects it because the parent
    // struct in the root module is `modules.config.Config` and has no
    // top-level `LlmProfile` member. CI fix 2026-08-21.
    //
    // `resolveSessionProfile` walks session selection → active_profile →
    // null, matching the workflow loop — so a Default chat with
    // active_profile=alpha shows alpha's 950k window, not 500k.
    const cfg = nalarcore.getLlmConfig(di);
    const profile_name = llm_history.getSessionProfileName(allocator, sqlite_db, session_id) catch "";
    const profile: ?config.LlmConfig.LlmProfile =
        llm_history.resolveSessionProfile(cfg, profile_name);

    const msg_response = llm_history.getSessionMessagesSorted(allocator, sqlite_db, session_id, limit_val, cursor, sort_spec, if (profile) |*p| p else null) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Database query failed" }) });
    };

    // 2026-08-24-fix-flaky-create-and-run-profile-test — when the
    // session has ZERO llm_history rows (fresh create_and_run session:
    // the worker drains the queued user message asynchronously), the
    // LEFT JOIN in getSessionMessagesSorted yields no rows and
    // msg_response.selected_profile_model stays null even though the
    // sessions row already carries the profile. Fall back to the
    // direct sessions-table read (already fetched above for the
    // capacity cascade) so the chatview's profile chip is correct from
    // the very first GET — no race with the worker.
    const selected_profile_model_final: ?[]const u8 = blk: {
        if (msg_response.selected_profile_model) |spm| break :blk spm;
        if (profile_name.len > 0) break :blk profile_name;
        break :blk null;
    };

    // Convert llm_history.SessionMessageResponse to http_response.SessionMessagesResponse
    var messages: []http_response.SessionMessage = try allocator.alloc(http_response.SessionMessage, msg_response.messages.len);
    for (msg_response.messages, 0..) |msg, idx| {
        // Join multiple image URLs into a pipe-separated string
        var image_url_str: []u8 = &[_]u8{};
        if (msg.image_urls) |urls| {
            var combined = std.ArrayList(u8).empty;
            errdefer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.append(allocator, '|');
                try combined.appendSlice(allocator, url);
            }
            image_url_str = try combined.toOwnedSlice(allocator);
        }

        messages[idx] = http_response.SessionMessage{
            .id = msg.id,
            .session_id = msg.session_id,
            .role = msg.role,
            .content = try helpers.sanitize.sanitizeUtf8(allocator, msg.content),
            .created_at = msg.timestamp,
            .is_input = msg.is_input,
            .is_output = msg.is_output,
            .tool_name = msg.tool_name,
            .finish_reason = msg.finish_reason,
            .reasoning_content = msg.reasoning_content,
            .diffview_before = msg.diffview_before orelse "",
            .diffview_after = msg.diffview_after orelse "",
            .image_url = image_url_str,
            .tool_call_id = msg.tool_call_id orelse "",
            .tool_calls_json = msg.tool_calls_json orelse "",
        };
    }

    const http_resp = http_response.SessionMessagesResponse{
        .messages = messages,
        .has_more = msg_response.has_more,
        .next_cursor = msg_response.next_cursor,
        .cwd = msg_response.cwd,
        .git_worktree_cwd = msg_response.git_worktree_cwd,
        // 2026-08-07-profile-persist-read — pass the per-session
        // selected profile name through so the frontend's profile chip
        // survives a page refresh. Without this the chip resets to
        // "Default" because the read endpoint never returned the field
        // that PUT /api/llm/session/:id persists.
        .selected_profile_model = selected_profile_model_final,
        .skills = msg_response.skills,
        .max_total_tokens = msg_response.max_total_tokens,
        .max_capacity_total_tokens = msg_response.max_capacity_total_tokens,
        .total = msg_response.total_count,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeSessionMessagesResponse(allocator, http_resp) });
}

