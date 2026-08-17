//! Static regression checks for description persistence in
//! `task_create.zig` (Migration 062).
//!
//! Why this file exists
//! ────────────────────
//! Migration 062 added the `description` column to
//! `workspace_item_tasks`. The `task_create` HTTP handler has THREE
//! branches (standard / routine / memory) and each must persist
//! description to the new column. These checks verify the SQL
//! pattern is present in all three branches, so a future refactor
//! can't silently drop description persistence.
//!
//! Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//!   (Chunk 1, Task 1.4).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";
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

test "createWorkspaceItemTask signature accepts a description parameter" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The helper signature must include `description` as the
    // trailing parameter so the standard-task INSERT path can pass
    // the field through. If this is missing, the standard-task
    // create path silently drops description.
    const sig = "pub fn createWorkspaceItemTask(";
    const sig_idx = std.mem.indexOf(u8, source, sig) orelse {
        std.debug.print("\n!! Could not find `pub fn createWorkspaceItemTask(` in {s} !!\n", .{LLM_HISTORY_PATH});
        return error.CreateWorkspaceItemTaskMissing;
    };
    const after_sig = sig_idx + sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const signature = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, signature, "description") == null) {
        std.debug.print(
            "\n!! createWorkspaceItemTask signature does not include `description` !!\n" ++
                "   Migration 062 requires the standard-task create path to persist\n" ++
                "   description. Add a trailing `description: ?[]const u8` parameter.\n",
            .{},
        );
        return error.DescriptionParameterMissing;
    }
}

test "createWorkspaceItemTask SQL inserts the description column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Find the INSERT INTO workspace_item_tasks inside createWorkspaceItemTask
    // and assert it lists the description column. We approximate by scanning
    // for a pattern: the helper's INSERT must reference `description` as a
    // column. (There are multiple INSERTs into workspace_item_tasks in the
    // file — three in task_create.zig plus one in createWorkspaceItemTask —
    // but we only care that THIS helper's INSERT covers description.)
    const sig = "pub fn createWorkspaceItemTask(";
    const sig_idx = std.mem.indexOf(u8, source, sig) orelse {
        std.debug.print("\n!! createWorkspaceItemTask signature not found !!\n", .{});
        return error.CreateWorkspaceItemTaskMissing;
    };
    const after_sig = sig_idx + sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    // The INSERT must list `description` in its column list and bind
    // it via a `?` placeholder. We accept either "description" alone
    // (column name) or "description, " (with trailing comma) so the
    // check is robust to surrounding whitespace.
    const has_col = std.mem.indexOf(u8, body, "description") != null;
    const has_bind = std.mem.indexOf(u8, body, "INSERT INTO workspace_item_tasks") != null and
        std.mem.indexOf(u8, body, ", description") != null;

    if (!has_col or !has_bind) {
        std.debug.print(
            "\n!! createWorkspaceItemTask INSERT does not cover `description` !!\n" ++
                "   The standard-task INSERT must list `description` in its column\n" ++
                "   list and bind it as a parameter. Example:\n" ++
                "     INSERT INTO workspace_item_tasks\n" ++
                "       (id, name, workspace_item_id, task_type, description)\n" ++
                "     VALUES (?, ?, ?, ?, ?)\n",
            .{},
        );
        return error.DescriptionColumnMissing;
    }
}

test "task_create routine + memory INSERTs cover the description column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler has two direct-INSERT branches (routine at the
    // createRoutineTask helper, memory at createMemoryTask). Both
    // must include `description` in their INSERT. We require BOTH
    // to appear so a regression that drops description from either
    // path is caught.
    const routine_match = std.mem.indexOf(u8, source, "'routine'") != null;
    const memory_match = std.mem.indexOf(u8, source, "'memory'") != null;

    // After PR #101 review feedback, the SQL is built dynamically
    // via a `std.ArrayList` builder + parallel `bind_values` list.
    // The literal substrings we can match against have changed:
    //   - The column list fragment is appended as `, description`
    //     in two places (one for the empty-string literal path,
    //     one for the bound-value path).
    //   - The VALUES tail fragment is appended as `, ''` (empty)
    //     or `, ?` (value).
    //   - The whole SQL is composed at the end via
    //     `INSERT INTO workspace_item_tasks ({s}) VALUES ({s})`.
    //
    // We accept any of these shapes to prove description is wired
    // in. The check is robust to the three branches (null / "" /
    // value) and to future minor reformatting.
    const has_desc_col = std.mem.indexOf(u8, source, ", description") != null;
    const has_routine_type = std.mem.indexOf(u8, source, "'routine'") != null;
    const has_memory_type = std.mem.indexOf(u8, source, "'memory'") != null;
    const has_empty_literal = std.mem.indexOf(u8, source, ", ''") != null;
    const has_bind_placeholder = std.mem.indexOf(u8, source, ", ?") != null;
    const has_insert_compose = std.mem.indexOf(u8, source,
        "INSERT INTO workspace_item_tasks ({s}) VALUES ({s})") != null;

    if (!routine_match or !memory_match) {
        std.debug.print(
            "\n!! task_create.zig is missing the 'routine' or 'memory' INSERT branch !!\n",
            .{},
        );
        return error.BranchMissing;
    }
    if (!has_desc_col or !has_routine_type or !has_memory_type or
        !has_empty_literal or !has_bind_placeholder or !has_insert_compose)
    {
        std.debug.print(
            "\n!! task_create.zig routine or memory branch does not persist description !!\n" ++
                "   After PR #101 refactor, each branch must build SQL dynamically:\n" ++
                "   - cols_buf.appendSlice(allocator, \", description\")\n" ++
                "   - vals_buf.appendSlice(allocator, \", ''\")  // empty-string case\n" ++
                "   - vals_buf.appendSlice(allocator, \", ?\")   // value case\n" ++
                "   - sql_buf.print(allocator,\n" ++
                "         INSERT_INTO_LITERAL, ...);\n" ++
                "     where INSERT_INTO_LITERAL is the standard INSERT\n" ++
                "     INTO workspace_item_tasks SQL template.\n" ++
                "   Missing: desc_col={any}, routine_type={any}, memory_type={any}, empty_literal={any}, bind_placeholder={any}, insert_compose={any}\n",
            .{ has_desc_col, has_routine_type, has_memory_type, has_empty_literal, has_bind_placeholder, has_insert_compose },
        );
        return error.DescriptionBranchMissing;
    }
}
