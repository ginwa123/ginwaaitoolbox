//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! Create (or idempotently upsert) a design page for a workspace item
//! of `item_type='design'`. Delegates to `design_model.setDesignPage`,
//! which is itself idempotent: calling twice with the same `(item_id,
//! page_name)` returns the same id and updates `width`/`height`.
//!
//! Body: `{name: string, width?: number=1440, height?: number=1024}`.
//! Defaults match the Figma-lite 1440×1024 canvas from §5.1 of the
//! design doc.
//!
//! Response shape: `DesignPageResponse` for the new (or updated)
//! page. Built by `http_response.makeDesignPageResponse` and wrapped
//! via `std.json.Stringify.valueAlloc`.
//!
//! Layered as:
//!   - `useCase` — business logic (validate → call setDesignPage →
//!     re-fetch via listPages → return heap-owned `DesignPage`).
//!   - `designPagesCreateHandler` — thin orchestrator over `useCase`:
//!     parses the HTTP request, resolves the singleton DB handle,
//!     delegates to `useCase`, maps the use-case outcome to an HTTP
//!     response (201 / 400 / 500).
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/empty `name`, missing
//!     `item_id` path param, page name validation failed, design
//!     item has no `path` set
//!   - 500 DB failure (insert, fetch, or consistency violation)
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../../../agentic_loop/design_model.zig");

