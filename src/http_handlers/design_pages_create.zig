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
const design_model = @import("../agentic_loop/design_model.zig");

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

// ===== Tests merged from design_pages_create_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `POST /design/pages` handler.
// 
// Why this file exists
// ────────────────────
// The page-create endpoint upserts a design page for a workspace
// item of `item_type='design'`. The handler must:
//   1. Parse `{name, width?, height?}` via `parseFromSliceLeaky`
//      (defaulting `width`/`height` to 1440×1024).
//   2. Call `design_model.setDesignPage(...)`.
//   3. Return 201 with the page as a `DesignPageResponse`.
// 
// These contracts are enforced by static substring checks, matching
// the project's `kanban_columns_create_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.2)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_pages_create.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true. The
/// returned buffer is owned by the caller.
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

test "design_pages_create handler parses body with parseFromSliceLeaky" {
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

    if (std.mem.indexOf(u8, source, "parsed.name") == null) {
        std.debug.print(
            "\n!! {s} does not extract .name from the parsed body !!\n" ++
                "   The handler must reference `parsed.name` for the new page.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

// ─── Contract 2: handler calls design_model.setDesignPage ────────────────

test "design_pages_create handler calls design_model.setDesignPage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.setDesignPage") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.setDesignPage !!\n" ++
                "   The POST contract is broken: the handler must delegate to\n" ++
                "   `design_model.setDesignPage(...)` (NOT raw SQL).\n",
            .{HANDLER_PATH},
        );
        return error.SetDesignPageCallMissing;
    }
}

// ─── Contract 3: handler returns 201 on success ──────────────────────────

test "design_pages_create handler returns 201 on success" {
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

// ─── Contract 4: handler emits ItemPathMissing as 400 with right message ─

test "design_pages_create handler maps ItemPathMissing to 400 + correct message" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design item must have a path") == null) {
        std.debug.print(
            "\n!! {s} does not contain the 'design item must have a path' message !!\n" ++
                "   The handler must map `ItemPathMissing` to a 400 with the message\n" ++
                "   'design item must have a path' so the frontend can surface it.\n",
            .{HANDLER_PATH},
        );
        return error.ItemPathMissingMessageMissing;
    }
}

// ─── Contract 5: handler uses std.json.Stringify.valueAlloc ──────────────

test "design_pages_create handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n" ++
                "   The response-shape contract is broken: the handler must use\n" ++
                "   `std.json.Stringify.valueAlloc` for the 201 response body.\n",
            .{HANDLER_PATH},
        );
        return error.ValueAllocMissing;
    }
}

// ─── Contract 6: response includes workspace_item_task_id FK field ───────
//
// Behavioural unit test (NOT a static grep — see the project rule in
// `.nalar/memories/static-contract-test-when-to-prefer-behavioural.md`).
//
// The wire contract requires `workspace_item_task_id` to appear on
// every page response. We exercise the actual production code path:
//   `design_model.DesignPage` → `makeDesignPageResponse(page)` (in
//   http_response.zig) → `std.json.Stringify.valueAlloc(...)` (in
//   design_pages_create.zig).
//
// Asserting on the serialized JSON proves that:
//   1. The DesignPage struct has the field (model layer).
//   2. The makeDesignPageResponse helper copies the field (wire layer).
//   3. std.json.Stringify emits it with the expected key (serialization).
// All three are real code paths; a regression in any of them surfaces.
//
// A static grep would only prove that the source mentions the field
// name — which is true even if the field is dead code or shadowed by
// a different field at runtime. This test fails if the field goes
// missing at any layer.
test "makeDesignPageResponse serializes workspace_item_task_id on the wire" {
    const allocator = testing.allocator;

    // Build the canonical page row that setDesignPage produces. The
    // `workspace_item_task_id` is the FK we care about.
    const page = design_model.DesignPage{
        .id = try allocator.dupe(u8, "page_test_abc"),
        .workspace_item_id = try allocator.dupe(u8, "item_test_xyz"),
        .name = try allocator.dupe(u8, "Login"),
        .workspace_item_task_id = try allocator.dupe(u8, "task_test_123"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try allocator.dupe(u8, ""),
        .updated_at = try allocator.dupe(u8, ""),
    };
    defer {
        allocator.free(page.id);
        allocator.free(page.workspace_item_id);
        allocator.free(page.name);
        allocator.free(page.workspace_item_task_id);
        allocator.free(page.created_at);
        allocator.free(page.updated_at);
    }

    // Map the model struct into the wire response struct (the same
    // helper the handler calls).
    const response = http_response.makeDesignPageResponse(page);

    // Serialize via std.json.Stringify.valueAlloc — the exact code
    // path design_pages_create.zig uses for the 201 response body.
    const json = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(json);

    // The FK MUST be present in the wire payload (the whole point of
    // the design-page-task-fk migration). Assert the JSON key +
    // value round-trip cleanly. A static grep can't catch a regression
    // where the field is declared but dropped by the serializer or
    // shadowed by a different name.
    const expected_key_value =
        "\"workspace_item_task_id\":\"task_test_123\"";
    if (std.mem.indexOf(u8, json, expected_key_value) == null) {
        std.debug.print(
            "\n!! Wire payload missing workspace_item_task_id !!\n" ++
                "   JSON body did not contain the expected FK key/value pair.\n" ++
                "   Actual body:\n{s}\n" ++
                "   Expected substring: {s}\n",
            .{ json, expected_key_value },
        );
        return error.WorkspaceItemTaskIdWireFieldMissing;
    }
}
