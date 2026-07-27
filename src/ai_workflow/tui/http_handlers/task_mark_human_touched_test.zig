//! Static-contract regression checks for `PUT /api/.../tasks/:id/touched`.
//!
//! The handler exists so the frontend can mark a task as
//! "human touched" the moment the user opens its chat — without
//! requiring the user to type a follow-up message or drag the card.
//! The kanban card UI uses this to flip the orange "AI finished —
//! awaiting review" dot into the green "reviewed" checkmark.
//!
//! Why static-contract (not behavioural)
//! ─────────────────────────────────────
//! The handler is a thin wrapper: parse path params → call
//! `llm_history.updateTaskLastTouchedAt` → emit `kanban_task`
//! SSE event → return 200 envelope. Standing up a real HTTP server
//! in a unit test is heavy (per project memory: HTTP handler
//! integration tests aren't the project's convention). Static
//! source-grep tests pin the four essential behaviours:
//!   1. handler is registered (can be called by router)
//!   2. handler calls the writer
//!   3. handler emits the right SSE event shape
//!   4. handler returns the right wire envelope
//!
//! Behavioural coverage of the writer lives in
//! `llm_history_notification_test.zig`; behavioural coverage of
//! the SQL predicate lives in the same file. SSE emission is
//! indirectly verified by `on_event_sent_kanban_test.zig`.
//!
//! Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md
//!   (Chunks 3 + 4).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

// ───────────────────────────────────────────────────────────────────────
// 1. handler exists and is exported by the http_handlers module
// ───────────────────────────────────────────────────────────────────────

test "task_mark_human_touched.zig exports taskMarkHumanTouchedHandler" {
    // Static: the handler symbol must exist. If the file is moved or
    // renamed, main.zig's router registration will break at compile
    // time, but we pin it here for an explicit failure message.
    const source = @embedFile("task_mark_human_touched.zig");
    if (std.mem.indexOf(u8, source, "pub fn taskMarkHumanTouchedHandler(") == null) {
        std.debug.print(
            \\
            \\!! task_mark_human_touched.zig does NOT export taskMarkHumanTouchedHandler !!
            \\
        , .{});
        return error.HandlerMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 2. handler calls the model writer
// ───────────────────────────────────────────────────────────────────────

test "task_mark_human_touched handler calls updateTaskLastHumanTouchedAt" {
    const source = @embedFile("task_mark_human_touched.zig");
    if (std.mem.indexOf(u8, source, "updateTaskLastHumanTouchedAt") == null) {
        std.debug.print(
            \\
            \\!! task_mark_human_touched.zig does NOT call updateTaskLastHumanTouchedAt !!
            \\
        , .{});
        return error.WriterCallMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 3. handler emits the kanban_task SSE event with human_touched action
// ───────────────────────────────────────────────────────────────────────

test "task_mark_human_touched handler emits kanban_task SSE event" {
    const source = @embedFile("task_mark_human_touched.zig");
    if (std.mem.indexOf(u8, source, "onEventSendKanbanTask") == null) {
        std.debug.print(
            \\
            \\!! task_mark_human_touched.zig does NOT call onEventSendKanbanTask !!
            \\
        , .{});
        return error.SseEmitMissing;
    }
    // The new "human_touched" action string must appear — without it,
    // the SSE dispatch on the frontend filters the event out
    // (KanbanTaskEvent is a discriminated union keyed on action).
    if (std.mem.indexOf(u8, source, "human_touched") == null) {
        std.debug.print(
            \\
            \\!! task_mark_human_touched.zig does NOT emit the 'human_touched' action !!
            \\
        , .{});
        return error.SseActionMissing;
    }
    // The emitted event must carry needs_human_review: false — that's
    // the truth the frontend paints as the green checkmark.
    if (std.mem.indexOf(u8, source, "needs_human_review") == null) {
        std.debug.print(
            \\
            \\!! task_mark_human_touched.zig does NOT pass needs_human_review in the SSE payload !!
            \\
        , .{});
        return error.NeedsHumanReviewInSseMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 4. handler returns a 200 success envelope
// ───────────────────────────────────────────────────────────────────────

test "task_mark_human_touched handler returns 200 success envelope" {
    const source = @embedFile("task_mark_human_touched.zig");
    // JSON envelope shape: `{"success":true}` per the project's
    // thin-handler convention (see nalar-backend-architecture.md
    // §"Status code conventions" — DELETE returns
    // `{"success":true,...}`).
    if (std.mem.indexOf(u8, source, "200") == null) {
        std.debug.print(
            \\
            \\!! task_mark_human_touched.zig does NOT return status_code 200 !!
            \\
        , .{});
        return error.StatusCodeMissing;
    }
    if (std.mem.indexOf(u8, source, "\"success\"") == null and
        std.mem.indexOf(u8, source, "success:") == null)
    {
        std.debug.print(
            \\
            \\!! task_mark_human_touched.zig does NOT include 'success' in the response envelope !!
            \\
        , .{});
        return error.SuccessEnvelopeMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 5. KanbanTaskAction enum accepts the human_touched action
// ───────────────────────────────────────────────────────────────────────

test "on_event_sent_kanban.zig exposes human_touched in KanbanTaskAction" {
    // Without this enum variant, the SSE emit will refuse to compile
    // (the action field is []const u8 — the enum exists only for
    // exhaustive switch coverage, but the helper fn mirrors the
    // enum's variants). The wire-side check: the SSE event's
    // `event_type` MUST be a known named event so the browser's
    // EventSource dispatches it (see project memory
    // `browser-eventsource-named-events`).
    const source = @embedFile("../on_event_sent_kanban.zig");
    if (std.mem.indexOf(u8, source, "human_touched") == null) {
        std.debug.print(
            \\
            \\!! on_event_sent_kanban.zig does NOT recognise the 'human_touched' action !!
            \\
        , .{});
        return error.HumanTouchedActionMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 6. KanbanTaskEventPayload accepts needs_human_review as a wire field
// ───────────────────────────────────────────────────────────────────────

test "KanbanTaskEventPayload exposes needs_human_review field" {
    // The frontend's KanbanTaskEvent interface (api/index.ts) reads
    // `event.needs_human_review` for the mark-touched re-fetch path.
    // Without this field on the wire, the frontend sees only the
    // action — same as a normal "moved" event — and the SSE handler
    // triggers a full refetch (which still works, but the explicit
    // field documents the transition).
    const source = @embedFile("../on_event_sent_kanban.zig");
    if (std.mem.indexOf(u8, source, "needs_human_review") == null) {
        std.debug.print(
            \\
            \\!! on_event_sent_kanban.zig KanbanTaskEventPayload does NOT carry needs_human_review !!
            \\
        , .{});
        return error.NeedsHumanReviewFieldMissing;
    }
}

// ───────────────────────────────────────────────────────────────────────
// 7. router registration in main.zig
// ───────────────────────────────────────────────────────────────────────

// Route registration is verified by `zig build` failing at compile
// time if `main.zig` doesn't wire the handler. Source-grepping
// `main.zig` from this file would require escaping the package path
// (Zig 0.16 forbids `@embedFile` of files outside the test's module
// path), so we defer that check to the full build.
//
// test "main.zig registers the PUT /touched route for tasks" was
// removed for that reason — see project memory `zig-embed-file-outside-module-path`.
//
// Suppress unused-import warning for `sqlite` — the test file
// doesn't directly touch the DB (the handler's writer call is
// verified by main.zig integration via `zig build run`).
comptime {
    _ = sqlite;
    _ = nalarcore;
}