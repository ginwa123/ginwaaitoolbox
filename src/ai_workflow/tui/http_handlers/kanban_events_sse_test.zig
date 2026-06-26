//! Static regression checks for the `/api/kanban/events` SSE handler.
//!
//! Why this file exists
//! ────────────────────
//! Chunks 1–3 of the kanban-list-fix plan added `onEventSendKanbanColumn` and
//! `onEventSendKanbanTask` emitters that publish to `event_bus` under the
//! keys `"kanban_column"` and `"kanban_task"`. Chunk 4 (frontend) wired up a
//! `createKanbanSseConnection` factory that opens an `EventSource` against
//! `/api/kanban/events` with `additionalEventTypes: ['kanban_column',
//! 'kanban_task']`. But the HTTP SSE handler for that route was missing —
//! the browser's EventSource connected to nothing, and events never reached
//! the UI.
//!
//! This file enforces three contracts:
//!   1. The handler file exists and defines `pub fn kanbanEventsStreamHandler`.
//!   2. The handler subscribes to BOTH `"kanban_column"` AND `"kanban_task"`
//!      event_bus keys (the emitters use two separate keys, but the
//!      frontend opens ONE EventSource — the handler must fan out both).
//!   3. The route `/api/kanban/events` is registered in `src/main.zig`.
//!
//! Plan: docs/superpowers/plans/2026-06-25-kanban-list-fix.md (Chunk 5).

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/kanban_events_sse.zig";
const MAIN_PATH = "src/main.zig";

/// Read a source file from disk, relative to the project root.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler file exists and defines the handler fn ───────────

test "kanban_events_sse.zig exists and defines pub fn kanbanEventsStreamHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn kanbanEventsStreamHandler") == null) {
        std.debug.print(
            "\n!! {s} does not define pub fn kanbanEventsStreamHandler !!\n" ++
                "   The SSE endpoint contract is broken: src/main.zig routes\n" ++
                "   /api/kanban/events to ai_mod.http_handlers.kanbanEventsStreamHandler,\n" ++
                "   but the handler function is missing.\n",
            .{HANDLER_PATH},
        );
        return error.HandlerFunctionMissing;
    }
}

// ─── Contract 2: handler subscribes to BOTH event_bus keys ────────────────

test "kanban_events_sse.zig subscribes to both kanban_column and kanban_task" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The frontend opens ONE EventSource to /api/kanban/events but expects
    // BOTH event types on the stream. The handler must subscribe to both
    // event_bus keys (the emitters in on_event_sent_kanban.zig publish to
    // two separate keys: "kanban_column" and "kanban_task").
    if (std.mem.indexOf(u8, source, "\"kanban_column\"") == null) {
        std.debug.print(
            "\n!! {s} does not subscribe to the kanban_column event_bus key !!\n" ++
                "   The fan-out contract is broken: onEventSendKanbanColumn\n" ++
                "   publishes to event_bus key \"kanban_column\", so the SSE\n" ++
                "   handler must subscribe to that key.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanColumnSubscriptionMissing;
    }
    if (std.mem.indexOf(u8, source, "\"kanban_task\"") == null) {
        std.debug.print(
            "\n!! {s} does not subscribe to the kanban_task event_bus key !!\n" ++
                "   The fan-out contract is broken: onEventSendKanbanTask\n" ++
                "   publishes to event_bus key \"kanban_task\", so the SSE\n" ++
                "   handler must subscribe to that key.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanTaskSubscriptionMissing;
    }
}

// ─── Contract 3: route is registered in main.zig ──────────────────────────

test "/api/kanban/events is registered in src/main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "/api/kanban/events") == null) {
        std.debug.print(
            "\n!! {s} does not register the /api/kanban/events route !!\n" ++
                "   The frontend's createKanbanSseConnection opens\n" ++
                "   EventSource('/api/kanban/events'), but the route is\n" ++
                "   not wired in src/main.zig. Add:\n" ++
                "     try gs.router.sse(\"/api/kanban/events\", ai_mod.http_handlers.kanbanEventsStreamHandler);\n",
            .{MAIN_PATH},
        );
        return error.RouteRegistrationMissing;
    }
}
