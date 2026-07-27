//! Static-contract regression checks that every HTTP handler that
//! mutates a task on behalf of a human user stamps the
//! `last_human_touched_at` column (Migration 065 / plan
//! docs/plans/2026-07-26-kanban-task-notification-icon.md, Chunk 5).
//!
//! Why this matters
//! ─────────────────
//! The kanban card "AI finished — awaiting review" dot flips to the
//! green "reviewed" checkmark the moment a user does anything that
//! touches the task. Without a stamp in the right handler, opening
//! the chat to read the AI's output leaves the orange dot stuck
//! "awaiting review" even though the human clearly engaged.
//!
//! Coverage matrix (Chunk 5 call sites)
//! ────────────────────────────────────
//! - task_update   (rename / description / pin) → handler stamps.
//! - task_create   (any new task)              → handler stamps.
//! - tasks_move    (drag to another column)    → handler stamps.
//! - session_create (user sends a chat message via POST /api/llm/session
//!                   — task_id == session_id per project convention)
//!                                            → handler stamps.
//!
//! Note: the AI workflow's own responses do NOT stamp
//! (workflow.zig::updateSessionLastFinishReason is an unrelated cache).
//! If a future AI-side call to `updateTaskLastHumanTouchedAt` is
//! added, the green checkmark would be permanently stuck on — the
//! opposite of the feature's intent.
//!
//! Per the project convention, these are static-contract source-grep
//! tests — they don't exercise the DB. Behavioural coverage of the
//! writer lives in `llm_history_notification_test.zig`.

const std = @import("std");
const testing = std.testing;

const TASK_UPDATE_PATH = "task_update.zig";
const TASK_CREATE_PATH = "task_create.zig";
const TASKS_MOVE_PATH = "tasks_move.zig";
const SESSION_CREATE_PATH = "session_create.zig";

test "task_update.zig calls updateTaskLastHumanTouchedAt" {
    // The stamp is a fire-and-forget `catch |err| std.log.warn(...)` so
    // the surrounding code path is unchanged — the kanban icon flips
    // when the user renames/edits/pins, but the rename itself stays
    // reliable even if the stamp write fails.
    const source = @embedFile(TASK_UPDATE_PATH);
    if (std.mem.indexOf(u8, source, "updateTaskLastHumanTouchedAt") == null) {
        std.debug.print(
            \\
            \\!! task_update.zig does NOT stamp last_human_touched_at on the task !!
            \\   Without this, renaming/editing/pinning a card leaves the
            \\   "AI finished — awaiting review" orange dot stuck even
            \\   though the user clearly touched the card.
            \\
        , .{});
        return error.TaskUpdateStampMissing;
    }
}

test "task_create.zig calls updateTaskLastHumanTouchedAt" {
    // Creating a card is a touch — even before the AI has run, the
    // user owns the empty slot. Without the stamp, freshly-created
    // kanban tasks show no icon (correct) but if the AI later
    // finishes, the dot would correctly turn orange (because
    // last_human_touched_at is NULL). The stamp's role here is more
    // subtle: subsequent user actions on the SAME card would no
    // longer re-fire the transition because last_human_touched_at
    // is now non-NULL. This is intentional — the "reviewed"
    // semantic applies to the FIRST interaction with the AI's
    // output, not to the card's existence.
    const source = @embedFile(TASK_CREATE_PATH);
    if (std.mem.indexOf(u8, source, "updateTaskLastHumanTouchedAt") == null) {
        std.debug.print(
            \\
            \\!! task_create.zig does NOT stamp last_human_touched_at on the new task !!
            \\
        , .{});
        return error.TaskCreateStampMissing;
    }
}

test "tasks_move.zig calls updateTaskLastHumanTouchedAt" {
    // Dragging a card to another column is the most visible
    // "human touch" interaction — users will expect the orange dot
    // to flip green the moment they release the drop.
    const source = @embedFile(TASKS_MOVE_PATH);
    if (std.mem.indexOf(u8, source, "updateTaskLastHumanTouchedAt") == null) {
        std.debug.print(
            \\
            \\!! tasks_move.zig does NOT stamp last_human_touched_at on the moved task !!
            \\
        , .{});
        return error.TasksMoveStampMissing;
    }
}

test "session_create.zig calls updateTaskLastHumanTouchedAt" {
    // POST /api/llm/session is the user's "send a message"
    // endpoint (frontend `api.sendChatMessage`). The session_id IS
    // the task_id per the project convention, so stamping the task
    // here captures the user-typed-message touch. Without this,
    // sending a message doesn't clear the orange dot — only
    // opening the chat (via the PUT /touched endpoint from Chunk 3)
    // would.
    const source = @embedFile(SESSION_CREATE_PATH);
    if (std.mem.indexOf(u8, source, "updateTaskLastHumanTouchedAt") == null) {
        std.debug.print(
            \\
            \\!! session_create.zig does NOT stamp last_human_touched_at !!
            \\   Without this, sending a chat message doesn't flip the
            \\   orange "awaiting review" dot — only opening the card
            \\   (via PUT /touched) would.
            \\
        , .{});
        return error.SessionCreateStampMissing;
    }
}