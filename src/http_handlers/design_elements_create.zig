//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements`.
//!
//! Add a new design element to a design page. Atomically writes
//! the element's HTML body to disk (under
//! `<workspace_item.path>/.pabrik/design/<page>/<element>.html`) and
//! inserts the metadata row. Delegates to `design_model.addElement`.
//!
//! Body: `{name: string, type: "rectangle"|"ellipse"|"text"|"image"|"frame"|"group",
//!        html: string, x?: number=0, y?: number=0, width?: number=375, height?: number=667,
//!        fill?: string="", rotation?: number=0, corner_radius?: number=0, opacity?: number=1.0,
//!        text_content?: string="", text_style?: string="", image_url?: string=""}`.
//!
//! Defaults match the v6 design-mode spec §5.1 (375×667 default size
//! to mirror a phone-shaped rectangle; other defaults 0/empty).
//!
//! Response shape: `DesignElementResponse` for the newly-created
//! element (without `html` — fetch lazily via
//! `GET .../elements/:eid/html`). Built by
//! `http_response.makeDesignElementResponse`.
//!
//! Layered as:
//!   - `useCase` — business logic (validate → call addElement →
//!     re-fetch via getElement → emit SSE → return heap-owned
//!     `DesignElement`).
//!   - `designElementsCreateHandler` — thin orchestrator over
//!     `useCase`: parses the HTTP request, resolves the singleton
//!     DB handle, delegates to `useCase`, maps the use-case outcome
//!     to an HTTP response (201 / 400 / 404 / 500).
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/empty `name`, missing
//!     `page_id` path param, invalid `type`, design item has no
//!     `path` set, bad numeric fields
//!   - 404 `page_id` not found in `design_pages`
//!   - 500 DB failure or file-write failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");
const on_event_sent_design = pabrikcore.ai_mod.on_event_sent_design;

/// HTTP request body for element-create. Decoupled from the
/// `AddElementInput` domain struct so the wire format can evolve
/// independently (e.g. adding `?` optional fields) without touching
/// the use-case. `type` is the wire string ("rectangle", "ellipse",
/// "text", "image", "frame", "group") — translated to the
/// `ElementType` enum at the handler boundary.
const CreateElementBody = struct {
    name: []const u8,
    type: []const u8,
    html: []const u8,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    fill: ?[]const u8 = null,
    rotation: ?f64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: ?[]const u8 = null,
    text_style: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (one for status, one for the user-facing message).
///
/// Adding a new variant fails to compile in the handler until both
/// switches are updated — that's intentional, to keep status codes
/// in lockstep with the error set.
pub const DesignElementCreateError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// Body `name` field was empty (matches `design_model.BadName`).
    BadName,
    /// `type` field was not a valid `ElementType` enum variant.
    InvalidType,
    /// `design_model.addElement` returned `ItemPathMissing`
    /// (the parent workspace_item has no `path`).
    ItemPathMissing,
    /// `design_model.addElement` returned `PageNotFound`
    /// (no row with that `page_id`).
    PageNotFound,
    /// `design_model.addElement` returned `FileWriteFailed` (mkdir
    /// or atomic-rename failed).
    FileWriteFailed,
    /// `addElement` failed for some other DB reason.
    DbError,
    /// Insert succeeded but the new element wasn't visible in the
    /// subsequent `getElement` (consistency violation — extremely
    /// unlikely; surfaces as 500 so the caller can re-fetch).
    ElementNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the create-element use-case.
pub const CreateElementInput = struct {
    page_id: []const u8,
    /// workspace_id is for the SSE payload (the frontend filters
    /// events by it). Empty is fine.
    workspace_id: []const u8,
    name: []const u8,
    elem_type: design_model.ElementType,
    html: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    fill: []const u8,
    rotation: f64,
    corner_radius: i64,
    opacity: f64,
    text_content: []const u8,
    text_style: []const u8,
    image_url: []const u8,
};

/// Output of the create-element use-case.
pub const CreateElementOutput = struct {
    /// The freshly-created element. The slice fields are HEAP-OWNED
    /// by the use-case: the use-case duplicates them out of the
    /// `getElement` result so the output survives the useCase's
    /// internal `freeElement` defer (and any later `freeElement(e)`
    /// that runs in the caller).
    element: design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a design element.
///
/// Steps:
///   1. Validate `page_id` and `name`.
///   2. Call `design_model.addElement(...)` — returns the new
///      element_id (also writes the HTML file atomically).
///   3. Re-query via `design_model.getElement(...)` to fetch the full
///      row (addElement only returns the id).
///   4. Emit a `design_element` SSE event with `action="created"`.
///      Best-effort: SSE failures are logged but don't fail the
///      request.
///   5. Return a heap-owned `DesignElement` for the response.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    io: std.Io,
    input: CreateElementInput,
) DesignElementCreateError!CreateElementOutput {
    // 1. Validate.
    if (input.page_id.len == 0) return error.PageIdRequired;
    if (input.name.len == 0) return error.BadName;

    // 2. Insert (and write the HTML file atomically).
    const new_id = design_model.addElement(allocator, db, io, .{
        .page_id = input.page_id,
        .name = input.name,
        .elem_type = input.elem_type,
        .html = input.html,
        .x = input.x,
        .y = input.y,
        .width = input.width,
        .height = input.height,
        .fill = input.fill,
        .rotation = input.rotation,
        .corner_radius = input.corner_radius,
        .opacity = input.opacity,
        .text_content = input.text_content,
        .text_style = input.text_style,
        .image_url = input.image_url,
    }) catch |err| switch (err) {
        error.BadName => return error.BadName,
        error.PageNotFound => return error.PageNotFound,
        error.ItemPathMissing => return error.ItemPathMissing,
        error.FileWriteFailed => return error.FileWriteFailed,
        else => return error.DbError,
    };
    defer allocator.free(new_id);

    // 3. Re-query to get the full row.
    const element = design_model.getElement(allocator, db, new_id) catch return error.ElementNotVisible;
    errdefer design_model.freeElement(allocator, element);

    // 4. Emit the SSE event (best-effort).
    on_event_sent_design.onEventSendDesignElementCreated(allocator, .{
        .action = "created",
        .workspace_id = input.workspace_id,
        .item_id = "", // The HTTP handler doesn't have item_id; SSE
        //                payload contract allows empty. (The
        //                frontend refetches by workspace_id.)
        .page_id = input.page_id,
        .element_id = new_id,
    }) catch {};

    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designElementsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    // workspace_id is used for the SSE payload filter — empty is OK.
    const ws_id = req.params.get("workspace_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateElementBody, allocator, req.body, .{}) catch {
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

    if (parsed.html.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "html is required" }),
        });
    }

    // Translate the wire `type` string into the ElementType enum.
    // `std.meta.stringToEnum` returns `?T` — null on no match.
    const elem_type = std.meta.stringToEnum(design_model.ElementType, parsed.type) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "type must be one of: rectangle, ellipse, text, image, frame, group",
            }),
        });
    };

    // Apply defaults (matches the v6 design-mode spec §5.1).
    const x = parsed.x orelse 0;
    const y = parsed.y orelse 0;
    const width = parsed.width orelse 375;
    const height = parsed.height orelse 667;
    const fill = parsed.fill orelse "";
    const rotation = parsed.rotation orelse 0.0;
    const corner_radius = parsed.corner_radius orelse 0;
    const opacity = parsed.opacity orelse 1.0;
    const text_content = parsed.text_content orelse "";
    const text_style = parsed.text_style orelse "";
    const image_url = parsed.image_url orelse "";

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, ctx.io, .{
        .page_id = page_id,
        .workspace_id = ws_id,
        .name = parsed.name,
        .elem_type = elem_type,
        .html = parsed.html,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .fill = fill,
        .rotation = rotation,
        .corner_radius = corner_radius,
        .opacity = opacity,
        .text_content = text_content,
        .text_style = text_style,
        .image_url = image_url,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.BadName => 400,
            error.InvalidType => 400,
            error.ItemPathMissing => 400,
            error.PageNotFound => 404,
            error.FileWriteFailed => 500,
            error.DbError => 500,
            error.ElementNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.BadName => "name is required",
            error.InvalidType => "type must be one of: rectangle, ellipse, text, image, frame, group",
            error.ItemPathMissing => "design item must have a path",
            error.PageNotFound => "Page not found",
            error.FileWriteFailed => "Failed to write element HTML file",
            error.DbError => "Failed to create element",
            error.ElementNotVisible => "Element was created but not visible",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned element slices (no-op on arena).
    defer design_model.freeElement(allocator, output.element);

    // 4. Build the success response (201 Created).
    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}

