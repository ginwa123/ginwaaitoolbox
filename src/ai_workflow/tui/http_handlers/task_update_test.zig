//! Static regression check for the rename-task cascade.
//!
//! Why this file exists
//! ────────────────────
//! The frontend workspace-item rename feature depends on the rename
//! HTTP path updating BOTH `workspace_item_tasks.name` AND the linked
//! `sessions.name` (the second update is what triggers the SSE
//! `session.updated` event that the ChatsList listens for).
//!
//! Without these two source-level contracts, the cascade is silently
//! broken — the rename UI would appear to work, but the chat list
//! would never pick up the new name until manual reload. The bug is
//! hard to spot in a casual read because the old code (the no-cascade
//! `updateWorkspaceItemTask`) is right next to the new code.
//!
//! The contract is enforced by two static substring checks:
//!   1. The HTTP handler must route name updates through
//!      `llm_history.updateTaskName(...)` (NOT the plain
//!      `ai_mod.workspace_item_tasks.updateWorkspaceItemTask`).
//!   2. `llm_history.updateTaskName` must call `updateSessionName`
//!      so the cascade runs and the SSE broadcast fires.
//!
//! Why a static check (not a behavioral DB test)?
//! ───────────────────────────────────────────────
//! The project has no precedent for in-process sqlite-backed tests
//! (every test in `test_runner.zig` either covers a pure function or
//! is a static source check). Standing up a sqlite DB + migrations +
//! event-bus subscription in a unit test would require either pulling
//! in the `nalarcore.getSingleton()` singleton (which depends on a
//! live `ContextIPCTui` with a server, logger, and event bus) or
//! duplicating the migration setup. The two static checks below
//! directly test the bug — they fail if and only if the cascade
//! contract is removed or routed back to the old path.
//!
//! Plan: docs/plans/2026-06-06-workspace-item-task-rename.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_update.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler uses the cascade path for renames ─────────────────

test "task_update handler routes name updates through llm_history.updateTaskName" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must contain a call to llm_history.updateTaskName.
    // If this is missing, the rename went back to the old
    // updateWorkspaceItemTask path that only updates the task row.
    if (std.mem.indexOf(u8, source, "llm_history.updateTaskName") == null) {
        std.debug.print(
            "\n!! {s} does not call llm_history.updateTaskName !!\n" ++
                "   The rename-cascade contract is broken: renaming a task\n" ++
                "   will not update the linked sessions row or broadcast the\n" ++
                "   SSE session.updated event that the ChatsList listens for.\n" ++
                "   Restore the cascade:\n" ++
                "     if (json_body.name) |n| {{\n" ++
                "         llm_history.updateTaskName(allocator, sqlite_db, task_id, n) ...\n" ++
                "     }}\n" ++
                "   See docs/plans/2026-06-06-workspace-item-task-rename.md.\n",
            .{HANDLER_PATH},
        );
        return error.RenameCascadeMissing;
    }
}

// ─── Contract 2: updateTaskName cascades to updateSessionName ─────────────

test "llm_history.updateTaskName cascades to updateSessionName" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Find the updateTaskName function body and verify it calls
    // updateSessionName. We do this by scanning the source for the
    // function signature and checking that `updateSessionName` appears
    // in the file (it appears in exactly two places: its own definition
    // and our cascade call). A more robust check would extract the
    // function body with the AST, but substring search is enough for
    // the contract — if the cascade is removed, this still passes
    // because updateSessionName is defined in the file. So we add
    // a tighter check below: updateSessionName must be called AFTER
    // the updateTaskName signature.

    const update_task_name_sig = "pub fn updateTaskName(";
    const sig_idx = std.mem.indexOf(u8, source, update_task_name_sig) orelse {
        std.debug.print(
            "\n!! Could not find `pub fn updateTaskName(` in {s} !!\n",
            .{LLM_HISTORY_PATH},
        );
        return error.UpdateTaskNameNotFound;
    };

    // Find the next `pub fn` after updateTaskName. Everything between
    // the signature and the next `pub fn` is the function body.
    const after_sig = sig_idx + update_task_name_sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, body, "updateSessionName") == null) {
        std.debug.print(
            "\n!! llm_history.updateTaskName does not call updateSessionName !!\n" ++
                "   The rename-cascade contract is broken: renaming a task\n" ++
                "   will not propagate to the linked sessions row or trigger\n" ++
                "   the SSE session.updated broadcast that the ChatsList\n" ++
                "   listens for.\n" ++
                "   Restore the cascade in updateTaskName:\n" ++
                "     updateSessionName(allocator, db, session_id, new_name) catch {{}};\n" ++
                "   See docs/plans/2026-06-06-workspace-item-task-rename.md.\n",
            .{},
        );
        return error.RenameCascadeMissing;
    }
}

// ─── Contract 3: handler preserves the session_id-only rebind path ─────────

test "task_update handler still routes session_id-only updates through updateWorkspaceItemTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must still call updateWorkspaceItemTask for the
    // session_id-only rebind case (so a session rebind doesn't
    // accidentally trigger a cascade with an empty new name). This
    // guards against an over-zealous refactor that removes the
    // rebind path entirely.
    if (std.mem.indexOf(u8, source, "updateWorkspaceItemTask") == null) {
        std.debug.print(
            "\n!! {s} no longer calls updateWorkspaceItemTask !!\n" ++
                "   The session_id rebind path may have been removed. A\n" ++
                "   `PUT {{ session_id: 'X' }}` request would no-op even though\n" ++
                "   it should rebind the task to a different session.\n" ++
                "   Restore the rebind:\n" ++
                "     if (json_body.session_id) |sid| {{\n" ++
                "         ai_mod.workspace_item_tasks.updateWorkspaceItemTask(..., null, sid) ...\n" ++
                "     }}\n" ++
                "   See docs/plans/2026-06-06-workspace-item-task-rename.md.\n",
            .{HANDLER_PATH},
        );
        return error.RebindPathMissing;
    }
}
