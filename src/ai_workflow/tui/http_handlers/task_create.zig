const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const memories_mod = nalarcore.memories;
const cron = @import("../routines/cron.zig");
const fire = @import("../routines/fire.zig");

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks
///
/// Body: { name, session_id?, task_type? ('standard'|'routine'|'memory'),
///         schedule?, initial_prompt?, enabled?,
///         memory_name?, memory_content? }.
///
/// Three task types are supported:
///
///  - **standard** (default): existing `createWorkspaceItemTask` path;
///    the migration's `task_type` column default is 'standard'.
///
///  - **routine**: inlines both the workspace_item_tasks INSERT (so we
///    can set task_type='routine' explicitly) and the routines INSERT.
///    The scheduler polls `routines` so the routines row is what makes
///    the task fire.
///
///  - **memory** (new): a local memory file scoped to the parent
///    workspace_item's directory. The .md file is created at
///    `<workspace_item.path>/.nalar/memories/<memory_name>` (the
///    directory is created if missing) so `loadLocalKnowledge` picks
///    it up on the next chat. The task row has `task_type='memory'`
///    and no `session_id` — the file is the content. Requires
///    `memory_name` (must pass `isValidMemoryName`) and `memory_content`
///    in the body.
///
/// Plans:
///  - docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md (routine)
///  - docs/plans/2026-06-20-add-markdown-memory.md (memory)
pub fn tasksCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    // Parse request body
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    // Generate task ID using timestamp
    const ts = std.Io.Timestamp.now(ctx.io, .real);
    const task_id = try std.fmt.allocPrint(allocator, "task_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)});

    // Routine branch — inlined (preserves the v1 routine flow). The
    // task_id is generated above; the routine path uses it for both
    // the workspace_item_tasks INSERT and the routines INSERT.
    if (std.mem.eql(u8, json_body.task_type, "routine")) {
        const schedule = json_body.schedule orelse {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "schedule is required for routine tasks" }) });
        };
        const initial_prompt = json_body.initial_prompt orelse {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "initial_prompt is required for routine tasks" }) });
        };
        cron.validate(schedule) catch {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid cron expression" }) });
        };
        const now_ns: i128 = ts.nanoseconds;
        const next_ns = cron.nextFireTime(schedule, now_ns) catch {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to compute next fire time" }) });
        };
        const next_run_at = try fire.formatSqliteDatetime(allocator, next_ns);
        defer allocator.free(next_run_at);

        if (json_body.session_id) |sid| {
            sqlite_db.exec(allocator,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id, task_type) VALUES (?, ?, ?, ?, 'routine')",
                &[_][]const u8{ task_id, json_body.name, item_id, sid },
            ) catch {
                return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
            };
        } else {
            sqlite_db.exec(allocator,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES (?, ?, ?, 'routine')",
                &[_][]const u8{ task_id, json_body.name, item_id },
            ) catch {
                return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
            };
        }

        const routine_id = try std.fmt.allocPrint(allocator, "routine_{s}", .{task_id});
        defer allocator.free(routine_id);
        const enabled_str = if (json_body.enabled) "1" else "0";
        sqlite_db.exec(allocator,
            "INSERT INTO routines (id, task_id, schedule, initial_prompt, enabled, next_run_at) VALUES (?, ?, ?, ?, ?, ?)",
            &[_][]const u8{ routine_id, task_id, schedule, initial_prompt, enabled_str, next_run_at },
        ) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create routine row" }) });
        };

        const session_id_json: []const u8 = if (json_body.session_id) |sid|
            try std.fmt.allocPrint(allocator, "\"{s}\"", .{sid})
        else
            "null";
        return res.jsonResponse(.{ .status_code = 201, .data = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","name":"{s}","workspace_item_id":"{s}","task_type":"routine","session_id":{s},"created_at":null,"updated_at":null}}
        , .{
            task_id,
            json_body.name,
            item_id,
            session_id_json,
        }) });
    }

    // Memory branch — new in 2026-06-20. Resolves the parent
    // workspace_item's `path`, builds the local memories dir,
    // validates the memory name, writes the .md file, then inserts
    // a single task row with `task_type='memory'` and no
    // `session_id`. The file is the content; there is no chat
    // session for memory tasks.
    if (std.mem.eql(u8, json_body.task_type, "memory")) {
        // 1. Validate the memory-specific body fields.
        const memory_name = json_body.memory_name orelse {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "memory_name is required for memory tasks" }) });
        };
        if (!memories_mod.isValidMemoryName(memory_name)) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid memory name (must end in .md, no /, no ..)" }) });
        }
        const memory_content = json_body.memory_content orelse {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "memory_content is required for memory tasks" }) });
        };

        // 2. Look up the parent workspace_item to get its `path`
        // (this is the project root — the .md file is scoped to
        // `<path>/.nalar/memories/<name>.md`).
        const item_opt = ai_mod.workspace_item_tasks.getWorkspaceItem(allocator, sqlite_db, item_id) catch null;
        const item = item_opt orelse {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found" }) });
        };
        defer item.deinit(allocator);

        // 3. Refuse non-folder items. The agent's loadLocalKnowledge
        // reads from `<cwd>/.nalar/memories/`, so the cwd must be a
        // real directory (which is what a 'folder' item's path is).
        if (!std.mem.eql(u8, item.item_type, "folder")) {
            return res.jsonResponse(.{ .status_code = 400, .data = try std.fmt.allocPrint(allocator, "Memory tasks can only be added to folder-type workspace items (item has type '{s}')", .{item.item_type}) });
        }
        const cwd = item.path orelse {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item has no path; the folder must have been created with a real path" }) });
        };

        // 4. Build the local memories dir: <cwd>/.nalar/memories/.
        const dir_path = memories_mod.get_local_memories_path_for_dir(allocator, cwd) orelse {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to build local memories path" }) });
        };
        defer allocator.free(dir_path);

        // 5. Write the .md file. Creates `<dir>/.nalar/memories/`
        // if missing; uses atomic-rename.
        if (!memories_mod.writeLocalMemoryFile(allocator, ctx.io, dir_path, memory_name, memory_content)) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to write memory file" }) });
        }

        // 6. Insert the task row. No session_id for memory tasks —
        // the file IS the content.
        sqlite_db.exec(allocator,
            "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES (?, ?, ?, 'memory')",
            &[_][]const u8{ task_id, json_body.name, item_id },
        ) catch {
            // Roll back the file on task-row failure so we don't leave
            // an orphan .md with no task pointing at it. The helper is
            // idempotent (returns true on already-missing), so this is
            // safe even if the file disappeared in the meantime.
            _ = memories_mod.deleteLocalMemoryFile(allocator, ctx.io, dir_path, memory_name);
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task row" }) });
        };

        return res.jsonResponse(.{ .status_code = 201, .data = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","name":"{s}","workspace_item_id":"{s}","task_type":"memory","session_id":null,"created_at":null,"updated_at":null}}
        , .{
            task_id,
            json_body.name,
            item_id,
        }) });
    }

    // Standard task path — unchanged from the pre-routines code.
    const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(allocator, sqlite_db, task_id, json_body.name, item_id, json_body.session_id, "standard") catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
    };
    defer task.deinit(allocator);

    // ─── Kanban auto-assign ────────────────────────────────────────────────
    // If the parent item is a kanban (`item_type='kanban'`), auto-assign
    // this task to the first column (by `position` ASC) at
    // `MAX(kanban_position) + 1` so the card lands at the bottom of the
    // "todo" (or first) column without the frontend having to send a
    // separate `PATCH /tasks/:id/move` call.
    //
    // For non-kanban items (folder / chat / memory), `kanban_column_id`
    // stays NULL (the column is `NULL` per Migration 051). The
    // frontend's folder-list view shows these as "Unassigned".
    //
    // Errors here are non-fatal — the task row is already created and
    // the response can succeed. Log and move on.
    {
        // Query the parent item's type via SQL. Using `WHERE id = ? AND
        // item_type = 'kanban'` keeps the kanban-check co-located with
        // the lookup; if the SELECT returns no row, the parent is
        // either missing or not a kanban, and we skip the auto-assign.
        const parent_is_kanban = blk: {
            var q = try sqlite_db.query(allocator,
                "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'",
                &.{item_id});
            defer q.deinit();
            const row = (try q.next()) orelse break :blk false;
            defer row.deinit(allocator);
            break :blk true;
        };

        if (parent_is_kanban) {
            const first_col_id = blk: {
                var q = try sqlite_db.query(allocator,
                    "SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
                    &.{item_id});
                defer q.deinit();
                const row = (try q.next()) orelse break :blk null;
                defer row.deinit(allocator);
                break :blk try allocator.dupe(u8, row.values[0]);
            };
            if (first_col_id) |col_id| {
                defer allocator.free(col_id);
                sqlite_db.exec(allocator,
                    "UPDATE workspace_item_tasks SET kanban_column_id = ?, kanban_position = (SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM workspace_item_tasks WHERE kanban_column_id = ?) WHERE id = ?",
                    &.{ col_id, col_id, task_id },
                ) catch |err| {
                    std.log.warn("task_create: kanban auto-assign failed (non-fatal): {s}", .{@errorName(err)});
                };
            }
        }
    }

    // Re-read the kanban fields after the auto-assign UPDATE above so
    // the 201 response carries `kanban_column_id` + `kanban_position`.
    // Without this, the frontend's `workspacesStore.addTask` would
    // push a task with `kanban_column_id = undefined` into
    // `item.tasks`, and `KanbanColumn.vue`'s `.filter((t) =>
    // t.kanban_column_id === props.column.id)` would drop the card
    // (it appears on the kanban sidebar but is invisible inside the
    // column until a full page reload triggers `getTasks`). SELECT
    // returns "" (empty string) for NULL per the SqliteBackend
    // convention — convert to `null` for JSON. The owned dupe keeps
    // the slice alive past `row.deinit` so we can use it in
    // `kanban_json` below.
    var kanban_column_id: ?[]u8 = null;
    var kanban_position: i64 = 0;
    {
        var q = try sqlite_db.query(allocator,
            "SELECT kanban_column_id, COALESCE(kanban_position, 0) FROM workspace_item_tasks WHERE id = ?",
            &.{task_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len > 0) {
                kanban_column_id = try allocator.dupe(u8, row.values[0]);
            }
            kanban_position = std.fmt.parseInt(i64, row.values[1], 10) catch 0;
        }
    }
    defer if (kanban_column_id) |cid| allocator.free(cid);

    const session_id_json: []const u8 = if (json_body.session_id) |sid|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{sid})
    else
        "null";
    // Build the kanban fields JSON. `null` (not the string "null")
    // for column when unassigned; number for position. Defaults match
    // `WorkspaceItemTaskResponse.kanban_column_id: ?[]const u8` and
    // `kanban_position: i64 = 0` in http_response.zig.
    const kanban_json: []const u8 = blk: {
        if (kanban_column_id) |cid| {
            break :blk try std.fmt.allocPrint(allocator,
                "\"kanban_column_id\":\"{s}\",\"kanban_position\":{d}",
                .{ cid, kanban_position });
        }
        break :blk "\"kanban_column_id\":null,\"kanban_position\":0";
    };
    return res.jsonResponse(.{ .status_code = 201, .data = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"name\":\"{s}\",\"workspace_item_id\":\"{s}\",\"task_type\":\"standard\",\"session_id\":{s},{s}}}",
        .{
            task.id,
            task.name,
            task.workspace_item_id,
            session_id_json,
            kanban_json,
        }) });
}