// ===== Tests merged from design_elements_create_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `POST .../pages/:pid/elements` handler.
// 
// Why this file exists
// ────────────────────
// The element-create endpoint appends a new element to a design
// page (atomically writes the HTML to disk + INSERTs the row).
// The handler must:
//   1. Parse `{name, type, html, ...}` via `parseFromSliceLeaky`,
//      translating the wire `type` string to the `ElementType` enum.
//   2. Call `design_model.addElement(...)`.
//   3. Return 201 with the new element as a `DesignElementResponse`.
// 
// These contracts are enforced by static substring checks, matching
// the project's `kanban_columns_create_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.3)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_elements_create.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

// ─── Contract 1: handler uses parseFromSliceLeaky ────────────────────────

test "design_elements_create handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

// ─── Contract 2: handler calls design_model.addElement ───────────────────

test "design_elements_create handler calls design_model.addElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.addElement") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.addElement !!\n" ++
                "   The POST contract is broken: the handler must delegate to\n" ++
                "   `design_model.addElement(allocator, db, io, input)`.\n",
            .{HANDLER_PATH},
        );
        return error.AddElementCallMissing;
    }
}

// ─── Contract 3: handler returns 201 on success ──────────────────────────

test "design_elements_create handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   Use `.status_code = 201` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}

// ─── Contract 4: handler maps PageNotFound to 404 ─────────────────────────

test "design_elements_create handler maps PageNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.PageNotFound => 404") == null) {
        std.debug.print(
            "\n!! {s} does not map PageNotFound to 404 !!\n" ++
                "   The status contract is broken: missing pages must return 404.\n",
            .{HANDLER_PATH},
        );
        return error.PageNotFoundStatusMissing;
    }
}

// ─── Contract 5: handler validates the page_id path param ───────────────

test "design_elements_create handler validates page_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"page_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the page_id path param !!\n" ++
                "   The path-param contract is broken: the handler must read\n" ++
                "   `req.params.get(\"page_id\")` and return 400 when missing.\n",
            .{HANDLER_PATH},
        );
        return error.PageIdParamMissing;
    }
}

// ─── Contract 6: handler translates type string to ElementType enum ──────

test "design_elements_create handler translates type string to enum" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.meta.stringToEnum") == null) {
        std.debug.print(
            "\n!! {s} does not use std.meta.stringToEnum for the type field !!\n" ++
                "   The wire-format contract is broken: the handler must translate\n" ++
                "   the `type` string to the `ElementType` enum via `std.meta.stringToEnum`.\n",
            .{HANDLER_PATH},
        );
        return error.TypeTranslationMissing;
    }
}
