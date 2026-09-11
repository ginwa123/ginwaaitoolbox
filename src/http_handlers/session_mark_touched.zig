//! `POST /api/session/:session_id/touched`.
//! `POST /api/llm/session/:session_id/touched`.
//!
//! Marks a chat session as seen by the human: stamps
//! `sessions.last_human_touched_at_nano = <unix_ms>` (Migration 082) and
//! emits a `session.updated` SSE event so connected clients clear the
//! yellow "AI is ahead of you" stale dot without a manual page reload.
//!
//! Why this endpoint exists
//! ─────────────────────────
//! The sidebar's per-chat time pill is sourced from
//! `last_human_touched_at ?? updated_at` and the amber stale dot shows
//! when `updated_at > last_human_touched_at`. Opening a chat to "just
//! read" the AI's output previously never bumped the column, so the
//! yellow dot stuck around until some other edit (rename / profile
//! switch / retry) happened to stamp it. The frontend fires this POST
//! the moment a user opens a session's chat — opening a chat to read
//! counts as a review, mirroring the kanban sibling
//! (`task_mark_human_touched.zig`, human_touched action).
//!
//! Idempotent: re-stamping the timestamp is harmless. Multiple clients
//! firing the POST simultaneously just produce the same DB write.
//!
//! Wire shape
//! ──────────
//! Request: empty body or `{}` (no fields required — the body is ignored).
//! Response: `200 { "success": true, "session_id": "sess_..." }`.
//! Errors:
//!   - 400 `session_id required` — path param missing or empty
//!   - 500 `Out of memory` — `std.json.Stringify.valueAlloc` failure
//!
//! Route registration (src/main.zig, next to the sibling PUT routes):
//!   - `POST /api/session/:session_id/touched`
//!   - `POST /api/llm/session/:session_id/touched`
//! No shadowing: POST differs in method from the existing PUT/GET on the
//! overlapping prefixes, and the literal `touched` tail differs from the
//! sibling `messages` / `queue_messages` / `stream` tails.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = ai_mod.llm_history;
const on_event_sent = ai_mod.on_event_sent;

