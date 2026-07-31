//! SSE events for design-mode mutations.
//!
//! Three event families are emitted on every successful design-element
//! mutation:
//!
//!   - `design_element_created` — fired when `addElement` succeeds
//!     (called from the HTTP `POST /design/.../elements` handler and
//!     the LLM `add_element` tool).
//!
//!   - `design_element_updated` — fired when `updateElement` succeeds
//!     (any field change: name, geometry, fill, rotation, contenteditable
//!     / Monaco HTML save, etc.).
//!
//!   - `design_element_deleted` — fired when `deleteElement` succeeds.
//!
//! All three share the same payload shape (`workspace_id`, `item_id`,
//! `page_id`, `element_id`, plus an `action` discriminator) and are
//! routed on the single event_bus key `"design_element"`. The
//! wire-format `event:` line carries the granular name
//! (`design_element_created` / `_updated` / `_deleted`) so the
//! browser's EventSource can dispatch by name (see project memory
//! `browser-eventsource-named-events.md`).
//!
//! Subscribers (the frontend `designSse.ts` store) register via
//! `event_bus.subscribe(SseEvent, "design_element", handler)` and
//! call `workspacesStore.fetchDesignElements(workspace_id, item_id,
//! page_id)` to re-fetch the page's element list. The frontend then
//! patches the local Pinia store in place (the SseEvent carries
//! enough context to decide whether the re-fetch is needed).
//!
//! Pattern mirrors `onEventSendKanbanColumn` in
//! `on_event_sent_kanban.zig`: the function allocates a fresh payload
//! slice per call and emits it through the shared event_bus. The SSE
//! manager serializes the payload as JSON on the wire.
//!
//! Note: this module lives in its own file (not `on_event_sent.zig`)
//! so the design event types are co-located with the design domain
//! code, and `on_event_sent.zig` stays untouched. The new module is
//! re-exported as `nalarcore.ai_mod.on_event_sent_design` from
//! `src/ai_workflow/tui/mod.zig`.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const on_event_sent = nalarcore.ai_mod.on_event_sent;
const on_event_design = @import("on_event_design.zig");

const SseEvent = on_event_sent.SseEvent;

/// Emit a `design_element_created` SSE event. Called from
/// `design_model.addElement` on every successful insert. Allocates
/// a JSON-safe copy of every payload field via
/// `std.json.Stringify.valueAlloc`; the caller passes raw slices and
/// may free them after this function returns.
///
/// The `event_bus` is fetched from the singleton (`di.event_bus`),
/// the same pattern as `onEventSendKanbanColumn` in
/// `on_event_sent_kanban.zig`. When no SSE client is subscribed,
/// `event_bus.emit` is a no-op (it looks up the routing key in a
/// hashmap and bails if no listener) — so model code can call this
/// unconditionally without guarding for "is an SSE subscriber
/// connected".
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

    // Build the SSE event. `event_type` drives the SSE wire format
    // `event: design_element_created\n` line; `data` is the JSON
    // body; `session_id` is the event_bus routing key (broadcast to
    // all subscribers of `"design_element"` regardless of session).
    const event = SseEvent{
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_element_created",
    };

    // event_bus.emit returns void and silently no-ops when no
    // subscriber is registered — so tests that don't stand up an SSE
    // server still pass.
    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_element_updated` SSE event. Called from
/// `design_model.updateElement` on every successful update. The
/// payload shape is identical to the `created` event so the
/// frontend listener can treat them uniformly (it re-fetches the
/// page's element list in both cases).
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
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_element_updated",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_elements_geometry_batch_updated` SSE event. Called
/// from `design_model.updateElementsBatch` after a single atomic
/// transaction moves 1+ elements. The frontend's local-mutation dedupe
/// (stores/designSse.ts) reads `element_ids` from this payload to
/// skip the `fetchDesignElements` GET fan-out when the batch originated
/// from this client within the last 1500 ms.
///
/// Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
///   (Chunk 1, Task 1.2)
pub fn onEventSendDesignElementsGeometryBatchUpdated(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementsGeometryBatchUpdatedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_elements_geometry_batch_updated",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_element_deleted` SSE event. Called from
/// `design_model.deleteElement` on every successful delete. The
/// frontend listener uses this to remove the element from the
/// local Pinia store without a re-fetch (the payload's
/// `element_id` is enough to identify the row).
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
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_element_deleted",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_page_deleted` SSE event. Called from
/// `design_model.deletePage` on every successful page delete. The
/// frontend listener (see `designSse.ts`) removes the page from the
/// tabs strip + clears `activeDesignPageId` if it was the active
/// page. Routing key `"design_page"` (parallel to `"design_element"`
/// — see project memory `browser-eventsource-named-events.md`).
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
        .session_id = "design_page",
        .data = json_payload,
        .event_type = "design_page_deleted",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_page", event);
}
