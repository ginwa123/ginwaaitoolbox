//! Static-contract tests for the live spawn-batch snapshot endpoint
//! (`subagent_progress_get.zig`, task_1788505292766_1 —
//! spawn-subagent-refresh-persist).
//!
//! Why this file exists
//! ────────────────────
//! Progress events are SSE-ephemeral: a page refresh mid-run wipes
//! ChatView's `subAgentProgressMap` with no replay. The fix:
//! `GET /api/subagent/progress/:tool_call_id` returns
//! `{ tool_call_id, progress[] }` from the in-memory
//! `subagent_progress.zig` registry, and `loadChatHistory` rehydrates
//! the map for placeholder rows.
//!
//! These contracts are enforced by static substring checks (matching
//! the sibling `stream_get_test.zig` pattern). Wire behaviour is
//! covered by `tests/functional/subagent_refresh_test.py`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/subagent_progress_get.zig";
const SNAPSHOT_PATH = "src/agentic_loop/subagent_progress.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
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
    const progress_route = "gs.router.get(\"/api/subagent/progress/:tool_call_id\", ai_mod.http_handlers.subAgentProgressGetHandler)";

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

test "tui test_runner registers subagent_progress_get_test" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TUI_TEST_RUNNER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "subagent_progress_get_test.zig") == null) {
        std.debug.print(
            "\n!! {s} does not register subagent_progress_get_test.zig !!\n" ++
                "   Without the import, zig build test never runs these contracts.\n",
            .{TUI_TEST_RUNNER_PATH},
        );
        return error.TestNotRegistered;
    }
}
