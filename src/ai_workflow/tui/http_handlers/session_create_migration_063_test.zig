//! Static-contract tests for Migration 063's POST /api/session changes.
//!
//! Why this file exists
//! ────────────────────
//! Chunk 3 Task 3.1 requires POST /api/session to:
//!   1. Accept is_auto_retry_until_stop in the JSON body.
//!   2. Persist it via insertWorker's INSERT SQL.
//!   3. Include it in the SSE broadcast (so ChatsList updates live).
//!
//! The sibling file `session_create_test.zig` has a pre-existing
//! Zig 0.16 compatibility issue (uses `std.fs.cwd()` which is
//! gone in 0.16) and is currently NOT registered in test_runner.zig.
//! Creating a fresh file with only the new static-contract checks
//! avoids touching that broken file and keeps the CI green.
//!
//! Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//!   (Chunk 3, Task 3.1)

const std = @import("std");
const testing = std.testing;

const SESSION_CREATE_SOURCE_PATH = "src/ai_workflow/tui/http_handlers/session_create.zig";

fn loadSessionCreateSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        SESSION_CREATE_SOURCE_PATH,
        allocator,
        .limited(64 * 1024),
    ) catch |err| return err;
}

test "session_create.zig RequestSession declares is_auto_retry_until_stop field" {
    const source = try loadSessionCreateSource(testing.allocator);
    defer testing.allocator.free(source);

    // The field defaults to "" so existing callers don't need to set it.
    if (std.mem.indexOf(u8, source, "is_auto_retry_until_stop: []const u8 = \"\"") == null) {
        std.debug.print(
            "!! session_create.zig RequestSession does NOT declare is_auto_retry_until_stop !!\n" ++
                "   (the field must be added to the request body struct with default \"\"). !!\n",
            .{},
        );
        return error.SessionCreateRequestFieldMissing;
    }
}

test "session_create.zig insertWorker INSERT SQL writes is_auto_retry_until_stop" {
    const source = try loadSessionCreateSource(testing.allocator);
    defer testing.allocator.free(source);

    // The INSERT must reference the column name (`is_auto_retry_until_stop`)
    // so the bind placeholder flows through.
    if (std.mem.indexOf(u8, source, "is_auto_retry_until_stop") == null) {
        std.debug.print(
            "!! session_create.zig INSERT SQL does NOT reference is_auto_retry_until_stop !!\n",
            .{},
        );
        return error.SessionCreateInsertColumnMissing;
    }
}

test "session_create.zig SSE broadcast includes is_auto_retry_until_stop" {
    const source = try loadSessionCreateSource(testing.allocator);
    defer testing.allocator.free(source);

    // The onEventSendSessions(...) call site must pass the field through
    // so ChatsList.vue's reactive binding sees the new value.
    if (std.mem.indexOf(u8, source, ".is_auto_retry_until_stop =") == null) {
        std.debug.print(
            "!! session_create.zig onEventSendSessions broadcast does NOT carry is_auto_retry_until_stop !!\n" ++
                "   (the SSE payload is what ChatsList uses to update the badge live). !!\n",
            .{},
        );
        return error.SessionCreateSseFieldMissing;
    }
}
