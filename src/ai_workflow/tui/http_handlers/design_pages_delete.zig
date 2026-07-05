//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Removes a design page row. Idempotent: deleting a missing page
//! returns 200 with `deleted: false` (matches the `deletePage`
//! model contract). Emits a `design_page_deleted` SSE event on
//! success so other connected clients refresh their tab strip.
//!
//! Errors:
//!   - 400 missing path params
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.6).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

pub fn designPagesDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";
    if (workspace_id.len == 0 or item_id.len == 0 or page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id, item_id, and page_id required" }),
        });
    }

    const di = try nalarcore.getSingleton();

    // Look up the page name BEFORE deletion so we can emit it in the
    // SSE event (the row vanishes on delete). If the row is missing,
    // skip the lookup and treat the request as a no-op.
    var page_name_buf: [256]u8 = undefined;
    var page_name: []const u8 = "";
    if (design_model.getPage(allocator, di.db, page_id)) |page| {
        defer design_model.freePageFull(allocator, page);
        const len = @min(page.name.len, page_name_buf.len);
        @memcpy(page_name_buf[0..len], page.name[0..len]);
        page_name = page_name_buf[0..len];
    } else |err| switch (err) {
        error.PageNotFound => {
            // Page doesn't exist — return idempotent 200.
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try std.json.Stringify.valueAlloc(allocator, struct {
                    deleted: bool = false,
                    page_id: []const u8,
                }{ .page_id = page_id }, .{}),
            });
        },
        else => return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to look up design page" }),
        }),
    }

    _ = design_model.deletePage(allocator, di.db, page_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete design page" }),
        });
    };

    // Fire-and-forget SSE event.
    on_event_sent_design.onEventSendDesignPageDeleted(allocator, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .page_id = page_id,
        .page_name = page_name,
    });

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, struct {
            deleted: bool = true,
            page_id: []const u8,
        }{ .page_id = page_id }, .{}),
    });
}