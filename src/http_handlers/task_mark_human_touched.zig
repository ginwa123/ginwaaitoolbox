//! `PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/touched`.
//!
//! Stamps `workspace_item_tasks.last_human_touched_at = <unix_ms>` (Migration 065)
//! for the given task and emits a `kanban_task` SSE event with
//! `action: "human_touched"` so connected clients flip the orange
//! "AI finished — awaiting review" dot to the green "reviewed"
//! checkmark without a manual page reload.
//!
//! Why this endpoint exists
//! ─────────────────────────
//! The frontend fires this the moment a user opens a task's chat
//! (`AppLayout.vue::setActiveTask`), so opening a card to "just read"
//! the AI's output counts as a review. Other human actions (drag,
//! rename, edit description, pin, send message) already stamp the
//! same column from their respective handlers — see Chunk 5.
//!
//! Idempotent: re-stamping the timestamp is harmless. Multiple clients
//! firing the PUT simultaneously just produce the same DB write.
//!
//! Wire shape
//! ──────────
//! Request: empty body or `{}` (no fields required).
//! Response: `200 { "success": true, "task_id": "task_..." }`.
//! Errors:
//!   - 400 `task_id required` — path param missing
//!   - 500 `Out of memory` — `std.json.Stringify.valueAlloc` failure
//!
//! Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md
//!   (Chunks 3 + 4).

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = ai_mod.llm_history;
const on_event_sent_kanban = ai_mod.on_event_sent_kanban;

pub const MarkTouchedError = error{
    TaskIdRequired,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const MarkTouchedResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

const MarkTouchedResponse = struct {
    success: bool = true,
    task_id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    workspace_id: []const u8,
    item_id: []const u8,
    task_id: []const u8,
) MarkTouchedError!MarkTouchedResult {
    if (task_id.len == 0) return error.TaskIdRequired;

    // 1. Stamp the column. Idempotent — re-stamping is harmless.
    //    The writer reads current time via libc gettimeofday
    //    internally (now_unix_ms=null → auto-now).
    llm_history.updateTaskLastHumanTouchedAt(allocator, db, task_id, null) catch {
        // Collapse writer errors to a single caller-handled variant
        // (matches the project's pattern of narrow use-case error sets;
        // see memory `zig-language-quirks` §"catch narrows the
        // inferred error set before the catch").
        return error.TaskIdRequired;
    };

    // 2. Emit SSE so connected kanban clients refresh. Fire-and-forget
    //    (matches tasks_move.zig and task_create.zig): SSE failures
    //    log a warning but don't fail the request — the DB write is
    //    already committed and the kanban view will pick up the new
    //    state on its next refetch.
    on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "human_touched",
        .workspace_id = workspace_id,
        .item_id = item_id,
        .task_id = task_id,
        // After a human touch, the task is no longer "awaiting
        // review" (if it ever was). Send the explicit flag so the
        // frontend doesn't have to recompute it.
        .needs_human_review = false,
    }) catch |err| {
        std.log.warn(
            "task_mark_human_touched: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return try std.json.Stringify.valueAlloc(
        allocator,
        MarkTouchedResponse{ .task_id = task_id },
        .{},
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn taskMarkHumanTouchedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // workspace_id + item_id are not strictly required (the DB write
    // is keyed on task_id only), but we keep them in the route so
    // the path matches the sibling task handlers and the SSE event
    // payload carries them. Empty-string is acceptable.
    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, workspace_id, item_id, task_id) catch |err| {
        const status: u16 = switch (err) {
            error.TaskIdRequired => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskIdRequired => "task_id required",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}