pub const MarkSessionTouchedError = error{
    SessionIdRequired,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const MarkSessionTouchedResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

pub const MarkSessionTouchedResponse = struct {
    success: bool = true,
    session_id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    session_id: []const u8,
) MarkSessionTouchedError!MarkSessionTouchedResult {
    if (session_id.len == 0) return error.SessionIdRequired;

    // 1. Capture "now" once so the DB stamp and the SSE payload below
    //    agree on the exact unix-ms value (no second SELECT needed).
    const now_ms = llm_history.unixMillisNow();

    // 2. Ensure the row exists before any UPDATE (mirrors
    //    session_update.zig:66). The user can land here by opening a
    //    brand-new chat: the session_id is in the URL but the row
    //    hasn't been INSERTed yet (no message queued).
    _ = llm_history.ensureSessionExists(allocator, db, session_id) catch {
        // Collapse storage errors to a single caller-handled variant
        // (matches the sibling pattern at
        // task_mark_human_touched.zig:70 — narrow use-case error sets).
        return error.SessionIdRequired;
    };

    // 3. Stamp the column with the captured timestamp (explicit value
    //    so the SSE payload matches the DB write exactly).
    llm_history.updateSessionLastHumanTouchedAt(allocator, db, session_id, now_ms) catch {
        return error.SessionIdRequired;
    };

    // 4. Re-read for the SSE payload (mirrors the update_session_status
    //    pattern in llm_history.zig). Unreachable after a successful
    //    ensure, but fail closed rather than emitting a half payload.
    //    NOTE: no `defer session.deinit(allocator)` — the per-request
    //    arena reclaims the duped strings when the request scope ends.
    const session = (llm_history.getSession(allocator, db, session_id) catch {
        return error.SessionIdRequired;
    }) orelse return error.SessionIdRequired;

    // 5. Emit SSE so connected sidebar clients clear the stale dot
    //    live. Best-effort (matches tasks_move.zig and
    //    task_mark_human_touched.zig): SSE failures log a warning but
    //    don't fail the request — the DB write is already committed
    //    and the sidebar picks up the new state on its next refetch.
    //    NOTE: no `defer allocator.free` — arena-owned.
    const touched_at_str = std.fmt.allocPrint(allocator, "{d}", .{now_ms}) catch {
        return error.OutOfMemory;
    };
    on_event_sent.onEventSendSessions(allocator, .{
        .action = "updated",
        .id = session.id,
        .name = session.name,
        .status = session.status,
        .cwd = session.cwd,
        .created_at = session.created_at,
        .updated_at = session.updated_at,
        .selected_profile_model = session.selected_profile_model,
        .git_worktree_cwd = session.git_worktree_cwd,
        .is_auto_retry_until_stop = session.is_auto_retry_until_stop,
        .last_finish_reason = session.last_finish_reason,
        .last_human_touched_at = touched_at_str,
    }) catch |err| {
        std.log.warn(
            "session_mark_touched: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return try std.json.Stringify.valueAlloc(
        allocator,
        MarkSessionTouchedResponse{ .session_id = session_id },
        .{},
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionMarkTouchedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // The body is intentionally ignored — empty body and `{}` are both
    // accepted (the stamp needs no input beyond the path param).
    const session_id = req.params.get("session_id") orelse "";
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, session_id) catch |err| {
        const status: u16 = switch (err) {
            error.SessionIdRequired => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.SessionIdRequired => "session_id required",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// =====================================================================
// Static-contract tests (inline — registered via test_runner.zig, which
// imports this file so `zig build test` runs them; mirrors the
// session_create.zig precedent).
//
// These lock in structural contracts that are hard to assert from
// behavioural tests: the useCase must stamp the chat-side column, must
// emit the session SSE event with the updated action, and both POST
// routes must stay registered in main.zig. Fail closed if a future
// refactor drops any of the three.
//
// Needles built via concatenation (see session_update_test.zig): this
// file IS the scanned file, so a verbatim needle in the test body
// would self-match and pass vacuously.
// =====================================================================

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;
const HANDLER_PATH = "src/http_handlers/session_mark_touched.zig";
const MAIN_PATH = "src/main.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "session_mark_touched useCase stamps the chat-side human-touched column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The chat-side stamp helper, defined in `llm_history.zig`.
    // Concatenated so this file's test body does NOT contain the
    // literal name (which would self-match the grep — the file under
    // test and the test body are the same file here).
    const needle = "updateSessi" ++ "onLastHumanTouchedAt";
    if (!contains(source, needle)) {
        std.debug.print(
            "\n!! {s} does NOT call the chat-side stamp helper !!\n"
            ++ "   The mark-as-seen useCase must stamp the sessions\n"
            ++ "   human-touched column so opening a chat clears the\n"
            ++ "   sidebar yellow stale dot.\n",
            .{HANDLER_PATH},
        );
        return error.SessionMarkTouchedStampMissing;
    }
}

test "session_mark_touched useCase emits the session SSE event with the updated action" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Concatenated for the same self-match reason as above: the debug
    // prints below deliberately avoid the contiguous helper name and
    // the contiguous quoted action string.
    const emit_needle = "onEventSend" ++ "Sessions";
    if (!contains(source, emit_needle)) {
        std.debug.print(
            "\n!! {s} does NOT emit the session SSE event !!\n"
            ++ "   Without the session emit, the sidebar only clears the\n"
            ++ "   stale dot on its next refetch instead of live.\n",
            .{HANDLER_PATH},
        );
        return error.SessionMarkTouchedSseMissing;
    }

    const updated_needle = "\"" ++ "updat" ++ "ed\"";
    if (!contains(source, updated_needle)) {
        std.debug.print(
            "\n!! {s} does NOT carry the updated action !!\n"
            ++ "   The mark-as-seen SSE event must carry the updated action\n"
            ++ "   so the frontend routes it to the session channel.\n",
            .{HANDLER_PATH},
        );
        return error.SessionMarkTouchedActionMissing;
    }
}

test "session_mark_touched POST routes stay registered in main.zig under both prefixes" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // Scanned file here is main.zig (not this file), so verbatim
    // needles are safe.
    const route_a = "/api/session/:session_id/touched";
    const route_b = "/api/llm/session/:session_id/touched";
    if (!contains(source, route_a)) {
        std.debug.print(
            "\n!! {s} is missing POST {s} !!\n"
            ++ "   The frontend mark-as-seen call 404s and the yellow stale\n"
            ++ "   dot never clears on click.\n",
            .{ MAIN_PATH, route_a },
        );
        return error.SessionMarkTouchedRouteAMissing;
    }
    if (!contains(source, route_b)) {
        std.debug.print(
            "\n!! {s} is missing POST {s} !!\n"
            ++ "   The desktop app prefix must expose the same mark-as-seen\n"
            ++ "   endpoint.\n",
            .{ MAIN_PATH, route_b },
        );
        return error.SessionMarkTouchedRouteBMissing;
    }
    if (!contains(source, "sessionMarkTouchedHandler")) {
        std.debug.print(
            "\n!! {s} does not reference sessionMarkTouchedHandler !!\n"
            ++ "   The touched routes must be wired to the new handler.\n",
            .{MAIN_PATH},
        );
        return error.SessionMarkTouchedHandlerMissing;
    }
}
