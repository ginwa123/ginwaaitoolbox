//! Static regression check for the SSE session event_type_name
//! mapping.
//!
//! Why this file exists
//! ────────────────────
//! The backend has TWO emitters that share the same
//! `OnEventInputSessions.action` → SSE `event:` name mapping:
//!   - src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig
//!     (serves the workflow-driven rename cascade via
//!      update_session_name.zig)
//!   - src/ai_workflow/tui/on_event_sent.zig
//!     (serves the llm_history.zig-driven unattended flag + finish
//!      reason updates; also used by session_create.zig for the
//!      initial created event)
//!
//! Pre-fix, both files had the SAME bug pattern: the if/else
//! cascade that picks the wire-format `event_type_name` only
//! knew about `created` and `deleted`, falling through to
//! `"session_unknown"` for any other action (including the
//! common `"updated"` case). The frontend's
//! `createUnifiedSseConnection` only pre-registers
//! `session_created` and `session_deleted` in additionalEventTypes
//! (api/index.ts:2925-2926), so the browser's EventSource dropped
//! the `session_unknown` event on the floor before the JS handler
//! ever saw it.
//!
//! Result: the auto-rename-on-first-message cascade and the
//! unattended-mode toggle both silently failed to update the
//! sidebar task row. The user had to refresh to see the new
//! name. See task_1786507100896 for the user report.
//!
//! These tests pin the wire-format contract: both files MUST
//! contain the `"updated"` → `"session_updated"` mapping in the
//! event_type_name if/else. A regression that drops the branch
//! (or renames it to `session_unknown`) fails the test.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const SSE_ON_EVENT_SEND_SESSION_PATH =
    "src/ai_workflow/tui/agentic_loop/sse_on_event_send_session.zig";
const ON_EVENT_SENT_PATH = "src/ai_workflow/tui/on_event_sent.zig";

/// Read a source file from disk, normalising CRLF → LF.
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

/// Extract the body of the `onEventSendSessions` function from a
/// source file. We find the `pub fn onEventSendSessions(` signature
/// and walk forward until the next `pub fn ` or end-of-file — the
/// slice between is the function body (newline-delimited, same
/// pattern as task_update_test.zig).
fn extractOnEventSendSessionsBody(source: []const u8) []const u8 {
    const sig = "pub fn onEventSendSessions(";
    const sig_idx = std.mem.indexOf(u8, source, sig) orelse {
        std.debug.print(
            "\n!! Could not find `pub fn onEventSendSessions(` !!\n",
            .{},
        );
        return source; // fall through — the substring check below will fail
    };
    const after_sig = sig_idx + sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    return source[after_sig..next_pub_fn];
}

// ─── Contract 1: agentic_loop emitter maps "updated" → "session_updated" ────

test "sse_on_event_send_session.zig maps action='updated' to event_type 'session_updated'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, SSE_ON_EVENT_SEND_SESSION_PATH);
    defer allocator.free(source);

    const body = extractOnEventSendSessionsBody(source);

    // The mapping must be present. We check for the substring
    // `"updated"))\n        "session_updated"` — the `))` closes both
    // the inner `eql(u8, ..., "updated")` argument AND the outer
    // `if (...)` condition, then a newline + 8 spaces + the return
    // value `"session_updated"`. A regression to "session_unknown"
    // fails this test.
    const needle =
        "\"updated\"))\n" ++
        "        \"session_updated\"";
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print(
            "\n!! {s} does not map action='updated' to event_type='session_updated' !!\n" ++
                "   The pre-fix bug mapped it to 'session_unknown' (the if/else\n" ++
                "   fallthrough), which the frontend's additionalEventTypes doesn't\n" ++
                "   register, so the browser's EventSource drops the event. Result:\n" ++
                "   sidebar task rows never update from 'New Chat' to the LLM-generated\n" ++
                "   name until a manual page refresh.\n" ++
                "   Fix: add an `else if (std.mem.eql(u8, input.action, \"updated\"))`\n" ++
                "   branch to the event_type_name if/else that returns\n" ++
                "   \"session_updated\".\n" ++
                "   See task_1786507100896 and the parallel test below.\n",
            .{SSE_ON_EVENT_SEND_SESSION_PATH},
        );
        return error.SessionUpdatedMissing;
    }
}

// ─── Contract 2: on_event_sent emitter maps "updated" → "session_updated" ───

test "on_event_sent.zig maps action='updated' to event_type 'session_updated'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ON_EVENT_SENT_PATH);
    defer allocator.free(source);

    const body = extractOnEventSendSessionsBody(source);

    const needle =
        "\"updated\"))\n" ++
        "        \"session_updated\"";
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print(
            "\n!! {s} does not map action='updated' to event_type='session_updated' !!\n" ++
                "   Same bug class as the agentic_loop emitter above — see that test's\n" ++
                "   failure message for the full context.\n",
            .{ON_EVENT_SENT_PATH},
        );
        return error.SessionUpdatedMissing;
    }
}
