//! Static-contract tests for Migration 063's PUT /api/session/:id changes.
//!
//! Chunk 3 Task 3.2 requires PUT to accept + persist
//! `is_auto_retry_until_stop`. Static-contract because the handler needs
//! a live `nalarcore.getSingleton()` to call `updateSessionAutoRetryUntilStop`.
//!
//! Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const testing = std.testing;

const SESSION_UPDATE_SOURCE_PATH = "src/ai_workflow/tui/http_handlers/session_update.zig";

fn loadSessionUpdateSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        SESSION_UPDATE_SOURCE_PATH,
        allocator,
        .limited(64 * 1024),
    ) catch |err| return err;
}

test "session_update.zig RequestSessionUpdate declares is_auto_retry_until_stop field" {
    const source = try loadSessionUpdateSource(testing.allocator);
    defer testing.allocator.free(source);

    // The handler's request struct must include the new field with default ""
    // so existing callers (without the flag) continue to compile.
    if (std.mem.indexOf(u8, source, "is_auto_retry_until_stop: []const u8 = \"\"") == null) {
        std.debug.print(
            "!! session_update.zig RequestSessionUpdate does NOT declare is_auto_retry_until_stop !!\n" ++
                "   (must add the field with default \"\" so existing calls compile). !!\n",
            .{},
        );
        return error.SessionUpdateRequestFieldMissing;
    }
}

test "session_update.zig handler calls updateSessionAutoRetryUntilStop when field is set" {
    const source = try loadSessionUpdateSource(testing.allocator);
    defer testing.allocator.free(source);

    // The handler must thread the field through to
    // `llm_history.updateSessionAutoRetryUntilStop(...)` when the
    // request body includes it.
    if (std.mem.indexOf(u8, source, "updateSessionAutoRetryUntilStop") == null) {
        std.debug.print(
            "!! session_update.zig handler does NOT call updateSessionAutoRetryUntilStop !!\n" ++
                "   (the toggle must persist to the DB so workflow.zig re-reads it). !!\n",
            .{},
        );
        return error.SessionUpdateToggleCallMissing;
    }
}

test "session_update.zig ResponseSessionUpdate includes is_auto_retry_until_stop" {
    const source = try loadSessionUpdateSource(testing.allocator);
    defer testing.allocator.free(source);

    // Response shape must include the field so the frontend's PUT
    // response reflects the new value (ChatsList refreshes from PUT).
    if (std.mem.indexOf(u8, source, "is_auto_retry_until_stop: []const u8") == null) {
        std.debug.print(
            "!! session_update.zig ResponseSessionUpdate does NOT include is_auto_retry_until_stop !!\n",
            .{},
        );
        return error.SessionUpdateResponseFieldMissing;
    }
}
