//! SSE emitters for design-page mutations.
//!
//! Two event families:
//!   - `design_page_updated` — fired on PUT /design/pages/:pid and
//!     by the `set_design_page` LLM tool. Carries the full page
//!     (id, name, html, position, timestamps) so the frontend can
//!     patch in place.
//!   - `design_page_deleted` — fired on DELETE /design/pages/:pid
//!     and by the `delete_design_page` LLM tool. Carries ids +
//!     page_name (no html — the row is gone).
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
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const on_event_sent = nalarcore.ai_mod.on_event_sent;
const SseEvent = on_event_sent.SseEvent;
const on_event_design = @import("on_event_design.zig");

/// Emit a `design_page_updated` event. Called from
/// `design_pages_update.zig` (Task 2.5) and the future
/// `set_design_page` tool (Chunk 3).
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
) void {
    const json_payload = std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    ) catch |err| {
        std.log.warn(
            "design_page_updated: valueAlloc failed (non-fatal): {s}",
            .{@errorName(err)},
        );
        return;
    };
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
/// `design_pages_delete.zig` (Task 2.6) and the future
/// `delete_design_page` tool (Chunk 3).
///
/// Same fire-and-forget semantics as `onEventSendDesignPageUpdated`.
pub fn onEventSendDesignPageDeleted(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignPageDeletedData,
) void {
    const json_payload = std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    ) catch |err| {
        std.log.warn(
            "design_page_deleted: valueAlloc failed (non-fatal): {s}",
            .{@errorName(err)},
        );
        return;
    };
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_page_deleted",
        .data = json_payload,
        .event_type = "design_page_deleted",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_page_deleted", event);
}