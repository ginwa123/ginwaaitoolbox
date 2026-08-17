//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/ungroup`.
//!
//! Dissolve a `group` or `frame` element: reparent its children to
//! the group's parent (or NULL if the group was top-level), then
//! delete the group row. Children keep their absolute x/y — their
//! geometry is independent of the group's bbox.
//!
//! Body: `{ element_id: "elem_g" }`.
//!
//! Response 200: `{ orphaned: <DesignElementResponse>[] }` (the
//! newly-top-level children in their new state).
//!
//! Errors:
//!   - 400 BadGroupId, NotAGroup, EmptyGroup
//!   - 404 PageNotFound
//!   - 500 DbError, OutOfMemory
//!
//! Plan: docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md
//! (Chunk 9 deferred item, now landing)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

const UngroupBody = struct {
    element_id: []const u8,
};

pub fn designElementsUngroupHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UngroupBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_id required" }),
        });
    }

    const orphaned = design_model.ungroupElements(allocator, sqlite_db, .{
        .page_id = page_id,
        .element_id = parsed.element_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.BadGroupId => 400,
            error.NotAGroup => 400,
            error.EmptyGroup => 400,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.BadGroupId => "element_id is invalid or does not exist on this page",
            error.NotAGroup => "element must be a group or frame",
            error.EmptyGroup => "group has no children — nothing to ungroup",
            error.DbError => "Failed to ungroup elements",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer {
        for (orphaned) |c| design_model.freeElement(allocator, c);
        allocator.free(orphaned);
    }

    const Response = struct {
        orphaned: []const http_response.DesignElementResponse,
    };
    const mapped = try allocator.alloc(http_response.DesignElementResponse, orphaned.len);
    defer allocator.free(mapped);
    for (orphaned, 0..) |c, i| mapped[i] = http_response.makeDesignElementResponse(c);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{ .orphaned = mapped },
            .{},
        ),
    });
}