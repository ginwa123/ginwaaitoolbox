//! `GET /api/workspaces/:id` — fetch a workspace by id.
//!
//! Layered as `useCase` (resolve singleton + read DB) and a thin
//! handler that maps the outcome + errors to status codes / JSON.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

pub const WorkspaceGetError = error{
    IdRequired,
    QueryFailed,
    RowFetchFailed,
};

/// Tagged outcome of the workspace-get use-case.
pub const WorkspaceGetResult = union(enum) {
    found: WorkspaceGetData,
    not_found,
};

pub const WorkspaceGetData = struct {
    id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    id: []const u8,
) WorkspaceGetError!WorkspaceGetResult {
    if (id.len == 0) return error.IdRequired;

    var rows = db.query(
        allocator,
        "SELECT id, name, created_at, updated_at FROM workspaces WHERE id = ?",
        &.{id},
    ) catch return error.QueryFailed;
    defer rows.deinit();

    const row = (rows.next() catch return error.RowFetchFailed) orelse return .not_found;
    defer row.deinit(allocator);
    return .{
        .found = .{
            .id = row.values[0],
            .name = row.values[1],
            .created_at = row.values[2],
            .updated_at = row.values[3],
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";

    const outcome = useCase(allocator, sqlite_db, id) catch |err| {
        const status: u16 = switch (err) {
            error.IdRequired => 400,
            error.QueryFailed, error.RowFetchFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdRequired => "id required",
            error.QueryFailed => "Database query failed",
            error.RowFetchFailed => "Failed to fetch row",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    switch (outcome) {
        .found => |data| {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try std.fmt.allocPrint(
                    allocator,
                    "{{\"id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\"}}",
                    .{ data.id, data.name, data.created_at, data.updated_at },
                ),
            });
        },
        .not_found => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = "{\"error\":\"Workspace not found\"}",
            });
        },
    }
}