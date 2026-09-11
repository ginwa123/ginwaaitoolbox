const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const http_response = nalarcore.http_response;

pub const WorkspaceUpdateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    MissingName,
    NameNotString,
    DatabaseError,
};

/// PUT /api/workspaces/:id
pub fn workspaceUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "id is required" }) });
    }

    const result = useCase(allocator, sqlite_db, id, req.body) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidJson, error.MissingBody, error.MissingName, error.NameNotString => 400,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "name is required",
            error.MissingName => "name is required",
            error.NameNotString => "name must be a string",
            error.DatabaseError => "Failed to update workspace",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ result.id, result.name }) });
}

const WorkspaceUpdateResult = struct {
    id: []const u8,
    name: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *nalarcore.sqlite.SqliteBackend,
    id: []const u8,
    body: []const u8,
) WorkspaceUpdateError!WorkspaceUpdateResult {
    if (body.len == 0) return error.MissingBody;

    // Per the project memory (nalar-http-handler-thin-wrapper-pattern.md),
    // the per-request arena allocator (`allocator`) is the per-request
    // arena, so parseFromSliceLeaky is the correct API — its internal
    // arena lifetime matches our handler's lifetime.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    const root = parsed.object;

    const name_val = root.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.NameNotString;

    sqlite_db.exec(allocator,
        "UPDATE workspaces SET name = ?, updated_at = datetime('now') WHERE id = ?",
        &[_][]const u8{ name_val.string, id },
    ) catch {
        return error.DatabaseError;
    };

    return .{ .id = id, .name = name_val.string };
}