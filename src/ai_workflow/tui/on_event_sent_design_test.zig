//! Static-contract regression tests for the design-mode SSE event
//! emitter file. The Chunk 2 spec requires at least 1 static-contract
//! test that greps the source for `event_bus.emit` and
//! `"design_element"`. The tests below also lock in the granular
//! wire-format event names (`design_element_created` / `_updated` /
//! `_deleted`) so a future refactor can't silently regress to a
//! single name across all three emitters (which would break
//! frontend EventSource dispatch — see project memory
//! `browser-eventsource-named-events.md`).
//!
//! All tests read `on_event_sent_design.zig` as text and assert the
//! presence / absence of substrings. This is the project convention
//! for files that emit through `event_bus.emit` (no test singleton
//! is required, no fake server is required — just check the contract
//! is wired in the source).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const ON_EVENT_SENT_DESIGN_PATH = "src/ai_workflow/tui/on_event_sent_design.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

test "on_event_sent_design.zig emits via event_bus.emit" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_DESIGN_PATH);
    defer testing.allocator.free(source);

    // The Chunk 2 spec requires the source to contain `event_bus.emit`
    // (the event_bus field on the singleton is named `event_bus` and
    // `emit` is its generic pubsub method).
    if (std.mem.indexOf(u8, source, "event_bus.emit") == null) {
        std.debug.print("!! on_event_sent_design.zig does not call event_bus.emit !!\n", .{});
        return error.EventBusEmitMissing;
    }
}

test "on_event_sent_design.zig routes on the design_element key" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_DESIGN_PATH);
    defer testing.allocator.free(source);

    // All three emitters must route on the same event_bus key
    // ("design_element") so the frontend listener registered with
    // `event_bus.subscribe(SseEvent, "design_element", handler)` receives
    // all three event variants. The key is hard-coded — assert it
    // appears at least 3 times (once per emitter, plus possibly in
    // the docstring).
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, source, idx, "\"design_element\"")) |pos| {
        count += 1;
        idx = pos + "\"design_element\"".len;
    }
    if (count < 3) {
        std.debug.print("!! on_event_sent_design.zig uses \"design_element\" routing key only {d} times (expected >= 3) !!\n", .{count});
        return error.DesignElementKeyMissing;
    }
}

test "on_event_sent_design.zig sets granular event_type names" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_DESIGN_PATH);
    defer testing.allocator.free(source);

    // The wire-format `event:` line must carry the granular name so
    // the browser's EventSource can dispatch by name. All three
    // names must be present in the source.
    const has_created = std.mem.indexOf(u8, source, "\"design_element_created\"") != null;
    const has_updated = std.mem.indexOf(u8, source, "\"design_element_updated\"") != null;
    const has_deleted = std.mem.indexOf(u8, source, "\"design_element_deleted\"") != null;
    if (!has_created or !has_updated or !has_deleted) {
        std.debug.print(
            "!! on_event_sent_design.zig missing granular event_type: created={}, updated={}, deleted={} !!\n",
            .{ has_created, has_updated, has_deleted },
        );
        return error.GranularEventTypeMissing;
    }
}

test "on_event_sent_design.zig exposes 3 pub emitter functions" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_DESIGN_PATH);
    defer testing.allocator.free(source);

    // The Chunk 2 spec requires 3 public emitter functions, one per
    // wire event. Each must start with `pub fn` and use the
    // `onEventSendDesignElement` prefix.
    const has_created_fn = std.mem.indexOf(u8, source, "pub fn onEventSendDesignElementCreated") != null;
    const has_updated_fn = std.mem.indexOf(u8, source, "pub fn onEventSendDesignElementUpdated") != null;
    const has_deleted_fn = std.mem.indexOf(u8, source, "pub fn onEventSendDesignElementDeleted") != null;
    if (!has_created_fn or !has_updated_fn or !has_deleted_fn) {
        std.debug.print(
            "!! on_event_sent_design.zig missing emitter function: created={}, updated={}, deleted={} !!\n",
            .{ has_created_fn, has_updated_fn, has_deleted_fn },
        );
        return error.EmitterFunctionMissing;
    }
}

test "on_event_sent_design.zig uses the nalarcore singleton" {
    const source = try readSource(testing.allocator, ON_EVENT_SENT_DESIGN_PATH);
    defer testing.allocator.free(source);

    // The emitters must fetch the singleton via nalarcore.getSingleton()
    // (the same pattern as onEventSendKanbanColumn in
    // on_event_sent_kanban.zig). When no singleton is initialized
    // (e.g. in unit tests), the function returns silently — so the
    // build can compile and run without a GinwaServer.
    if (std.mem.indexOf(u8, source, "nalarcore.getSingleton()") == null) {
        std.debug.print("!! on_event_sent_design.zig does not call nalarcore.getSingleton() !!\n", .{});
        return error.GetSingletonMissing;
    }
}
