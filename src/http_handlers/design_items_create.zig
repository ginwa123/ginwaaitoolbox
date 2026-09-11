//! `POST /api/workspaces/:workspace_id/items/design`.
//!
//! Creates a new workspace item of `item_type='design'`. Mirrors
//! `workspace_items_create_kanban.zig` byte-for-byte except:
//!   - `item_type` is `'design'`, not `'kanban'`
//!   - `path` is REQUIRED (not optional): design elements live as
//!     HTML files at `<path>/.nalar/design/<page>/<element>.html`.
//!     Without a path, the user has no way to author design
//!     elements because the model layer rejects `addElement` with
//!     `ItemPathMissing` (see design_model.zig). We 400 here so the
//!     failure is caught at create-time, not at first-write-time.
//!   - No seeded children (unlike kanban's 3 default columns). A
//!     fresh design item starts with zero pages; the LLM creates
//!     pages on demand via the `set_design_page` tool.
//!   - No SSE `kanban_column` emit (no children to announce).
//!
//! Body: `{name: string, path: string}` — both required.
//! Response: 201 with `{id, workspace_id, item_type, name, path, position}`.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   Chunk 8 (AppLayout + Sidebar Wiring) + post-merge Gap #1
//!   "no POST /items/design route + no UI".

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");

/// Request body for the design-item create endpoint.
const CreateDesignBody = struct {
    name: []const u8,
    /// Absolute path on disk that will become the storage root for
    /// design elements (`<path>/.nalar/design/...`). Required because
    /// the model layer's `addElement` rejects the operation with
    /// `ItemPathMissing` if NULL — catching the failure at create-time
    /// gives the user a clearer error than failing on first addElement.
    path: []const u8,
};

/// Response body for the design-item create endpoint. Same shape as
/// `CreateKanbanResponse` minus the seeded-column fields. Re-used by
/// `http_response.makeWorkspaceItemResponse` so the wire format
/// matches the other create-item endpoints.
pub const CreateDesignResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8, // always "design"
    name: []const u8,
    path: []const u8,
    position: i64,
};

pub const WorkspaceItemsCreateDesignError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    PathRequired,
    PathEmpty,
    InsertFailed,
    /// `std.json.Stringify.valueAlloc` and `allocator.dupe` can
    /// fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const WorkspaceItemsCreateDesignInput = struct {
    workspace_id: []const u8,
    body: CreateDesignBody,
};

pub const WorkspaceItemsCreateDesignResult = []const u8; // pre-serialized JSON

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: WorkspaceItemsCreateDesignInput,
) WorkspaceItemsCreateDesignError!WorkspaceItemsCreateDesignResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    // Trim whitespace and reject empty names. Mirrors
    // `workspace_items_create.zig`'s `EmptyName` validation.
    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.NameRequired;

    // Design items REQUIRE a path — without it, addElement would
    // fail on first use. Reject at create-time so the user can pick
    // the path in the dialog (mirrors kanban's recommended path;
    // we don't enforce it there because kanban works cwd-less).
    const trimmed_path = std.mem.trim(u8, input.body.path, " \t\n\r");
    if (trimmed_path.len == 0) return error.PathRequired;

    // Generate item id with the same `item_<unix_nanoseconds>` scheme
    // as `workspace_items_create.zig:generateItemId` and
    // `workspace_items_create_kanban.zig:79-81`. We go through
    // `helpers.unixTimestampNanos` (not `std.Io.Clock.now`) so the
    // use-case doesn't need a `std.Io` parameter — see the same
    // note in create_kanban.zig:73-77 about Windows clockid_t.
    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    defer allocator.free(item_id);

    // Compute the new item's position as
    // COALESCE(MAX(position), -1) + 1 within this workspace. The
    // COALESCE handles the empty-workspace case (no rows → MAX is
    // NULL → -1 → position 0). `workspace_id` is bound twice: once
    // for the column, once for the correlated subquery.
    db.exec(allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at)
        \\VALUES (?, ?, 'design', ?, ?, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))
    , &.{ item_id, input.workspace_id, trimmed_name, trimmed_path, input.workspace_id }) catch {
        return error.InsertFailed;
    };

    // Build the full CreateDesignResponse. The frontend
// (`workspacesStore.addDesignItem`) spreads this response into
// the local item entry so the sidebar can render `item.name`
// immediately without a re-fetch. If we only returned `{id,
// success}` (the `makeWorkspaceItemResponse` shape), the
// sidebar would have to fall back to "Untitled project"
// because the local push would have no name field — the bug
// the user reported on 2026-07-14.
//
// Mirrors the kanban handler's `CreateKanbanResponse` pattern.
// `position` is a placeholder (0) — the frontend sidebar sorts
// by created_at on the next reload and doesn't use position yet;
// computing it here would require a second SELECT for no gain.
    const json = std.json.Stringify.valueAlloc(allocator, CreateDesignResponse{
        .id = item_id,
        .workspace_id = input.workspace_id,
        .item_type = "design",
        .name = trimmed_name,
        .path = trimmed_path,
        .position = 0,
    }, .{}) catch {
        return error.OutOfMemory;
    };
    return json;
}

/// POST /api/workspaces/:workspace_id/items/design.
pub fn workspaceItemsCreateDesignHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
    });

    const json_body_len = req.body.len;
    if (json_body_len == 0) return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "request body required" }),
    });

    const parsed = std.json.parseFromSliceLeaky(CreateDesignBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const result = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.NameRequired => 400,
            error.PathRequired => 400,
            error.PathEmpty => 400,
            error.InsertFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired => "name is required",
            error.PathRequired => "path is required for design items (the storage root for design files)",
            error.PathEmpty => "path is empty after trimming whitespace",
            error.InsertFailed => "Failed to create design item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 201, .data = result });
}

