//! GET /api/subagent/progress/:tool_call_id — live spawn-batch snapshot.
//!
//! 2026-09-04 spawn-subagent-refresh-persist (task_1788505292766_1):
//! Progress events are SSE-ephemeral, so a page refresh mid-run wipes
//! ChatView's `subAgentProgressMap` with no replay. This handler serves
//! the backend's authoritative in-memory snapshot
//! (`subagent_progress.zig` registry, mirrored on every emit) so
//! `loadChatHistory` can rehydrate the map for placeholder rows.
//!
//! Wire shape: `{ tool_call_id: string, progress: [{ agent_name,
//! status, agent_index, total_agents, subagent_session_id,
//! elapsed_ms }] }`
//! - progress=[] → unknown/cleared (completed, or server restarted).
//!   The frontend falls back to Task 0's "starting…" copy.
//! - `subagent_session_id` is "" when not yet known; the frontend
//!   normalizes "" → undefined (same as the omitted wire field on the
//!   live SSE path).
//!
//! NOTE: this is an in-memory read only — mid-run rows are NOT in
//! llm_history yet (only the Phase 1 placeholder envelope is), so
//! reading from the DB here would always return no rows.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const helpers = @import("helpers");
const ai_mod = nalarcore.ai_mod;
const subagent_progress = ai_mod.subagent_progress;

/// Get the live snapshot for one spawn_sub_agent batch.
pub fn subAgentProgressGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const tool_call_id = req.params.get("tool_call_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "tool_call_id required" }) });
    };
    if (tool_call_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "tool_call_id required" }) });
    }

    const rows = try subagent_progress.getSnapshot(allocator, tool_call_id);

    // Build the JSON body manually — `data` must be a pre-serialized
    // JSON string (see worker_get.zig / stream_get.zig pattern), not
    // an anonymous struct. Strings go through std.json.fmt so
    // LLM-supplied agent_names are always valid JSON strings.
    // `body` is arena-owned (freed at request end — do NOT free here).
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(allocator, "{{\"tool_call_id\":{f},\"progress\":[", .{std.json.fmt(tool_call_id, .{})});
    for (rows, 0..) |row, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.print(allocator, "{{\"agent_name\":{f},\"status\":\"{s}\",\"agent_index\":{},\"total_agents\":{},\"subagent_session_id\":{f},\"elapsed_ms\":{}}}", .{
            std.json.fmt(row.agent_name, .{}),
            row.status.toStr(),
            row.agent_index,
            row.total_agents,
            std.json.fmt(row.subagent_session_id, .{}),
            row.elapsed_ms,
        });
    }
    try buf.appendSlice(allocator, "]}");
    const body = try buf.toOwnedSlice(allocator);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = body,
    });
}

// ===== Tests merged from subagent_progress_get_test.zig (2026-09-11 flatten) =====
// Static-contract tests for the live spawn-batch snapshot endpoint
// (`subagent_progress_get.zig`, task_1788505292766_1 —
// spawn-subagent-refresh-persist).
// 
// Why this file exists
// ────────────────────
// Progress events are SSE-ephemeral: a page refresh mid-run wipes
// ChatView's `subAgentProgressMap` with no replay. The fix:
// `GET /api/subagent/progress/:tool_call_id` returns
// `{ tool_call_id, progress[] }` from the in-memory
// `subagent_progress.zig` registry, and `loadChatHistory` rehydrates
// the map for placeholder rows.
// 
// These contracts are enforced by static substring checks (matching
// the sibling `stream_get_test.zig` pattern). Wire behaviour is
// covered by `tests/functional/subagent_refresh_test.py`.

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/subagent_progress_get.zig";
const SNAPSHOT_PATH = "src/agentic_loop/subagent_progress.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/http_routes.zig";
const TUI_TEST_RUNNER_PATH = "src/ai_workflow/tui/test_runner.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler reads from the subagent_progress registry ────

test "subagent_progress_get handler calls subagent_progress.getSnapshot" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // If the handler stopped reading the registry, the endpoint would
    // always report progress=[] and refresh-rehydrate would silently
    // break (Task 0 "starting…" fallback forever, no live rows).
    if (std.mem.indexOf(u8, source, "getSnapshot") == null) {
        std.debug.print(
            "\n!! {s} does not call subagent_progress.getSnapshot !!\n" ++
                "   The snapshot contract is broken: the handler must\n" ++
                "   serve the progress array from the in-memory\n" ++
                "   registry, not from llm_history (mid-run rows are\n" ++
                "   NOT persisted yet).\n",
            .{HANDLER_PATH},
        );
        return error.SnapshotNotCalled;
    }
}

