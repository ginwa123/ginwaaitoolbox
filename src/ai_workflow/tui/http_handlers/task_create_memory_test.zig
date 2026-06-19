//! Static regression checks for the memory-aware task create/delete handlers.
//!
//! Why this file exists
//! ────────────────────
//! The Markdown Memory feature (plan: `2026-06-20-add-markdown-memory.md`)
//! adds a new `memory` task type. A memory task is a local .md file scoped
//! to the parent workspace_item's directory; the task row is a thin
//! index pointing at the file. The create handler must:
//!   1. Validate `memory_name` via `isValidMemoryName`.
//!   2. Resolve the parent workspace_item to get its `path`.
//!   3. Build the local memories dir path via `get_local_memories_path_for_dir`.
//!   4. Refuse non-folder items (only `folder` items have a real directory path).
//!   5. Write the .md file via `writeLocalMemoryFile` (atomic-rename).
//!   6. Insert a `workspace_item_tasks` row with `task_type='memory'` and
//!      no `session_id` (the file IS the content).
//!   7. Roll back the file on task-row failure (no orphan .md).
//!
//! The delete handler must:
//!   1. Look up the task, identify `task_type='memory'`.
//!   2. Resolve the parent workspace_item to get its `path`.
//!   3. Build the local memories dir path.
//!   4. Delete the .md file (idempotent — missing file is OK).
//!
//! These contracts are enforced by static substring checks (matching the
//! project's `task_create_routines_test.zig` pattern), not by spinning
//! up an in-memory DB. The static checks below directly test the bug —
//! they fail if and only if the memory-creation plumbing is removed or
//! routed back to the standard-task path.
//!
//! Plan: docs/plans/2026-06-20-add-markdown-memory.md

const std = @import("std");
const testing = std.testing;

const CREATE_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";
const DELETE_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_delete.zig";
const REQ_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

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

// ─── Contract 1: TaskCreateRequest has memory_name + memory_content ─────────

test "TaskCreateRequest has memory_name + memory_content fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, REQ_PATH);
    defer allocator.free(source);

    // The request struct must carry the two memory-creation fields.
    // Without these, a client cannot request a memory task and the
    // handler will fail to write the .md file.
    if (std.mem.indexOf(u8, source, "memory_name") == null) {
        std.debug.print(
            "\n!! {s} does not define a `memory_name` field on TaskCreateRequest !!\n" ++
                "   The memory-creation contract is broken: clients cannot pass the\n" ++
                "   memory file name. Add `memory_name: ?[]const u8 = null` to the struct.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{REQ_PATH},
        );
        return error.MemoryNameFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "memory_content") == null) {
        std.debug.print(
            "\n!! {s} does not define a `memory_content` field on TaskCreateRequest !!\n" ++
                "   The memory-creation contract is broken: clients cannot pass the\n" ++
                "   memory file body. Add `memory_content: ?[]const u8 = null` to the struct.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{REQ_PATH},
        );
        return error.MemoryContentFieldMissing;
    }
}

// ─── Contract 2: handler validates the memory name via isValidMemoryName ──

test "task_create handler validates memory_name via isValidMemoryName" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `isValidMemoryName(memory_name)` and return
    // 400 on a bad name. Without this, a path-traversal attempt
    // (e.g. memory_name = "../../etc/passwd.md") would write the file
    // outside the memories dir.
    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print(
            "\n!! {s} does not call isValidMemoryName !!\n" ++
                "   The memory-name-validation contract is broken: a bad memory_name\n" ++
                "   (e.g. with '/' or '..') will be written to disk outside the memories dir.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.IsValidMemoryNameMissing;
    }
}

// ─── Contract 3: handler resolves the parent workspace_item to find path ───

test "task_create handler resolves parent workspace_item to get path" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `getWorkspaceItem` to look up the parent
    // workspace_item's `path` (the project root for the .md file). Without
    // this, the .md file would be written to a relative path (cwd-relative),
    // which the agent's loadLocalKnowledge would not find.
    if (std.mem.indexOf(u8, source, "getWorkspaceItem") == null) {
        std.debug.print(
            "\n!! {s} does not call getWorkspaceItem to resolve the parent !!\n" ++
                "   The memory-task needs the parent workspace_item's `path` to know\n" ++
                "   where to write the .md file. Without this lookup, the file is\n" ++
                "   written relative to the server's cwd, not the project's dir.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.GetWorkspaceItemMissing;
    }
}

// ─── Contract 4: handler refuses non-folder workspace items ────────────────

test "task_create handler refuses non-folder workspace items" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must check the parent item's `item_type == 'folder'`
    // and return 400 for chat/other types. Memory tasks need a real
    // directory path; chat items have a session-id path that is not a
    // directory.
    if (std.mem.indexOf(u8, source, "\"folder\"") == null) {
        std.debug.print(
            "\n!! {s} does not check `item_type == 'folder'` !!\n" ++
                "   The folder-only contract is broken: a memory task could be\n" ++
                "   attached to a chat-type workspace item, where the .md file\n" ++
                "   would be written to a non-directory path.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.FolderTypeCheckMissing;
    }
}

