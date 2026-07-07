//! SSE emitters for design-page + design-element mutations.
//!
//! Five event families:
//!   - `design_page_updated`    — fired on POST/PUT /design/pages/:pid
//!     and the `set_design_page` LLM tool.
//!   - `design_page_deleted`    — fired on DELETE /design/pages/:pid.
//!   - `design_element_created` — fired on POST /design/pages/:pid/elements
//!     and the `set_design_element` LLM tool.
//!   - `design_element_updated` — fired on PUT/PATCH move/PATCH resize
//!     /design/pages/:pid/elements/:eid (and the LLM tools).
//!   - `design_element_deleted` — fired on DELETE /design/pages/:pid/elements/:eid.
//!
//! Pattern mirrors `onEventSendKanbanColumn` /
//! `onEventSendKanbanTask` in `on_event_sent_kanban.zig`:
//!   1. Serialize the payload via `std.json.Stringify.valueAlloc`.
//!   2. Wrap in an `SseEvent` with `event_type` = routing key
//!      (= the same string used as the bus publish key).
//!   3. Dispatch via `di.event_bus.emit(SseEvent, routing_key, event)`.
//!
//! The event_bus is fetched from the singleton (`di.event_bus`).
//! When no SSE client is subscribed, `event_bus.emit` is a no-op
//! (it looks up the routing key in a hashmap and bails if no
//! listener) — so handlers can call these unconditionally.
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2 + 3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const on_event_sent = nalarcore.ai_mod.on_event_sent;
const SseEvent = on_event_sent.SseEvent;
const on_event_design = @import("on_event_design.zig");

/// Emit a `design_page_updated` event. Called from
/// `design_pages_update.zig` and the `set_design_page` LLM tool.
///
/// `allocator` may be any allocator — the per-request arena in HTTP
/// handlers, the test leak-tracker in unit tests. The JSON copy is
/// freed before this function returns; the SSE bus holds its own
/// owned copy.
///
/// The function returns void: SSE failures (no subscriber, OOM in
/// `valueAlloc`) are NOT propagated to the caller. The HTTP
/// request is allowed to succeed even if no client is listening —
/// the row is already updated.
pub fn onEventSendDesignPageUpdated(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignPageUpdatedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_page_updated",
        .data = json_payload,
        .event_type = "design_page_updated",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_page_updated", event);
}

/// Emit a `design_page_deleted` event. Called from
/// `design_pages_delete.zig`.
///
/// Same fire-and-forget semantics as `onEventSendDesignPageUpdated`.
pub fn onEventSendDesignPageDeleted(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignPageDeletedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_page_deleted",
        .data = json_payload,
        .event_type = "design_page_deleted",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_page_deleted", event);
}

/// Emit a `design_element_created` event. Called from
/// `design_page_elements_create.zig` and the `set_design_element`
/// LLM tool. The payload has no html body (that's on disk; the
/// frontend fetches it via GET /elements/:eid).
pub fn onEventSendDesignElementCreated(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementCreatedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_element_created",
        .data = json_payload,
        .event_type = "design_element_created",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element_created", event);
}

/// Emit a `design_element_updated` event. Called from
/// `design_page_elements_update.zig`, `design_page_elements_move.zig`,
/// `design_page_elements_resize.zig`, and the LLM tools
/// (`set_design_element` update path, `move_design_element`).
///
/// The `action` field on the payload discriminates the source:
/// `"updated"` for PUT body updates, `"moved"` for PATCH move,
/// `"resized"` for PATCH resize. v1 treats them the same; v2 may
/// use the discriminator to skip iframe re-renders for moved/resized.
pub fn onEventSendDesignElementUpdated(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementUpdatedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_element_updated",
        .data = json_payload,
        .event_type = "design_element_updated",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element_updated", event);
}

/// Emit a `design_element_deleted` event. Called from
/// `design_page_elements_delete.zig` and the
/// `delete_design_element` LLM tool.
pub fn onEventSendDesignElementDeleted(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementDeletedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_element_deleted",
        .data = json_payload,
        .event_type = "design_element_deleted",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element_deleted", event);
}