// ─── Contract 2: empty tool_call_id is rejected with 400 ──────────────

test "subagent_progress_get handler guards empty tool_call_id with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "tool_call_id required") == null) {
        std.debug.print(
            "\n!! {s} does not guard an empty tool_call_id !!\n" ++
                "   Restore:\n" ++
                "     if (tool_call_id.len == 0) return res.jsonResponse(.{{ .status_code = 400, ... \"tool_call_id required\" }});\n",
            .{HANDLER_PATH},
        );
        return error.ToolCallIdGuardMissing;
    }
}

// ─── Contract 3: response carries tool_call_id + progress fields ──────

test "subagent_progress_get handler responds with tool_call_id + progress" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler builds the JSON body via print, so the Zig source
    // contains the ESCAPED literals `\"tool_call_id\":` /
    // `\"progress\":` / `\"agent_name\":` / `\"status\":`.
    if (std.mem.indexOf(u8, source, "\\\"tool_call_id\\\":") == null or
        std.mem.indexOf(u8, source, "\\\"progress\\\":") == null or
        std.mem.indexOf(u8, source, "\\\"agent_name\\\":") == null or
        std.mem.indexOf(u8, source, "\\\"status\\\":") == null)
    {
        std.debug.print(
            "\n!! {s} response shape missing tool_call_id/progress keys !!\n" ++
                "   The frontend api.getSubAgentProgress() expects\n" ++
                "   an object with tool_call_id and progress[] fields.\n",
            .{HANDLER_PATH},
        );
        return error.ResponseShapeBroken;
    }
}

// ─── Contract 4: mod.zig re-exports the handler ───────────────────────

test "http_handlers mod re-exports subAgentProgressGetHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "subAgentProgressGetHandler") == null) {
        std.debug.print(
            "\n!! {s} does not re-export subAgentProgressGetHandler !!\n" ++
                "   main.zig references ai_mod.http_handlers.subAgentProgressGetHandler;\n" ++
                "   without the re-export the route registration fails to compile.\n" ++
                "   Restore:\n" ++
                "     pub const subAgentProgressGetHandler = @import(\"subagent_progress_get.zig\").subAgentProgressGetHandler;\n",
            .{MOD_PATH},
        );
        return error.HandlerNotReExported;
    }
}

// ─── Contract 5: route registered in main.zig ─────────────────────────

test "main.zig registers GET subagent/progress/:tool_call_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // Fresh `/api/subagent/...` prefix: no sibling `:param` routes
    // exist under it, so no shadowing risk — but pin the exact
    // registration so a future refactor can't silently drop it.
    const progress_route = "authed.get(\"/api/subagent/progress/:tool_call_id\", ai_mod.http_handlers.subAgentProgressGetHandler)";

    if (std.mem.indexOf(u8, source, progress_route) == null) {
        std.debug.print(
            "\n!! {s} does not register the subagent progress GET route !!\n" ++
                "   Restore:\n" ++
                "     {s}\n" ++
                "   (immediately after the stream GET registration).\n",
            .{ MAIN_PATH, progress_route },
        );
        return error.ProgressRouteMissing;
    }
}

// ─── Contract 6: registry exposes getSnapshot ─────────────────────────

test "subagent_progress exposes getSnapshot" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, SNAPSHOT_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn getSnapshot(") == null) {
        std.debug.print(
            "\n!! {s} does not expose getSnapshot !!\n" ++
                "   The GET handler reads the registry through it.\n",
            .{SNAPSHOT_PATH},
        );
        return error.GetSnapshotMissing;
    }
}

// ─── Contract 7: tui test_runner registers this file ─────────────────

test "tui test_runner registers subagent_progress_get" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TUI_TEST_RUNNER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "subagent_progress_get.zig") == null) {
        std.debug.print(
            "\n!! {s} does not register subagent_progress_get.zig !!\n" ++
                "   Without the import, zig build test never runs these contracts.\n",
            .{TUI_TEST_RUNNER_PATH},
        );
        return error.TestNotRegistered;
    }
}
