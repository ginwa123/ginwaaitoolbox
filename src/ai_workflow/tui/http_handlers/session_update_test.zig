//! Static-contract tests for `session_update.zig`.
//!
//! Lock in structural contracts that are hard to assert from behavioural
//! tests: the handler must call the chat-side human-touched stamp helper
//! when a user edits a session field. See plan
//! `docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md`
//! Task 4 for context.
//!
//! The grep needle is constructed via string concatenation so the helper
//! name doesn't appear verbatim in this file's source body — the source
//! itself is what the grep scans (the same trap the session_create tests
//! hit before being masked).

const std = @import("std");
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/session_update.zig";

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

test "session_update.zig calls the chat-side stamp helper on real field edits (Task 4 invariant)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The chat-side stamp helper, defined in `llm_history.zig` (Task 2).
    // Constructed via concatenation so this file's source body does NOT
    // contain the literal name (which would self-match the grep).
    const needle = "updateSessi" ++ "onLastHumanTouchedAt";
    if (!contains(source, needle)) {
        std.debug.print(
            "\n!! {s} does NOT call the chat-side stamp helper !!\n"
            ++ "   session_update.zig must stamp sessions.last_human_touched_at_nano\n"
            ++ "   when the user edits name / profile / unattended toggle, so the\n"
            ++ "   chat sidebar's time pill reflects that the user just touched\n"
            ++ "   this chat. Plan Task 4.\n",
            .{HANDLER_PATH},
        );
        return error.SessionUpdateStampMissing;
    }
}
