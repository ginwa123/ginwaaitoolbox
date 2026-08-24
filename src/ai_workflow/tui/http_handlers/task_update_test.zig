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
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_update.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/agentic_loop/llm_history.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
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

// ─── Contract 3: handler no longer references the dropped session_id rebind ─

test "task_update handler no longer references the dropped session_id rebind" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Migration 052 dropped the redundant `session_id` column from
    // `workspace_item_tasks` (the column equaled the task's own id
    // per the `task.id == session_id` convention). The rebind path
    // (`updateWorkspaceItemTask(... , null, sid)`) was removed in
    // the same change. This test guards against accidentally
    // re-introducing it.
    if (std.mem.indexOf(u8, source, "updateWorkspaceItemTask") != null) {
        std.debug.print(
            "\n!! {s} still calls updateWorkspaceItemTask !!\n" ++
                "   Migration 052 dropped the session_id column; the rebind\n" ++
                "   path is no longer needed (task.id IS the session id).\n" ++
                "   Remove the call from the handler.\n",
            .{HANDLER_PATH},
        );
        return error.RebindPathStillPresent;
    }
}

// ─── Contract 4: task_update persists description (Migration 062) ──────────
//
// When the request body carries a `description` field, the handler must
// persist it to `workspace_item_tasks.description` via a guarded UPDATE
// (only when the field is non-null — null means "leave unchanged").
// Empty string is the canonical "no description" sentinel and IS
// persisted (NOT skipped — it means the user actively cleared the field).
//
// Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//   (Chunk 1, Task 1.3).

test "task_update persists description to workspace_item_tasks column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must contain an UPDATE that sets the description
    // column. After PR #101 refactor the SQL is built dynamically,
    // so we match the composed fragments rather than a literal
    // `description = ?` substring (which no longer appears in source).
    // The dynamic builder appends:
    //   - `, description = ` (between the fixed prefix and the RHS)
    //   - either `''` (empty-string literal) or `?` (value bind)
    // We require at least the `?` bind path so a regression that
    // always uses the literal still has to wire the bind through.
    const has_set_clause = std.mem.indexOf(u8, source, ", description = ") != null;
    const has_bind = std.mem.indexOf(u8, source, ", description = \"?") != null or
        std.mem.indexOf(u8, source, "appendSlice(allocator, \"?\")") != null;
    const has_where = std.mem.indexOf(u8, source, "WHERE id = ?") != null or
        std.mem.indexOf(u8, source, "\" WHERE id = ?\"") != null;
    if (!has_set_clause or !has_bind or !has_where) {
        std.debug.print(
            "\n!! {s} does not UPDATE workspace_item_tasks.description !!\n" ++
                "   Migration 062 added the column; PUT /api/workspaces/tasks/:id\n" ++
                "   with a body.description must persist it via the dynamic SQL\n" ++
                "   builder. The useCase's description branch must:\n" ++
                "   - sql_buf.appendSlice(allocator, \", description = \")\n" ++
                "   - sql_buf.appendSlice(allocator, \"?\")  // for non-empty desc\n" ++
                "   - sql_buf.appendSlice(allocator, \" WHERE id = ?\")\n" ++
                "   See plan docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md.\n" ++
                "   Missing: set_clause={any}, bind={any}, where={any}\n",
            .{ HANDLER_PATH, has_set_clause, has_bind, has_where },
        );
        return error.DescriptionUpdateMissing;
    }
}

test "task_update guards description branch on body.description != null" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The UPDATE must be wrapped in an `if (input.body.description) |...|`
    // guard so a null body.description (the "leave unchanged" sentinel
    // in TaskUpdateRequest) does NOT overwrite the column with NULL.
    // We check for the pattern `if (input.body.description)` (or the
    // equivalent `if (input.body.description) |`) anywhere in the file.
    const has_branch = std.mem.indexOf(u8, source, "if (input.body.description)") != null or
        std.mem.indexOf(u8, source, "if (json_body.description)") != null;
    if (!has_branch) {
        std.debug.print(
            "\n!! {s} does not guard the description branch !!\n" ++
                "   The UPDATE must only run when input.body.description is non-null\n" ++
                "   (a null value is the 'leave unchanged' sentinel in the request).\n" ++
                "   Add `if (input.body.description) |desc| {{ ... }}` around the\n" ++
                "   UPDATE statement.\n",
            .{HANDLER_PATH},
        );
        return error.DescriptionBranchUnguarded;
    }
}

// =====================================================================
// Migration 069 read-path follow-up (plan:
// docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
// Task 3): the PUT handler parses TaskUpdateRequest.image_urls but had
// NO useCase branch — image edits were silently dropped. Two contracts:
// the branch must exist + validate via image_urls_validation, and the
// handler must map the validation errors to 400/413.
// =====================================================================

test "task_update useCase persists image_urls edits" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The useCase must import + use image_urls_validation.
    if (std.mem.indexOf(u8, source, "image_urls_validation") == null) {
        std.debug.print(
            "\n!! {s} does not import/use image_urls_validation !!\n" ++
                "   The PUT handler parses TaskUpdateRequest.image_urls but\n" ++
                "   never persists it — image edits are silently dropped.\n" ++
                "   Add an image_urls branch mirroring the tags branch\n" ++
                "   (validate via image_urls_validation.validateImageUrls,\n" ++
                "   dynamic SQL builder, SQL '' literal for the empty case).\n",
            .{HANDLER_PATH},
        );
        return error.ImageUrlsValidationMissing;
    }

    // The useCase must read input.body.image_urls.
    if (std.mem.indexOf(u8, source, "input.body.image_urls") == null) {
        std.debug.print(
            "\n!! {s} useCase does not read input.body.image_urls !!\n",
            .{HANDLER_PATH},
        );
        return error.ImageUrlsBranchMissing;
    }
}

test "task_update maps image_urls validation errors to 400/413" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.InvalidImageUrls => 400") == null) {
        std.debug.print(
            "\n!! {s} handler does not map error.InvalidImageUrls to 400 !!\n",
            .{HANDLER_PATH},
        );
        return error.InvalidImageUrlsStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "error.ImageUrlsTooLarge => 413") == null) {
        std.debug.print(
            "\n!! {s} handler does not map error.ImageUrlsTooLarge to 413 !!\n",
            .{HANDLER_PATH},
        );
        return error.ImageUrlsTooLargeStatusMissing;
    }
}
