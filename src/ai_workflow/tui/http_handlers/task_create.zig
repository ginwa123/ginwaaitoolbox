const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const cron = @import("../routines/cron.zig");
const fire = @import("../routines/fire.zig");

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks
///
/// Body: { name, session_id?, task_type? ('standard'|'routine'),
///         schedule?, initial_prompt?, enabled? }.
///
/// Standard tasks (the default) take the existing
/// `createWorkspaceItemTask` path which lets the migration's
/// `task_type` column default to 'standard'.
///
/// Routine tasks inline the workspace_item_tasks INSERT (so we can
/// set `task_type='routine'` explicitly), then validate the cron
/// expression, compute the first `next_run_at` via
/// `cron.nextFireTime` + `fire.formatSqliteDatetime`, and INSERT a
/// matching row into the `routines` table. The scheduler polls
/// `routines` (not `workspace_item_tasks`) so the routines row is
/// what makes the task actually fire.
///
/// Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md
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

    // Branch on task_type. The routine path inlines both the
    // workspace_item_tasks INSERT (so we can set task_type='routine'
    // explicitly) and the routines INSERT. The standard path keeps
    // using createWorkspaceItemTask — the migration's column default
    // is 'standard', so the 6-arg signature still produces a
    // well-formed row.
    const is_routine = std.mem.eql(u8, json_body.task_type, "routine");
    if (is_routine) {
        // Routine-specific validation + initial next_run_at computation.
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

        // Inline the workspace_item_tasks INSERT for routines so we can
        // set task_type='routine' explicitly. The migration added the
        // column with default 'standard', so the standard path's
        // `createWorkspaceItemTask` call (below) is unaffected.
        if (json_body.session_id) |sid| {
            sqlite_db.exec(allocator,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id, task_type) VALUES (?, ?, ?, ?, 'routine')",
                &.{ task_id, json_body.name, item_id, sid },
            ) catch {
                return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
            };
        } else {
            sqlite_db.exec(allocator,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES (?, ?, ?, 'routine')",
                &.{ task_id, json_body.name, item_id },
            ) catch {
                return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
            };
        }

        // Insert the routines row in the same handler call. The
        // scheduler reads from this table; without the row, the
        // routine would never fire.
        const routine_id = try std.fmt.allocPrint(allocator, "routine_{s}", .{task_id});
        defer allocator.free(routine_id);
        const enabled_str = if (json_body.enabled) "1" else "0";
        sqlite_db.exec(allocator,
            "INSERT INTO routines (id, task_id, schedule, initial_prompt, enabled, next_run_at) VALUES (?, ?, ?, ?, ?, ?)",
            &.{ routine_id, task_id, schedule, initial_prompt, enabled_str, next_run_at },
        ) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create routine row" }) });
        };

        return res.jsonResponse(.{ .status_code = 201, .data = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}","name":"{s}","workspace_item_id":"{s}","task_type":"routine","session_id":{f},"created_at":null,"updated_at":null}}
        , .{
            task_id,
            json_body.name,
            item_id,
            // session_id may be null; emit JSON null literally
            // rather than going through std.json.Stringify (the
            // WorkspaceItemTaskResponse struct doesn't yet carry
            // task_type / routine — those land in Task 4.5).
            if (json_body.session_id) |sid| std.fmt.comptimePrint("\"{s}\"", .{sid}) else "null",
        }) });
    }

    // Standard task path — unchanged from the pre-routines code.
    const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(allocator, sqlite_db, task_id, json_body.name, item_id, json_body.session_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
    };
    defer task.deinit(allocator);

    return res.jsonResponse(.{ .status_code = 201, .data = try http_response.makeWorkspaceItemTaskResponse(allocator, http_response.WorkspaceItemTaskResponse{
        .id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .session_id = task.session_id,
        .created_at = task.created_at,
        .updated_at = task.updated_at,
    }) });
}
