//! Static regression checks for Migration 062's description
//! propagation through `llm_history.zig`.
//!
//! Why this file exists
//! ────────────────────
//! Migration 062 added `description TEXT NOT NULL DEFAULT ''` to
//! `workspace_item_tasks`. The frontend's kanban-task-detail-dialog
//! reads the description via `GET /api/workspaces/:wid/items/:iid/tasks`
//! (the cursor-paginated lister) and `GET /api/workspaces/tasks/:tid`
//! (the single-row `getWorkspaceItemTask`). Both paths must:
//!   1. Include `description` in their SELECT column list.
//!   2. Populate the `description` field on the returned
//!      `WorkspaceItemTaskInfo` struct.
//!
//! If the SELECT drifts (e.g. someone reverts the column list to the
//! pre-061 shape) the row parser will read `created_at` from
//! `row.values[3]` instead of `description` — silently corrupting
//! the response. These static checks catch that regression at compile
//! time of the test binary.
//!
//! Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//!   (Chunk 1, Task 1.5).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const LLM_HISTORY_PATH = "src/ai_workflow/tui/agentic_loop/llm_history.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

// ─── Contract 1: WorkspaceItemTaskInfo has a description field ────────────

test "WorkspaceItemTaskInfo struct has description field (Migration 062)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The struct body (between the signature and the first `};`) must
    // contain `description:` to confirm Migration 062 added the field.
    const struct_sig = "pub const WorkspaceItemTaskInfo = struct";
    const sig_idx = std.mem.indexOf(u8, source, struct_sig) orelse {
        std.debug.print("\n!! Could not find WorkspaceItemTaskInfo in {s} !!\n", .{LLM_HISTORY_PATH});
        return error.WorkspaceItemTaskInfoMissing;
    };
    const after_sig = sig_idx + struct_sig.len;
    // Find the matching `};` — the struct body's closing brace.
    // We use the FIRST `};` after the signature (Zig struct bodies
    // close at the FIRST `};` they encounter, so this is correct for
    // top-level struct declarations).
    const end_marker = std.mem.indexOfPos(u8, source, after_sig, "};") orelse source.len;
    const body = source[after_sig..end_marker];

    if (std.mem.indexOf(u8, body, "description:") == null) {
        std.debug.print(
            "\n!! WorkspaceItemTaskInfo has no `description` field !!\n" ++
                "   Migration 062 requires the lister to populate description from\n" ++
                "   the new column. Add `description: []u8 = &.{{}}` to the struct.\n",
            .{},
        );
        return error.DescriptionFieldMissing;
    }
}

// ─── Contract 2: getWorkspaceItemTask SELECT includes description ─────────

test "getWorkspaceItemTask SELECT lists the description column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Find the function body and verify the SELECT lists `description`
    // in its column list (between workspace_item_id and created_at).
    const fn_sig = "pub fn getWorkspaceItemTask(";
    const sig_idx = std.mem.indexOf(u8, source, fn_sig) orelse {
        std.debug.print("\n!! getWorkspaceItemTask signature not found !!\n", .{});
        return error.GetTaskFnMissing;
    };
    const after_sig = sig_idx + fn_sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    // Accept either `description, created_at` (the exact expected
    // column order) OR `t.description, t.created_at` (the aliased
    // form some queries use).
    const has_description_col = std.mem.indexOf(u8, body, "description, created_at") != null or
        std.mem.indexOf(u8, body, "t.description, t.created_at") != null;

    if (!has_description_col) {
        std.debug.print(
            "\n!! getWorkspaceItemTask SELECT does not list description !!\n" ++
                "   The single-task SELECT must include `description` (Migration 062).\n" ++
                "   Expected column order: id, name, workspace_item_id, description, ...\n" ++
                "   A missing column here means the row parser will read created_at\n" ++
                "   from row.values[3] (the wrong slot) and silently corrupt the\n" ++
                "   response.\n",
            .{},
        );
        return error.DescriptionColumnMissing;
    }
}

// ─── Contract 3: listWorkspaceItemTasks SELECT includes description ──────

test "listWorkspaceItemTasks SELECT lists t.description column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Find the legacy lister (no cursor) and assert it includes
    // `t.description` in its SELECT column list.
    const fn_sig = "pub fn listWorkspaceItemTasks(";
    const sig_idx = std.mem.indexOf(u8, source, fn_sig) orelse return error.ListFnMissing;
    const after_sig = sig_idx + fn_sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, body, "t.description, t.created_at") == null) {
        std.debug.print(
            "\n!! listWorkspaceItemTasks SELECT does not list t.description !!\n" ++
                "   The non-cursor lister must include `t.description` (Migration 062).\n",
            .{},
        );
        return error.ListDescriptionMissing;
    }
}

// ─── Contract 4: listWorkspaceItemTasksWithCursor SELECT includes description

test "listWorkspaceItemTasksWithCursor SELECT lists t.description column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Find the cursor lister and assert it includes `t.description`.
    const fn_sig = "pub fn listWorkspaceItemTasksWithCursor(";
    const sig_idx = std.mem.indexOf(u8, source, fn_sig) orelse return error.CursorListFnMissing;
    const after_sig = sig_idx + fn_sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, body, "t.description, t.created_at") == null) {
        std.debug.print(
            "\n!! listWorkspaceItemTasksWithCursor SELECT does not list t.description !!\n" ++
                "   The cursor lister must include `t.description` (Migration 062).\n" ++
                "   This is the primary read path for the frontend's tasks-list\n" ++
                "   endpoint; without description in the SELECT the response will\n" ++
                "   silently shift created_at into the description slot.\n",
            .{},
        );
        return error.CursorListDescriptionMissing;
    }
}
