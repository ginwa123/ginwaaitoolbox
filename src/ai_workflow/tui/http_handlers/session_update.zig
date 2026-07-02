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
};

/// Response body for session update
pub const ResponseSessionUpdate = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
};

pub const SessionUpdateError = error{
    OutOfMemory,
    InvalidJson,
    SessionNotFound,
    UpdateFailed,
};

const SessionUpdateInput = struct {
    session_id: []const u8,
    body: RequestSessionUpdate,
    db: *root_mod.sqlite.SqliteBackend,
};

const SessionUpdateResult = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
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

    const di = try root_mod.getSingleton();

    const result = useCase(allocator, .{
        .session_id = session_id,
        .body = parsed,
        .db = di.db,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.SessionNotFound => 404,
            error.InvalidJson => 400,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.SessionNotFound => "session not found",
            error.InvalidJson => "Invalid JSON",
            error.UpdateFailed => "Failed to update session",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{ .status_code = status, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }) });
    };

    const data = try http_response.makeSessionUpdateResponse(allocator, .{
        .id = result.id,
        .name = result.name,
        .status = result.status,
        .selected_profile_model = result.selected_profile_model,
    });

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

fn useCase(allocator: std.mem.Allocator, input: SessionUpdateInput) SessionUpdateError!SessionUpdateResult {
    // Update selected_profile_model (always — even if empty, to allow clearing)
    llm_history.updateSessionSelectedProfileModel(allocator, input.db, input.session_id, input.body.selected_profile_model) catch {
        return error.UpdateFailed;
    };

    // Optionally update name
    if (input.body.name.len > 0) {
        llm_history.updateSessionName(allocator, input.db, input.session_id, input.body.name) catch {
            return error.UpdateFailed;
        };
    }

    // Re-read for the response
    const session = (llm_history.getSession(allocator, input.db, input.session_id) catch {
        return error.UpdateFailed;
    }) orelse return error.SessionNotFound;
    defer session.deinit(allocator);

    return .{
        .id = session.id,
        .name = session.name,
        .status = session.status,
        .selected_profile_model = session.selected_profile_model,
    };
}