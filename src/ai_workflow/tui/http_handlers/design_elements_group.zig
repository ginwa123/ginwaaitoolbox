//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/group`.
//!
//! Create a new `group` (or `frame`) element at the union bbox of the
//! given `child_ids`, then set `parent_id` on each child to the new
//! group's id. Single-transaction, atomic via `design_model.groupElements`.
//!
//! Body: `{ child_ids: ["elem_a", "elem_b", ...],
//!         name?: string (default "Group"),
//!         type?: 'group'|'frame' (default 'group') }`.
//!
//! Response 201: `{ parent: <DesignElementResponse>,
//!                 children: [<DesignElementResponse>, ...] }`.
//!
//! Errors:
//!   - 400 missing/invalid body, `child_ids.len < 2`, invalid `type`,
//!     missing `page_id` path param
//!   - 404 `page_id` not found
//!   - 409 `ChildAlreadyParented` (a child already has a parent_id)
//!   - 500 DB / file-write failure
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

/// HTTP request body for the group-elements endpoint. `child_ids`
/// must contain at least 2 element ids (a single-element group is
/// not meaningful). `name` defaults to `"Group"` and `type` defaults
/// to `"group"` (non-clipping) at the handler boundary.
const GroupElementsBody = struct {
    child_ids: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (one for status, one for the user-facing message).
pub const DesignElementsGroupError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `child_ids.len < 2` — single-element group is not useful.
    TooFewChildren,
    /// `name` was empty (after default fallback).
    BadName,
    /// `type` field was not a valid `ElementType` enum variant.
    InvalidType,
    /// `design_model.groupElements` returned `PageNotFound`.
    PageNotFound,
    /// `design_model.groupElements` returned `BadChildId` (a child
    /// id didn't resolve to a row).
    BadChildId,
    /// `design_model.groupElements` returned `ItemPathMissing`.
    ItemPathMissing,
    /// `design_model.groupElements` returned
    /// `ChildAcrossDifferentPages`.
    ChildAcrossDifferentPages,
    /// `design_model.groupElements` returned `ChildAlreadyParented`.
    ChildAlreadyParented,
    /// `design_model.groupElements` returned `FileWriteFailed`
    /// (atomic-write of the group HTML failed).
    FileWriteFailed,
    /// `groupElements` failed for some other DB reason.
    DbError,
    /// Insert succeeded but the new element wasn't visible in the
    /// subsequent `getElement` (consistency violation).
    ParentNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the group-elements use-case.
pub const GroupElementsInput = struct {
    page_id: []const u8,
    workspace_id: []const u8,
    child_ids: []const []const u8,
    name: []const u8,
    elem_type: design_model.ElementType,
};

/// Output of the group-elements use-case.
pub const GroupElementsOutput = struct {
    /// The newly-created parent element.
    parent: design_model.DesignElement,
    /// The re-fetched children (post-reparent). Heap-owned by the
    /// use-case — `freeElement(allocator, ...)` per child on cleanup.
    children: []design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

/// Group 2+ elements into a new parent.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: GroupElementsInput,
) DesignElementsGroupError!GroupElementsOutput {
    if (input.page_id.len == 0) return error.PageIdRequired;
    if (input.name.len == 0) return error.BadName;

    // Delegate to the model. The model owns the transaction + on-disk
    // HTML + SSE emit; we just translate the error set.
    const new_id = design_model.groupElements(allocator, db, .{
        .page_id = input.page_id,
        .child_ids = input.child_ids,
        .parent_name = input.name,
        .parent_type = input.elem_type,
    }) catch |err| switch (err) {
        error.PageNotFound => return error.PageNotFound,
        error.BadChildId => return error.BadChildId,
        error.ItemPathMissing => return error.ItemPathMissing,
        error.ChildAcrossDifferentPages => return error.ChildAcrossDifferentPages,
        error.ChildAlreadyParented => return error.ChildAlreadyParented,
        error.FileWriteFailed => return error.FileWriteFailed,
        else => return error.DbError,
    };
    defer allocator.free(new_id);

    // Re-fetch the new parent + each reparented child for the
    // response. Free-then-build (errdefer) pattern: if any
    // `getElement` fails, free the parts we already have.
    const parent = design_model.getElement(allocator, db, new_id) catch return error.ParentNotVisible;
    errdefer design_model.freeElement(allocator, parent);

    // Build the children array via repeated getElement calls.
    var children: std.ArrayList(design_model.DesignElement) = .empty;
    errdefer {
        for (children.items) |c| design_model.freeElement(allocator, c);
        children.deinit(allocator);
    }
    for (input.child_ids) |cid| {
        const child = design_model.getElement(allocator, db, cid) catch return error.DbError;
        try children.append(allocator, child);
    }

    return .{
        .parent = parent,
        .children = try children.toOwnedSlice(allocator),
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designElementsGroupHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    const ws_id = req.params.get("workspace_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(GroupElementsBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Validate child_ids length. Figma convention: 2+ required.
    if (parsed.child_ids.len < 2) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "Select at least 2 elements to group",
            }),
        });
    }

    // 3. Apply defaults (Figma convention: "Group" + non-clipping).
    const name = parsed.name orelse "Group";
    const type_str = parsed.type orelse "group";

    // 4. Translate the wire `type` string to the ElementType enum.
    //    `std.meta.stringToEnum` returns `?T` — null on no match.
    const elem_type = std.meta.stringToEnum(design_model.ElementType, type_str) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "type must be one of: group, frame",
            }),
        });
    };
    // Reject .rectangle / .ellipse / .text / .image — the `/group`
    // endpoint is specifically for parent containers.
    if (elem_type != .group and elem_type != .frame) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "type must be one of: group, frame",
            }),
        });
    }

    // 5. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .workspace_id = ws_id,
        .child_ids = parsed.child_ids,
        .name = name,
        .elem_type = elem_type,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.BadName => 400,
            error.TooFewChildren => 400,
            error.InvalidType => 400,
            error.BadChildId => 400,
            error.ChildAcrossDifferentPages => 400,
            error.ItemPathMissing => 400,
            error.PageNotFound => 404,
            error.ChildAlreadyParented => 409,
            error.FileWriteFailed => 500,
            error.DbError => 500,
            error.ParentNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.BadName => "name is required",
            error.TooFewChildren => "Select at least 2 elements to group",
            error.InvalidType => "type must be one of: group, frame",
            error.BadChildId => "One or more child_ids is invalid",
            error.ChildAcrossDifferentPages => "All children must be on the same page",
            error.ItemPathMissing => "design item must have a path",
            error.PageNotFound => "Page not found",
            error.ChildAlreadyParented => "One or more children is already parented",
            error.FileWriteFailed => "Failed to write group HTML file",
            error.DbError => "Failed to group elements",
            error.ParentNotVisible => "Group was created but not visible",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned slices (no-op on arena).
    defer {
        design_model.freeElement(allocator, output.parent);
        for (output.children) |c| design_model.freeElement(allocator, c);
        allocator.free(output.children);
    }

    // 6. Build the success response (201 Created) with
    //    `{parent, children}` envelope.
    const Response = struct {
        parent: http_response.DesignElementResponse,
        children: []const http_response.DesignElementResponse,
    };
    const mapped = try allocator.alloc(http_response.DesignElementResponse, output.children.len);
    defer allocator.free(mapped);
    for (output.children, 0..) |c, i| mapped[i] = http_response.makeDesignElementResponse(c);

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{
                .parent = http_response.makeDesignElementResponse(output.parent),
                .children = mapped,
            },
            .{},
        ),
    });
}