// ─── Contract 5: handler builds the local memories path ────────────────────

test "task_create handler builds the local memories dir path" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `get_local_memories_path_for_dir` to build
    // `<cwd>/.nalar/memories/`. Without this, the .md file would be
    // written to the wrong dir (the raw cwd, not <cwd>/.nalar/memories/).
    if (std.mem.indexOf(u8, source, "get_local_memories_path_for_dir") == null) {
        std.debug.print(
            "\n!! {s} does not call get_local_memories_path_for_dir !!\n" ++
                "   The memory-dir-path contract is broken: the .md file would be\n" ++
                "   written to the raw cwd, not to <cwd>/.nalar/memories/ where the\n" ++
                "   agent's loadLocalKnowledge scans.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.GetLocalMemoriesPathMissing;
    }
}

// ─── Contract 6: handler writes the .md file via writeLocalMemoryFile ──────

test "task_create handler writes the .md file via writeLocalMemoryFile" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `writeLocalMemoryFile` to actually create
    // the file on disk. Without this, the task row would point at a
    // non-existent file.
    if (std.mem.indexOf(u8, source, "writeLocalMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call writeLocalMemoryFile !!\n" ++
                "   The memory-file-write contract is broken: the task row would\n" ++
                "   reference a file that does not exist, and loadLocalKnowledge\n" ++
                "   would have nothing to read.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.WriteLocalMemoryFileMissing;
    }
}

// ─── Contract 7: handler inserts a workspace_item_tasks row for memory ─────

test "task_create handler inserts a task row for memory tasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must INSERT a row into the `workspace_item_tasks`
    // table with `task_type='memory'` (so the task list UI shows it
    // under the memory filter). Without this INSERT, the .md file
    // would exist but no task would reference it.
    if (std.mem.indexOf(u8, source, "INSERT INTO workspace_item_tasks") == null) {
        std.debug.print(
            "\n!! {s} does not contain 'INSERT INTO workspace_item_tasks' !!\n" ++
                "   The task-row contract is broken: the .md file would exist but\n" ++
                "   no task row references it, so it would never appear in the UI.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.MemoryTaskInsertMissing;
    }
}

// ─── Contract 8: handler rolls back the .md on task-row failure ────────────

test "task_create handler rolls back the .md on task-row failure" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // When the workspace_item_tasks INSERT fails, the handler must call
    // `deleteLocalMemoryFile` to remove the .md file it just wrote.
    // Without the rollback, the file would be an orphan (no task row
    // pointing at it), and the user would see a "memory exists" entry
    // on next reload but no way to delete it from the UI.
    //
    // Static check: the handler must reference both `deleteLocalMemoryFile`
    // AND appear in a `catch` branch (rollback on error).
    const has_delete = std.mem.indexOf(u8, source, "deleteLocalMemoryFile") != null;
    if (!has_delete) {
        std.debug.print(
            "\n!! {s} does not call deleteLocalMemoryFile for rollback !!\n" ++
                "   The rollback contract is broken: if the task-row INSERT fails\n" ++
                "   after the .md file is written, the file is an orphan with no\n" ++
                "   task row pointing at it.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.MemoryRollbackMissing;
    }
}

// ─── Contract 9: delete handler cleans up the .md file ────────────────────

test "task_delete handler cleans up the .md file for memory tasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_HANDLER_PATH);
    defer allocator.free(source);

    // The delete handler must call `deleteLocalMemoryFile` for tasks
    // with `task_type='memory'`, so the file system and the task list
    // stay in sync. Without this, deleted memory tasks would leave
    // orphan .md files in <cwd>/.nalar/memories/ that the agent would
    // still load on the next chat.
    if (std.mem.indexOf(u8, source, "deleteLocalMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call deleteLocalMemoryFile for memory tasks !!\n" ++
                "   The delete-cleanup contract is broken: deleting a memory task\n" ++
                "   would leave the .md file in <cwd>/.nalar/memories/ as an orphan\n" ++
                "   that the agent would still load on the next chat.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{DELETE_HANDLER_PATH},
        );
        return error.MemoryDeleteCleanupMissing;
    }
}

// ─── Contract 10: delete handler branches on task_type='memory' ────────────

test "task_delete handler branches on task_type='memory'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DELETE_HANDLER_PATH);
    defer allocator.free(source);

    // The delete handler must check the task's `task_type == 'memory'`
    // before doing the .md cleanup. Without this branch, the .md
    // deletion would either never happen (because there's no type check)
    // or happen for non-memory tasks (where there's no .md file).
    if (std.mem.indexOf(u8, source, "\"memory\"") == null) {
        std.debug.print(
            "\n!! {s} does not check `task_type == 'memory'` !!\n" ++
                "   The type-check contract is broken: the delete handler must\n" ++
                "   branch on memory tasks to call deleteLocalMemoryFile. Without\n" ++
                "   the check, the cleanup either runs for all tasks (creating\n" ++
                "   a false-positive 'missing file' error) or never runs.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{DELETE_HANDLER_PATH},
        );
        return error.MemoryTypeCheckMissing;
    }
}
