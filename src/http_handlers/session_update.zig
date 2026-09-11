const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const llm_history = root_mod.llm_history;
const http_response = @import("http_response.zig");

/// Request body for updating an existing session
pub const RequestSessionUpdate = struct {
    /// Name of a profile in LlmConfig.profiles_models.
    /// Empty string OR missing key = clear (use top-level config).
    selected_profile_model: []const u8 = "",
    /// Optional — also support renaming in the same endpoint for symmetry.
    /// Empty string OR missing key = unchanged.
    name: []const u8 = "",
    /// Migration 063 — toggle the unattended-mode flag. "1" to enable,
    /// "0" to disable. Empty string OR missing key = unchanged
    /// (preserves today's "no-op when omitted" behavior).
    is_auto_retry_until_stop: []const u8 = "",
};

/// Response body for session update
pub const ResponseSessionUpdate = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
    /// Migration 063 — echo the current unattended-mode flag back so
    /// the frontend's reactive Pinia store refreshes from the response.
    is_auto_retry_until_stop: []const u8,
};

/// PUT /api/session/:session_id
/// PUT /api/llm/session/:session_id
///
/// Body (JSON, all fields optional):
///   - selected_profile_model: profile name to assign to this session (empty/null = clear)
///   - name: new session name (empty/null = unchanged)
pub fn sessionUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    if (session_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    }

    const parsed = std.json.parseFromSliceLeaky(RequestSessionUpdate, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };

    // Get the singleton DB handle
    const di = try root_mod.getSingleton();
    const sqlite_db = di.db;

    // Plan 2026-08-06-set-active-profile-default — ensure the row
    // exists before any UPDATE. The user can land here by changing
    // the profile on a brand-new chat: the session_id is in the URL
    // but the row hasn't been INSERTed yet (no message queued). The
    // helper auto-creates with defaults so subsequent UPDATEs succeed
    // and the user's profile choice is preserved for the first real
    // LLM call. Without this, getSession() below returns null and the
    // handler 404s with "session not found".
    _ = try llm_history.ensureSessionExists(allocator, sqlite_db, session_id);

    // Update selected_profile_model (always — even if empty, to allow clearing)
    try llm_history.updateSessionSelectedProfileModel(allocator, sqlite_db, session_id, parsed.selected_profile_model);

    // Optionally update name
    if (parsed.name.len > 0) {
        try llm_history.updateSessionName(allocator, sqlite_db, session_id, parsed.name);
    }

    // Migration 063 — toggle unattended mode. Empty body value = no-op
    // (preserves existing "do nothing when omitted" semantics so a
    // frontend that only sends selected_profile_model/name doesn't
    // accidentally flip the flag).
    if (parsed.is_auto_retry_until_stop.len > 0) {
        try llm_history.updateSessionAutoRetryUntilStop(
            allocator,
            sqlite_db,
            session_id,
            parsed.is_auto_retry_until_stop,
        );
    }

    // Re-read for the response
    const session = (try llm_history.getSession(allocator, sqlite_db, session_id)) orelse {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session not found" }) });
    };
    defer session.deinit(allocator);

    // NEW (plan 2026-08-29-chat-sidebar-last-human-touched, Task 4):
    // Stamp `sessions.last_human_touched_at_nano` when the user
    // genuinely edits a field (rename / profile switch / unattended
    // toggle). The earlier early-return on empty body ensures we
    // never reach here with zero fields to update, so this stamp is
    // only triggered by a real edit - no separate guard needed.
    //
    // Best-effort: log + continue on transient DB blip so a stamp
    // failure can't fail the PUT response. Matches the project
    // pattern at `task_mark_human_touched.zig:70` (task-side sibling).
    llm_history.updateSessionLastHumanTouchedAt(
        allocator, sqlite_db, session_id, null,
    ) catch |stamp_err| {
        std.log.warn(
            "session_update: stamp last_human_touched_at failed (non-fatal): {s}",
            .{@errorName(stamp_err)},
        );
    };

    const data = try http_response.makeSessionUpdateResponse(allocator, .{
        .id = session.id,
        .name = session.name,
        .status = session.status,
        .selected_profile_model = session.selected_profile_model,
        // Migration 063 — echo the (post-update) flag value so the
        // frontend's PUT response reflects the new state.
        .is_auto_retry_until_stop = session.is_auto_retry_until_stop,
    });

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
