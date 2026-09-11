//! GET /api/llm/session/:session_id/stream — in-flight stream snapshot.
//!
//! 2026-09-02 stream-resume-on-reselect (task_1787673548905_0):
//! When the user closes/re-selects a chat session mid-stream, ChatView
//! drops its `streaming-*` placeholder and resets `streamingContent`.
//! The backend keeps streaming chunks, but the re-mounted view has no
//! way to recover the partial text. This handler serves the backend's
//! authoritative in-memory buffer (`stream_snapshot.zig`) so the
//! frontend can resume seamlessly.
//!
//! Wire shape: `{ active: bool, content: string }`
//! - active=true  → a stream is in flight; content is the partial text.
//! - active=false → idle (or finished); content is the last turn's text
//!   (kept for a late poll) or "" when the session never streamed.
//!
//! NOTE: this is an in-memory read only — the in-flight turn is NOT in
//! llm_history yet, so reading from the DB here would always return
//! stale/no data.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const helpers = @import("helpers");
const ai_mod = nalarcore.ai_mod;
const stream_snapshot = ai_mod.stream_snapshot;

/// Get the in-flight stream snapshot for a session.
pub fn streamGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id required" }) });
    };
    if (session_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id required" }) });
    }

    const snap = try stream_snapshot.getSnapshot(allocator, session_id);

    // Build the JSON body manually — `data` must be a pre-serialized
    // JSON string (see worker_get.zig pattern), not an anonymous struct.
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"active\":{},\"content\":{f}}}",
        .{ snap.active, std.json.fmt(snap.content, .{}) },
    );

    return res.jsonResponse(.{
        .status_code = 200,
        .data = body,
    });
}