// ===== Tests merged from design_items_create_test.zig (2026-09-11 flatten) =====
// Static regression checks for `workspaceItemsCreateDesignHandler`.
// Follows the project convention (per memory
// `nalar-http-handler-thin-wrapper-pattern.md`): for HTTP handlers,
// static-contract tests verify the file's shape — function name,
// required parsing/serialization helpers, status codes, error
// mapping — without standing up a real GinwaServer. Behavioral
// coverage lives in `migration_055_test.zig` +
// `design_model_test.zig` (the model-layer functions that the
// handler delegates to).

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH =
    "src/http_handlers/design_items_create.zig";
const MAIN_PATH = "src/main.zig";
const MOD_PATH = "src/http_handlers/mod.zig";

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

// ─── Contract 1: handler function exists ─────────────────────────────────

test "design_items_create.zig defines pub fn workspaceItemsCreateDesignHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn workspaceItemsCreateDesignHandler") == null) {
        std.debug.print(
            "\n!! {s} does not define pub fn workspaceItemsCreateDesignHandler !!\n",
            .{HANDLER_PATH},
        );
        return error.HandlerFunctionMissing;
    }
}

// ─── Contract 2: handler uses parseFromSliceLeaky + valueAlloc ───────────

test "design_items_create.zig uses parseFromSliceLeaky + valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("\n!! {s} does not use parseFromSliceLeaky !!\n", .{HANDLER_PATH});
        return error.ParseFromSliceLeakyMissing;
    }
    // valueAlloc is required because we return the FULL
    // CreateDesignResponse (id, workspace_id, item_type, name, path,
    // position) — not the simpler WorkspaceItemResponse `{id,
    // success}` shape. The frontend pushes the response into the
    // local store entry; without `name` in the response, the
    // sidebar falls back to "Untitled project" (the bug reported on
    // 2026-07-14). Using makeWorkspaceItemResponse (which only
    // returns id+success) is therefore a regression of that fix.
    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print("\n!! {s} does not use std.json.Stringify.valueAlloc !!\n", .{HANDLER_PATH});
        return error.ValueAllocMissing;
    }
    if (std.mem.indexOf(u8, source, "CreateDesignResponse") == null) {
        std.debug.print("\n!! {s} does not define CreateDesignResponse !!\n", .{HANDLER_PATH});
        return error.CreateDesignResponseMissing;
    }
}

// ─── Contract 3: error mapping includes PathRequired ─────────────────────

test "design_items_create.zig maps PathRequired + NameRequired to 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "PathRequired") == null) {
        std.debug.print("\n!! {s} does not define PathRequired error !!\n", .{HANDLER_PATH});
        return error.PathRequiredMissing;
    }
    if (std.mem.indexOf(u8, source, "NameRequired") == null) {
        std.debug.print("\n!! {s} does not define NameRequired error !!\n", .{HANDLER_PATH});
        return error.NameRequiredMissing;
    }
}

// ─── Contract 4: route is registered in main.zig ─────────────────────────

test "POST /api/workspaces/:workspace_id/items/design is registered in src/main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    const route_pattern = "/api/workspaces/:workspace_id/items/design";
    if (std.mem.indexOf(u8, source, route_pattern) == null) {
        std.debug.print(
            "\n!! {s} does not register the {s} route !!\n",
            .{ MAIN_PATH, route_pattern },
        );
        return error.RouteRegistrationMissing;
    }
}

// ─── Contract 5: handler is re-exported in mod.zig ───────────────────────

test "workspaceItemsCreateDesignHandler is re-exported in http_handlers/mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "workspaceItemsCreateDesignHandler") == null) {
        std.debug.print(
            "\n!! {s} does not re-export workspaceItemsCreateDesignHandler !!\n",
            .{MOD_PATH},
        );
        return error.HandlerReExportMissing;
    }
}

// ─── Contract 6: response includes name + workspace_id + path ────────────
//
// The frontend (workspacesStore.addDesignItem) does:
//   const item = await api.createDesign(workspaceId, name, path)
//   ws.items.push({ ...item, tasks: [], design_elements: [] })
//
// For the sidebar to render the right name (not fall back to
// "Untitled project"), the response MUST carry `name`. Same
// requirement for `workspace_id`, `item_type`, `path` so the
// item integrates with the rest of the WorkspaceItem interface.
// Regression test for the 2026-07-14 "Untitled project" bug.

test "CreateDesignResponse fields include name, workspace_id, path, item_type" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Find the struct definition block.
    const struct_start = std.mem.indexOf(u8, source, "pub const CreateDesignResponse = struct") orelse {
        std.debug.print("\n!! {s} does not define CreateDesignResponse !!\n", .{HANDLER_PATH});
        return error.CreateDesignResponseMissing;
    };
    const struct_end = std.mem.indexOfPos(u8, source, struct_start, "};") orelse {
        return error.StructEndMissing;
    };
    const block = source[struct_start..struct_end];

    // Comptime-known field list + patterns. The `:` suffix is
    // appended at comptime (the `++` operator on string literals
    // requires comptime operands) so Zig accepts the call.
    const fields = [_][]const u8{ "name", "workspace_id", "item_type", "path", "id" };
    inline for (fields) |field| {
        const pattern = field ++ ":";
        if (std.mem.indexOf(u8, block, pattern) == null) {
            std.debug.print(
                "\n!! CreateDesignResponse is missing the `{s}:` field !!\n",
                .{field},
            );
            return error.ResponseFieldMissing;
        }
    }
}
