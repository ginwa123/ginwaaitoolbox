//! Static regression checks for the `/api/events` unified SSE handler.
//!
//! Why this file exists
//! ────────────────────
//! The unified handler is the single entry point for ALL server-pushed
//! events. Any regression in the channel parser or the routing-key
//! subscriptions silently drops events for the entire frontend, so
//! these contracts are pinned via static source checks (the same
//! pattern as `kanban_events_sse_test.zig`).
//!
//! Plan: docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/unified_events_sse.zig";
const MAIN_PATH = "src/main.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler exists and defines the public fn ─────────────────

test "unified_events_sse.zig exists and defines pub fn unifiedEventsStreamHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn unifiedEventsStreamHandler") == null) {
        std.debug.print(
            "\n!! {s} does not define pub fn unifiedEventsStreamHandler !!\n", .{HANDLER_PATH},
        );
        return error.HandlerFunctionMissing;
    }
}

// ─── Contract 2: all 6 channel tokens are recognized ─────────────────────

test "unified_events_sse.zig recognizes all 6 channel tokens" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    const required_tokens = .{
        // workers branch
        "\"workers\"",
        // sessions branch
        "\"sessions\"",
        // kanban branch (subscribes BOTH kanban_column + kanban_task)
        "\"kanban\"",
        "\"kanban_column\"",
        "\"kanban_task\"",
        // design_element branch (design-mode v6, Chunk 2 SSE)
        "eql(u8, token, \"design_element\")",
        // bare 'llm' branch
        "eql(u8, token, \"llm\")",
        // bare 'queue' branch
        "eql(u8, token, \"queue\")",
    };

    inline for (required_tokens) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} is missing the substring {s} !!\n", .{ HANDLER_PATH, needle },
            );
            return error.ChannelTokenMissing;
        }
    }
}

// ─── Contract 3: handler sends the `connected` handshake ─────────────────

test "unified_events_sse.zig sends the connected handshake" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The verbatim byte sequence pinned by sse_handshake_test.zig:61-64.
    const handshake = "event: connected\\ndata: {\\\"connected\\\": true}\\n\\n";
    if (std.mem.indexOf(u8, source, handshake) == null) {
        std.debug.print(
            "\n!! {s} does not contain the SSE connected handshake !!\n", .{HANDLER_PATH},
        );
        return error.ConnectedHandshakeMissing;
    }
}

// ─── Contract 4: route is registered in main.zig ─────────────────────────

test "/api/events is registered in src/main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "/api/events") == null) {
        std.debug.print(
            "\n!! {s} does not register the /api/events route !!\n", .{MAIN_PATH},
        );
        return error.RouteRegistrationMissing;
    }
}

// ─── Behavioral tests for parseChannels ────────────────────────────────
//
// Plan Reviewer finding #3: the 4 static contracts above only verify
// the file's shape, not the parser's correctness. A typo in the
// bare `llm`/`queue` token names, or an off-by-one in the kanban
// expansion would silently drop events in production. These
// behavioral tests pin the parser contract.
//
// To make `parseChannels` testable from this file, the production
// code must expose it as `pub fn` (currently `fn`). Chunk 1.1's
// implementation step promotes it to `pub`.

const parseChannels = @import("unified_events_sse.zig").parseChannels;

test "parseChannels: workers → 1 routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "workers");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
}

test "parseChannels: sessions,kanban → 3 routing keys (kanban expands)" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "sessions,kanban");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), list.routing_keys.len);
    try testing.expectEqualStrings("sessions", list.routing_keys[0]);
    try testing.expectEqualStrings("kanban_column", list.routing_keys[1]);
    try testing.expectEqualStrings("kanban_task", list.routing_keys[2]);
}

test "parseChannels: llm:<sid> → error.UnknownChannel (superseded by bare 'llm')" {
    try testing.expectError(error.UnknownChannel, parseChannels(testing.allocator, "llm:chat-123"));
}

test "parseChannels: queue:<sid> → error.UnknownChannel (superseded by bare 'queue')" {
    try testing.expectError(error.UnknownChannel, parseChannels(testing.allocator, "queue:chat-abc"));
}

test "parseChannels: bare 'llm' → central 'llm' routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "llm");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("llm", list.routing_keys[0]);
}

test "parseChannels: bare 'queue' → central 'queue' routing key" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("queue", list.routing_keys[0]);
}

test "parseChannels: mixed 5 channels (bare llm+queue) → 6 routing keys (kanban expands)" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator,
        "workers,sessions,kanban,llm,queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 6), list.routing_keys.len);
    // workers, sessions, kanban_column, kanban_task, llm, queue (in registration order)
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
    try testing.expectEqualStrings("sessions", list.routing_keys[1]);
    try testing.expectEqualStrings("kanban_column", list.routing_keys[2]);
    try testing.expectEqualStrings("kanban_task", list.routing_keys[3]);
    try testing.expectEqualStrings("llm", list.routing_keys[4]);
    try testing.expectEqualStrings("queue", list.routing_keys[5]);
}

test "parseChannels: multiple bare tokens (llm+queue repeated) → 2 keys" {
    const allocator = testing.allocator;
    // Bare 'llm' and 'queue' tokens each register once under their
    // central key. The ChannelList does NOT deduplicate (see the
    // ChannelList docstring); the SSE event_bus handles duplicate
    // subscribers without error.
    const list = try parseChannels(allocator,
        "llm,llm,queue,queue");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 4), list.routing_keys.len);
    try testing.expectEqualStrings("llm", list.routing_keys[0]);
    try testing.expectEqualStrings("llm", list.routing_keys[1]);
    try testing.expectEqualStrings("queue", list.routing_keys[2]);
    try testing.expectEqualStrings("queue", list.routing_keys[3]);
}

test "parseChannels: empty string → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, ""));
}

test "parseChannels: whitespace-only → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, "   "));
}

test "parseChannels: only commas → error.MissingChannels" {
    const allocator = testing.allocator;
    try testing.expectError(error.MissingChannels, parseChannels(allocator, ",,,"));
}

test "parseChannels: unknown channel → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "foo"));
}

test "parseChannels: llm: (per-session token removed) → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "llm:"));
}

test "parseChannels: queue: (per-session token removed) → error.UnknownChannel" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "queue:"));
}

test "parseChannels: trims whitespace around tokens" {
    const allocator = testing.allocator;
    const list = try parseChannels(allocator, "  workers , sessions  ");
    defer list.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), list.routing_keys.len);
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
    try testing.expectEqualStrings("sessions", list.routing_keys[1]);
}