/// HTTP request body for page-create. Decoupled from the
/// `SetDesignPageInput` domain struct so the wire format can evolve
/// independently (e.g. adding `?` optional fields) without touching
/// the use-case. `width` / `height` default to the Figma-lite
/// 1440×1024 canvas (per design §5.1).
const CreatePageBody = struct {
    name: []const u8,
    width: ?i64 = null,
    height: ?i64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (one for status, one for the user-facing message).
///
/// Adding a new variant fails to compile in the handler until both
/// switches are updated — that's intentional, to keep status codes
/// in lockstep with the error set.
pub const DesignPageCreateError = error{
    /// `:item_id` path param was missing or empty.
    ItemIdRequired,
    /// Body `name` field was empty (matches `design_model.BadPageName`).
    BadPageName,
    /// `design_model.setDesignPage` returned `ItemPathMissing`
    /// (the parent workspace_item has no `path`).
    ItemPathMissing,
    /// `setDesignPage` failed for some other DB reason.
    DbError,
    /// Insert succeeded but the new page wasn't visible in the
    /// subsequent `listPages` (consistency violation — extremely
    /// unlikely; surfaces as 500 so the caller can re-fetch).
    PageNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the create-page use-case. The handler maps the parsed
/// HTTP body into this struct; the use-case is then transport-agnostic.
pub const CreatePageInput = struct {
    item_id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
};

/// Output of the create-page use-case.
pub const CreatePageOutput = struct {
    /// The freshly-created (or idempotently-upserted) page. The slice
    /// fields are HEAP-OWNED by the use-case: the use-case duplicates
    /// them out of the `listPages` result so the output survives the
    /// useCase's internal `freePages` defer (and any later
    /// `freePages(pages)` that runs in the caller).
    ///
    /// The caller MUST free the per-field slices (or pass the whole
    /// struct to `design_model.freePages` wrapped in a single-element
    /// array). The same ownership pattern as the kanban column
    /// create handler.
    page: design_model.DesignPage,
};

// =====================================================================
// Use case
// =====================================================================

/// Create (or upsert) a design page.
///
/// Steps:
///   1. Validate `item_id` and `name`.
///   2. Call `design_model.setDesignPage` (which is idempotent).
///   3. Re-query via `design_model.listPages` to fetch the full row
///      (setDesignPage only returns the id).
///   4. Locate the new page by its id.
///   5. Return a heap-owned `DesignPage` for the response.
///
/// The use-case is intentionally allocator-agnostic: it works for
/// both the per-request arena (production HTTP handler) and a
/// leak-tracker allocator (unit tests). All allocations are paired
/// with `errdefer` / `defer` for non-arena safety.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: CreatePageInput,
) DesignPageCreateError!CreatePageOutput {
    // 1. Validate. Empty `item_id` → no parent design item; empty
    //    `name` → `design_model.BadPageName` (and the DB column is
    //    NOT NULL anyway).
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.name.len == 0) return error.BadPageName;

    // 2. Insert (or upsert) the page. `setDesignPage` returns a
    //    freshly-generated id (allocated from `allocator`) for new
    //    pages, or the existing id for upserts. Free it via defer.
    const new_id = design_model.setDesignPage(allocator, db, .{
        .item_id = input.item_id,
        .page_name = input.name,
        .width = input.width,
        .height = input.height,
    }) catch |err| switch (err) {
        error.BadPageName => return error.BadPageName,
        error.ItemPathMissing => return error.ItemPathMissing,
        else => return error.DbError,
    };
    defer allocator.free(new_id);

    // 3. Re-query to get the full row (we need `created_at` +
    //    `workspace_item_id` + `position` for the response, which
    //    setDesignPage does not return).
    const pages = design_model.listPages(allocator, db, input.item_id) catch return error.DbError;
    defer design_model.freePages(allocator, pages);

    // 4. Locate the new page by its id.
    for (pages) |p| {
        if (!std.mem.eql(u8, p.id, new_id)) continue;

        // 5. Duplicate the matched page's slices so the output
        //    survives the `freePages(pages)` defer above.
        //    `errdefer` reverts each successful dupe if a later dupe
        //    fails (the partial state would otherwise leak).
        var duped_id: ?[]u8 = null;
        var duped_workspace_item_id: ?[]u8 = null;
        var duped_name: ?[]u8 = null;
        var duped_workspace_item_task_id: ?[]u8 = null;
        var duped_created_at: ?[]u8 = null;
        var duped_updated_at: ?[]u8 = null;
        errdefer {
            if (duped_id) |v| allocator.free(v);
            if (duped_workspace_item_id) |v| allocator.free(v);
            if (duped_name) |v| allocator.free(v);
            if (duped_workspace_item_task_id) |v| allocator.free(v);
            if (duped_created_at) |v| allocator.free(v);
            if (duped_updated_at) |v| allocator.free(v);
        }
        duped_id = try allocator.dupe(u8, p.id);
        duped_workspace_item_id = try allocator.dupe(u8, p.workspace_item_id);
        duped_name = try allocator.dupe(u8, p.name);
        duped_workspace_item_task_id = try allocator.dupe(u8, p.workspace_item_task_id);
        duped_created_at = try allocator.dupe(u8, p.created_at);
        duped_updated_at = try allocator.dupe(u8, p.updated_at);

        return .{ .page = .{
            .id = duped_id.?,
            .workspace_item_id = duped_workspace_item_id.?,
            .name = duped_name.?,
            .workspace_item_task_id = duped_workspace_item_task_id.?,
            .width = p.width,
            .height = p.height,
            .position = p.position,
            .created_at = duped_created_at.?,
            .updated_at = duped_updated_at.?,
        } };
    }

    return error.PageNotVisible;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designPagesCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreatePageBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }

    // Defaults match the Figma-lite 1440×1024 canvas from design §5.1.
    const width = parsed.width orelse 1440;
    const height = parsed.height orelse 1024;

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .name = parsed.name,
        .width = width,
        .height = height,
    }) catch |err| {
        // 3. Map the use-case error to an HTTP response. Both
        //    switches are exhaustive over the inferred error set —
        //    adding a new `DesignPageCreateError` variant will fail
        //    to compile here (intentional, to keep status codes in
        //    sync). No `else` prong needed.
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.BadPageName => 400,
            error.ItemPathMissing => 400,
            error.DbError => 500,
            error.PageNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.BadPageName => "name is required",
            error.ItemPathMissing => "design item must have a path",
            error.DbError => "Failed to create page",
            error.PageNotVisible => "Page was created but not visible in list",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned page slices. On the per-request
    // arena this is a no-op (the arena reaps at request end) but the
    // explicit frees are defensive + document ownership.
    defer {
        allocator.free(output.page.id);
        allocator.free(output.page.workspace_item_id);
        allocator.free(output.page.name);
        allocator.free(output.page.created_at);
        allocator.free(output.page.updated_at);
    }

    // 4. Build the success response (201 Created — POST that creates
    //    a new resource, or 200 OK for idempotent re-POST of the
    //    same name; we use 201 unconditionally because the body
    //    represents "this page is now in the system" — the client
    //    can ignore the difference).
    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignPageResponse(output.page),
            .{},
        ),
    });
}