//! `PATCH /api/agents/:agent_id/knowledge/:knowledge_id`.
//!
//! Updates file_path and/or label of an existing knowledge entry.
//! Body: `{file_path?, label?}` (both optional; at least one required).
//! `file_path` MUST be absolute if provided.
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 6)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

const UpdateKnowledgeBody = struct {
    file_path: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

pub fn agentKnowledgeUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const knowledge_id = req.params.get("knowledge_id") orelse "";
    if (agent_id.len == 0 or knowledge_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "agent_id and knowledge_id required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.file_path == null and parsed.label == null) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "file_path or label required" }),
        });
    }

    if (parsed.file_path) |fp| {
        if (!std.fs.path.isAbsolute(fp)) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "file_path must be absolute" }),
            });
        }
    }

    // Build dynamic UPDATE SQL into an owned ArrayList. Zig 0.16 dropped
    // std.io.fixedBufferStream, so we use appendSlice for the static
    // SQL fragments and std.fmt for the position-number interpolation.
    var sql_list: std.ArrayList(u8) = .empty;
    defer sql_list.deinit(allocator);
    try sql_list.appendSlice(allocator, "UPDATE agent_knowledge SET updated_at = datetime('now')");
    if (parsed.file_path != null) try sql_list.appendSlice(allocator, ", file_path = ?");
    if (parsed.label != null) try sql_list.appendSlice(allocator, ", label = ?");
    try sql_list.appendSlice(allocator, " WHERE id = ? AND agent_id = ?");

    // Bind args.
    var args_buf: [3][]const u8 = undefined;
    var arg_idx: usize = 0;
    if (parsed.file_path) |fp| {
        args_buf[arg_idx] = fp;
        arg_idx += 1;
    }
    if (parsed.label) |lb| {
        args_buf[arg_idx] = lb;
        arg_idx += 1;
    }
    args_buf[arg_idx] = knowledge_id;
    arg_idx += 1;
    args_buf[arg_idx] = agent_id;
    arg_idx += 1;

    const sql = sql_list.items;

    // Build argv slice for db.exec — pass an owned slice.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    for (args_buf[0..arg_idx]) |a| try argv_list.append(allocator, a);

    sqlite_db.exec(allocator, sql, argv_list.items) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update knowledge" }),
        });
    };

    // Read back.
    var q = sqlite_db.query(allocator,
        "SELECT id, agent_id, file_path, label, position FROM agent_knowledge WHERE id = ?",
        &[_][]const u8{knowledge_id},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read row" }),
        });
    };
    defer q.deinit();
    const r = (q.next() catch null) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "knowledge row not found" }),
        });
    };
    defer r.deinit(allocator);
    const position = std.fmt.parseInt(i64, r.values[4], 10) catch 0;

    const envelope = .{
        .id = r.values[0],
        .agent_id = r.values[1],
        .file_path = r.values[2],
        .label = r.values[3],
        .position = position,
    };
    const data = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}