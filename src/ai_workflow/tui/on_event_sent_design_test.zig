//! Static regression checks for the design SSE emitter module.
//!
//! Why this file exists
//! ────────────────────
//! The Design Mode feature (plan: `2026-07-05-design-mode.md`)
//! introduces 2 SSE event families: `design_page_updated` and
//! `design_page_deleted`. Each handler that mutates design pages
//! (Task 2.5 PUT, Task 2.6 DELETE, and the future LLM tools in
//! Chunk 3) MUST emit the corresponding event through
//! `on_event_sent_design` so other connected clients refresh.
//!
//! These tests lock the contract by source-grep, mirroring the
//! static-contract pattern used for other event-emitter files in
//! this codebase (see `kanban_model_test.zig` and
//! `tool_registry_*_test.zig` for the same shape).
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.2).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const EMITTER_PATH = "src/ai_workflow/tui/on_event_sent_design.zig";
const TYPES_PATH = "src/ai_workflow/tui/on_event_design.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even
/// when the file was checked out on Windows with autocrlf=true.
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

test "on_event_sent_design exports onEventSendDesignPageUpdated" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, EMITTER_PATH);
    defer allocator.free(source);

    // The PUT handler (Task 2.5) and the future `set_design_page`
    // tool (Chunk 3) call this function by name. If it disappears
    // the handlers fail to compile — but this test catches the
    // removal BEFORE the handler is migrated to a different API.
    if (std.mem.indexOf(u8, source, "onEventSendDesignPageUpdated") == null) {
        std.debug.print(
            "\n!! {s} does not export `onEventSendDesignPageUpdated` !!\n" ++
                "   PUT handler (design_pages_update.zig) and the future\n" ++
                "   `set_design_page` tool both call this function.\n",
            .{EMITTER_PATH},
        );
        return error.OnEventSendDesignPageUpdatedMissing;
    }
}

test "on_event_sent_design exports onEventSendDesignPageDeleted" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, EMITTER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "onEventSendDesignPageDeleted") == null) {
        std.debug.print(
            "\n!! {s} does not export `onEventSendDesignPageDeleted` !!\n" ++
                "   DELETE handler (design_pages_delete.zig) and the future\n" ++
                "   `delete_design_page` tool both call this function.\n",
            .{EMITTER_PATH},
        );
        return error.OnEventSendDesignPageDeletedMissing;
    }
}

test "on_event_design defines DesignPageUpdatedData payload" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TYPES_PATH);
    defer allocator.free(source);

    // The payload struct must carry the fields the frontend expects:
    //   action, workspace_id, item_id, page (with id/name/html/...).
    // Lock the most diagnostic fields by name — `action`,
    // `workspace_id`, `page` — so a future refactor that drops
    // `page` (and breaks the frontend's patch-in-place logic) fails.
    const need: []const []const u8 = &.{
        "DesignPageUpdatedData",
        "action",
        "workspace_id",
        "item_id",
        "page",
    };
    for (need) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} is missing field/struct `{s}` !!\n" ++
                    "   The design_page_updated payload contract is broken.\n",
                .{ TYPES_PATH, needle },
            );
            return error.PayloadFieldMissing;
        }
    }
}

test "on_event_design defines DesignPageDeletedData payload" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TYPES_PATH);
    defer allocator.free(source);

    const need: []const []const u8 = &.{
        "DesignPageDeletedData",
        "workspace_id",
        "item_id",
        "page_id",
    };
    for (need) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} is missing field/struct `{s}` !!\n" ++
                    "   The design_page_deleted payload contract is broken.\n",
                .{ TYPES_PATH, needle },
            );
            return error.PayloadFieldMissing;
        }
    }
}

test "on_event_sent_design emits via event_bus.emit" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, EMITTER_PATH);
    defer allocator.free(source);

    // Both emitters MUST dispatch through `event_bus.emit(SseEvent, ...)`
    // so the SSE manager routes them to subscribed clients. We assert
    // BOTH the routing function name and the SseEvent type reference.
    if (std.mem.indexOf(u8, source, "event_bus.emit") == null) {
        std.debug.print(
            "\n!! {s} does not call `event_bus.emit` !!\n" ++
                "   Both emitters must dispatch via the shared event_bus.\n",
            .{EMITTER_PATH},
        );
        return error.EventBusEmitMissing;
    }
    if (std.mem.indexOf(u8, source, "SseEvent") == null) {
        std.debug.print(
            "\n!! {s} does not reference `SseEvent` !!\n" ++
                "   Both emitters must construct an `SseEvent` for the bus.\n",
            .{EMITTER_PATH},
        );
        return error.SseEventMissing;
    }
}