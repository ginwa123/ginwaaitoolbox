//! SSE events for kanban mutations.
//!
//! Two event families are emitted on every successful kanban mutation:
//!
//!   - `kanban_column` — fired when a kanban column is created,
//!     renamed, reordered, or deleted. Carries the workspace_id,
//!     item_id, column_id, and the action so the frontend can no-op
//!     events for other workspaces without re-fetching.
//!
//!   - `kanban_task` — fired when a task is moved to a different
//!     column, reordered within a column, assigned to a kanban column
//!     for the first time, or unassigned (column deleted). Carries
//!     workspace_id, item_id, task_id, and the new kanban_column_id
//!     (or null for unassign).
//!
//! Subscribers (the frontend KanbanSse store) register via
//! `event_bus.subscribe(SseEvent, "kanban_<family>", handler)` and
//! patch the local Pinia store without a re-fetch when possible.
//!
//! Pattern mirrors `onEventSendWorkers` in `on_event_sent.zig`: the
//! function allocates a fresh payload slice per call and emits it
//! through the shared event_bus. The SSE manager serializes the
//! payload as JSON on the wire.
//!
//! Note: this module lives in its own file (not `on_event_sent.zig`)
//! so the kanban event types are co-located with the kanban domain
//! code, and `on_event_sent.zig` stays untouched. The new module is
//! re-exported as `nalarcore.ai_mod.on_event_sent_kanban` from
//! `src/ai_workflow/tui/mod.zig`.
//!
//! Plan: docs/superpowers/plans/2026-06-26-fix-kanban-list-empty-add-sse.md
//!   (Chunk 3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const on_event_sent = nalarcore.ai_mod.on_event_sent;
const SseEvent = on_event_sent.SseEvent;

/// Action discriminator for `kanban_column` events.
pub const KanbanColumnAction = enum {
    created,
    updated,
    deleted,
    reordered,
};

/// JSON payload for a `kanban_column` SSE event. Field names match
/// the frontend's `KanbanColumnEvent` interface (camelCase for the
/// action, snake_case for the ids — see
/// `src/apps/desktop/src/api/index.ts`).
pub const KanbanColumnEventPayload = struct {
    /// "created" | "updated" | "deleted" | "reordered"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    column_id: []const u8,
    /// New column name (only set for "updated"; null otherwise).
    new_name: ?[]const u8 = null,
    /// New column description (only set for "updated"; null
    /// otherwise). The frontend ignores nulls and re-fetches the
    /// full column list anyway, but carrying the value lets future
    /// in-place patch optimisations skip the GET.
    new_description: ?[]const u8 = null,
    /// New position (only set for "updated" / "reordered"; null otherwise).
    new_position: ?i64 = null,
};

/// Emit a `kanban_column` SSE event. Called from every kanban column
/// HTTP handler on success. Allocates a JSON-safe copy of every
/// payload field via `std.json.Stringify.valueAlloc`; the caller passes
/// raw slices and may free them after this function returns.
///
/// The `event_bus` is fetched from the singleton (`di.event_bus`), the
/// same pattern as `onEventSendWorkers` in `on_event_sent.zig`. When
/// no SSE client is subscribed, `event_bus.emit` is a no-op (it looks
/// up the routing key in a hashmap and bails if no listener) — so
/// handlers can call this unconditionally without guarding for
/// "is an SSE subscriber connected".
pub fn onEventSendKanbanColumn(
    allocator: std.mem.Allocator,
    payload: KanbanColumnEventPayload,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    // Build the SSE event. `event_type` drives the SSE wire format
    // `event: kanban_column\n` line; `data` is the JSON body;
    // `session_id` is the event_bus routing key (broadcast to all
    // subscribers of `"kanban_column"` regardless of session).
    const event = SseEvent{
        .session_id = "kanban_column",
        .data = json_payload,
        .event_type = "kanban_column",
    };

    // event_bus.emit returns void and silently no-ops when no
    // subscriber is registered — so tests that don't stand up an SSE
    // server still pass.
    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "kanban_column", event);
}

/// Action discriminator for `kanban_task` events.
pub const KanbanTaskAction = enum {
    assigned,
    moved,
    unassigned,
    /// Human interaction stamp — fired by the new
    /// `PUT /api/.../tasks/:id/touched` endpoint and by every existing
    /// task-mutating handler (`task_update`, `task_create`, `tasks_move`,
    /// `sessions_send_message`). The kanban card UI listens for this
    /// and re-fetches the task list so the orange "AI finished —
    /// awaiting review" dot flips to the green "reviewed" checkmark
    /// the moment a user does anything with the card.
    human_touched,
};

/// JSON payload for a `kanban_task` SSE event. Field names match
/// the frontend's `KanbanTaskEvent` interface.
pub const KanbanTaskEventPayload = struct {
    /// "assigned" | "moved" | "unassigned" | "human_touched"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    task_id: []const u8,
    /// New kanban_column_id (null for "unassigned" / "human_touched").
    new_column_id: ?[]const u8 = null,
    /// New kanban_position (null for "unassigned" / "human_touched").
    new_position: ?i64 = null,
    /// After-action `needs_human_review` state. Present only on
    /// `human_touched` events so the frontend can confirm the mark
    /// without re-querying; null on `assigned`/`moved`/`unassigned`
    /// (those handlers don't touch the AI-state predicate).
    needs_human_review: ?bool = null,
};

/// Emit a `kanban_task` SSE event. Called from `tasks_move.zig` on
/// every successful move and from `task_create.zig` when the new
/// task is auto-assigned to a kanban column.
pub fn onEventSendKanbanTask(
    allocator: std.mem.Allocator,
    payload: KanbanTaskEventPayload,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "kanban_task",
        .data = json_payload,
        .event_type = "kanban_task",
    };

    const di = nalarcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "kanban_task", event);
}
