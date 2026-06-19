const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const memories_mod = nalarcore.memories;

/// DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
///
/// For routine tasks, also deletes the matching row in the `routines`
/// table (CASCADE should handle this, but we delete it explicitly to
/// be safe — the scheduler must not pick up a routine whose task no
/// longer exists).
///
/// For memory tasks, also deletes the underlying .md file in
/// `<workspace_item.path>/.nalar/memories/<name>.md` so the file
/// system and the task list stay in sync. The .md deletion is
/// idempotent (the helper returns true on already-missing), so a
/// missing file at delete time is not an error.
pub fn tasksDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // Look up the task before deletion so we can clean up any
    // associated resources (routines row for routine tasks, .md
    // file for memory tasks). The task row is deleted last so the
    // helper sees a consistent DB state during the cleanup.
    const task_opt = ai_mod.workspace_item_tasks.getWorkspaceItemTask(allocator, sqlite_db, task_id) catch null;
    if (task_opt) |task| {
        defer task.deinit(allocator);

        // Memory-task cleanup: delete the .md file from
        // `<workspace_item.path>/.nalar/memories/<task_name>`. We
        // only attempt this if the parent workspace_item still
        // exists and has a path (otherwise the file is unreachable
        // anyway).
        if (std.mem.eql(u8, task.task_type, "memory")) {
            const item_opt = ai_mod.workspace_item_tasks.getWorkspaceItem(allocator, sqlite_db, task.workspace_item_id) catch null;
            if (item_opt) |item| {
                defer item.deinit(allocator);
                if (item.path) |cwd| {
                    if (memories_mod.get_local_memories_path_for_dir(allocator, cwd)) |dir_path| {
                        defer allocator.free(dir_path);
                        // The .md filename == task.name. The name
                        // passes isValidMemoryName today (the
                        // create handler validates it), but be
                        // defensive — the helper returns false
                        // safely on invalid input.
                        _ = memories_mod.deleteLocalMemoryFile(allocator, ctx.io, dir_path, task.name);
                    }
                }
            }
        }

        // Routine-task cleanup: delete the routines row. (Standard
        // tasks have no extra table; nothing to do.)
        if (std.mem.eql(u8, task.task_type, "routine")) {
            sqlite_db.exec(allocator,
                "DELETE FROM routines WHERE task_id = ?",
                &[_][]const u8{task_id},
            ) catch {
                return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete routine row" }) });
            };
        }
    }

    ai_mod.workspace_item_tasks.deleteWorkspaceItemTask(allocator, sqlite_db, task_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete task" }) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTaskDeleteResponse(allocator, .{ .id = task_id, .success = true }) });
}
