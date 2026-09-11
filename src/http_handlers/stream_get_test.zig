//!
//! Static-contract tests for the in-flight stream snapshot endpoint
//! (`stream_get.zig`, task_1787673548905_0 — stream-resume-on-reselect).
//!
//! Why this file exists
//! ────────────────────
//! When the user closes/re-selects a chat session mid-stream, ChatView
//! drops its `streaming-*` placeholder and resets `streamingContent`.
//! The backend keeps streaming, but the re-mounted view has no way to
//! recover the partial text. The fix: `GET /api/llm/session/:id/stream`
//! returns `{ active: bool, content: string }` from the in-memory
//! `stream_snapshot.zig` registry, and ChatView resumes from it.
//!
//! These contracts are enforced by static substring checks (matching
//! the sibling `tasks_get_test.zig` pattern). Wire behaviour is covered
//! by `tests/functional/llm_stream_get_test.py`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/stream_get.zig";
const SNAPSHOT_PATH = "src/agentic_loop/stream_snapshot.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
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

// ─── Contract 1: handler reads from the stream_snapshot registry ──────────

test "stream_get handler calls stream_snapshot.getSnapshot" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // If the handler stopped reading the registry, the endpoint would
    // always report idle and the frontend resume would silently break.
    if (std.mem.indexOf(u8, source, "getSnapshot") == null) {
        std.debug.print(
            "\n!! {s} does not call stream_snapshot.getSnapshot !!\n" ++
                "   The snapshot contract is broken: the handler must\n" ++
                "   serve the active/content pair from the in-memory\n" ++
                "   registry, not from llm_history (the in-flight turn\n" ++
                "   is NOT persisted yet).\n",
            .{HANDLER_PATH},
        );
        return error.SnapshotNotCalled;
    }
}

// ─── Contract 2: empty session_id is rejected with 400 ────────────────────

test "stream_get handler guards empty session_id with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "session_id required") == null) {
        std.debug.print(
            "\n!! {s} does not guard an empty session_id !!\n" ++
                "   Restore:\n" ++
                "     if (session_id.len == 0) return res.jsonResponse(.{{ .status_code = 400, ... \"session_id required\" }});\n",
            .{HANDLER_PATH},
        );
        return error.SessionIdGuardMissing;
    }
}

// ─── Contract 3: response carries both active + content fields ────────────

test "stream_get handler responds with active + content" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler builds the JSON body via allocPrint, so the Zig
    // source contains the ESCAPED literals `\"active\":` / `\"content\":`.
    if (std.mem.indexOf(u8, source, "\\\"active\\\":") == null or
        std.mem.indexOf(u8, source, "\\\"content\\\":") == null)
    {
        std.debug.print(
            "\n!! {s} response shape missing active/content keys !!\n" ++
                "   The frontend api.getStreamSnapshot() expects\n" ++
                "   an object with active and content fields.\n",
            .{HANDLER_PATH},
        );
        return error.ResponseShapeBroken;
    }
}

// ─── Contract 4: mod.zig re-exports the handler ───────────────────────────

test "http_handlers mod re-exports streamGetHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "streamGetHandler") == null) {
        std.debug.print(
            "\n!! {s} does not re-export streamGetHandler !!\n" ++
                "   main.zig references ai_mod.http_handlers.streamGetHandler;\n" ++
                "   without the re-export the route registration fails to compile.\n" ++
                "   Restore:\n" ++
                "     pub const streamGetHandler = @import(\"stream_get.zig\").streamGetHandler;\n",
            .{MOD_PATH},
        );
        return error.HandlerNotReExported;
    }
}

// ─── Contract 5: route registered AFTER /messages + /queue_messages ───────

test "main.zig registers GET session/:id/stream after sibling routes" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // matchRoute walks routes in registration order. `/api/llm/session`
    // (list) is a PREFIX of `/api/llm/session/:id/stream`; registering
    // the specific routes after the list route is the existing pattern.
    // We pin the new route to sit with its siblings so a future reorder
    // that puts the bare list route last doesn't silently shadow it.
    const messages_route = "gs.router.get(\"/api/llm/session/:session_id/messages\", ai_mod.http_handlers.sessionMessagesHandler)";
    const stream_route = "gs.router.get(\"/api/llm/session/:session_id/stream\", ai_mod.http_handlers.streamGetHandler)";

    _ = std.mem.indexOf(u8, source, messages_route) orelse {
        std.debug.print("\n!! messages route missing from {s} !!\n", .{MAIN_PATH});
        return error.MessagesRouteMissing;
    };
    const stream_idx = std.mem.indexOf(u8, source, stream_route) orelse {
        std.debug.print(
            "\n!! {s} does not register the stream GET route !!\n" ++
                "   Restore:\n" ++
                "     {s}\n" ++
                "   (immediately after the queue_messages registration).\n",
            .{ MAIN_PATH, stream_route },
        );
        return error.StreamRouteMissing;
    };
    if (stream_idx < (std.mem.indexOf(u8, source, messages_route).?)) {
        std.debug.print(
            "\n!! stream GET route registered BEFORE the messages route in {s} !!\n" ++
                "   matchRoute walks routes in registration order; keep the\n" ++
                "   sibling ordering stable (see router.zig route-order rule).\n",
            .{MAIN_PATH},
        );
        return error.RouteOrderShadowing;
    }
}

// ─── Contract 6: registry exposes getSnapshot with the expected signature ─

test "stream_snapshot exposes getSnapshot" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, SNAPSHOT_PATH);
    defer allocator.free(source);

    const sig = "pub fn getSnapshot(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `getSnapshot` !!\n" ++
                "   The registry lookup function is missing, so the handler\n" ++
                "   has no way to read the in-flight buffer.\n" ++
                "   Restore:\n" ++
                "     pub fn getSnapshot(allocator, session_id) !Snapshot\n",
            .{SNAPSHOT_PATH},
        );
        return error.GetSnapshotFnMissing;
    }
}

// ─── Contract 7: tui test_runner registers this test file ─────────────────

test "tui test_runner registers stream_get_test" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TUI_TEST_RUNNER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "stream_get_test.zig") == null) {
        std.debug.print(
            "\n!! {s} does not import stream_get_test.zig !!\n" ++
                "   Without the import these contracts never run.\n" ++
                "   Restore:\n" ++
                "     _ = @import(\"../../http_handlers/stream_get_test.zig\");\n",
            .{TUI_TEST_RUNNER_PATH},
        );
        return error.TestNotRegistered;
    }
}
