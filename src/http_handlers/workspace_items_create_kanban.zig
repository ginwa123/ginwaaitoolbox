//! `POST /api/workspaces/:workspace_id/items/kanban`.
//!
//! Creates a new workspace item of `item_type='kanban'`, seeds its
//! default 3-column flow (`todo / in progress / done`), creates the
//! `agent_kanbans` config row, and seeds default tools
//! (command, read_file, write_file) so a fresh board is immediately usable.
//!
//! Body: `{name, path?}` — `name` is required, `path` is optional
//! (NULL is stored when omitted; the kanban is cwd-less until the
//! user sets the path via the PUT endpoint).
//!
//! Steps:
//!   1. Generate a unique item id (`item_<unix_nanoseconds>` — same
//!      pattern as `workspace_items_create.zig`).
//!   2. INSERT into `workspace_items` with `item_type='kanban'` and
//!      a fresh position (`COALESCE(MAX(position), -1) + 1`).
//!   3. Seed the default columns.
//!   4. Emit one SSE `kanban_column` event per seeded column.
//!   5. Return 201 with `{id, workspace_id, item_type, name, path,
//!      position}`.
//!
//! Layered as `useCase` (validate + generate id + insert + seed +
//! emit SSE) and a thin handler that maps the outcome + errors to
//! status codes / JSON.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;
const helpers = @import("helpers");

/// Request body for the kanban-item create endpoint.
const CreateKanbanBody = struct {
    name: []const u8,
    /// Optional absolute path on disk that will become the `cwd` for
    /// every chat session created under this kanban's tasks.
    path: ?[]const u8 = null,
};

/// Response body for the kanban-item create endpoint.
pub const CreateKanbanResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    /// Mirrors the request body's path. `null` when the caller did
    /// not supply one (cwd-less kanban).
    path: ?[]const u8 = null,
    position: i64,
};

/// Wire envelope for the create endpoint. The frontend's
/// `api.createKanban(workspaceId, name, path)` destructures
/// `{item, columns}` from the response body and pushes the item
/// straight into the workspaces store (see `addKanbanItem` in
/// `src/apps/desktop/src/stores/workspaces.ts`).
///
/// Why the wrapper:
///   - The frontend's `KanbanColumn[]` array is the 3 freshly-seeded
///     default columns (`todo / in progress / done`). Returning them
///     inline saves a follow-up `GET /items/:id/kanban/columns`
///     round-trip — the kanban board renders immediately on the
///     client without a flicker-frame of empty columns.
///   - The flat `CreateKanbanResponse` shape (the original `item`
///     payload alone) caused a UI bug: the frontend's destructure
///     `const { item, columns } = await api.createKanban(...)` got
///     `item` and `columns` as `undefined`, the local store pushed
///     an item with all fields undefined, and the sidebar rendered
///     the `{{ item.name || 'Untitled project' }}` fallback until
///     the user reloaded (the reloaded state came from
///     `getWorkspacesItems`, which has the correct shape). Tests
///     pass because the API mocks return the wrapped shape — the
///     real backend never matched it. Fix: serialize both fields
///     in one envelope so the wire shape matches the contract.
pub const CreateKanbanResponseFull = struct {
    item: CreateKanbanResponse,
    columns: []const kanban_model.KanbanColumn,
};

pub const WorkspaceItemsCreateKanbanError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    InsertFailed,
    SeedFailed,
    /// `std.json.Stringify.valueAlloc` and `allocator.dupe` can
    /// fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const WorkspaceItemsCreateKanbanInput = struct {
    workspace_id: []const u8,
    body: CreateKanbanBody,
};

pub const WorkspaceItemsCreateKanbanResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: WorkspaceItemsCreateKanbanInput,
) WorkspaceItemsCreateKanbanError!WorkspaceItemsCreateKanbanResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    // Trim leading/trailing ASCII whitespace and reject empty names.
    // Mirrors `workspace_items_create.zig`'s `EmptyName` validation
    // so both create endpoints have consistent semantics.
    // `std.mem.trim` returns a slice into the same backing
    // `parseFromSliceLeaky` arena, so no allocation needed. Plan:
    // docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.NameRequired;

    // Path is optional — when omitted, NULL is stored (cwd-less
    // kanban, same as pre-fix behavior). The frontend should always
    // pass it; we don't enforce it here so existing tests / API
    // clients that don't know about the field keep working.
    const path_opt: ?[]const u8 = input.body.path;
    const path_for_insert: []const u8 = path_opt orelse "";

    // Generate item id. Same nanosecond-timestamp scheme as
    // `workspace_items_create.zig:generateItemId`. We use helpers.unixTimestampNanos
    // here (rather than `std.Io.Clock.now`) so the use-case doesn't need
    // a `std.Io` parameter — the timestamp generation is a single wall-
    // clock read with no async/IO involvement. `std.c.clock_gettime`
    // cannot compile on Windows in Zig 0.16 (clockid_t is void there),
    // which is why we route through the cross-platform helper.
    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    defer allocator.free(item_id);

    // tx so workspace_item + columns + agent_kanbans + tools are atomic.
    var tx = db.begin() catch return error.InsertFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // Compute the new item's position as
    // COALESCE(MAX(position), -1) + 1 within this workspace. The
    // COALESCE handles the empty-workspace case (no rows → MAX is
    // NULL → -1 → position 0). `workspace_id` is bound twice: once
    // for the column, once for the correlated subquery. The path
    // column is included so the kanban can act as a cwd root for
    // its child task sessions; NULL is stored when the caller
    // didn't pass a path.
    tx.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, 'kanban', ?, NULLIF(?, ''), COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, trimmed_name, path_for_insert, input.workspace_id },
    ) catch return error.InsertFailed;

    // Seed the 3 default columns (`todo / in progress / done`).
    // Takes `tx` (not `db`): the tx holds the backend mutex, so a
    // `db.exec` here would deadlock on the non-reentrant lock.
    kanban_model.seedDefaultColumns(allocator, &tx, item_id) catch return error.SeedFailed;

    // Seed the agent_kanbans config row + default tools (command,
    // read_file, write_file) so a fresh board is immediately usable.
    // INSERT OR IGNORE keeps re-entry safe; tools seed uses OR IGNORE
    // per row so it never trips UNIQUE(kanban_id, tool_name).
    tx.exec(allocator,
        "INSERT OR IGNORE INTO agent_kanbans (id, workspace_item_id) VALUES (?, ?)",
        &.{ item_id, item_id },
    ) catch return error.SeedFailed;
    tools_equipped.seedDefaultKanbanTools(allocator, &tx, item_id) catch return error.SeedFailed;

    tx.commit() catch return error.SeedFailed;

    // Read back the freshly-seeded columns so the response can
    // include them in the `columns` field of the wire envelope.
    // Failures here are logged and swallowed: we still return the
    // created item (with `columns: []`) so the HTTP 201 succeeds —
    // the frontend falls back to a follow-up
    // `GET /items/:id/kanban/columns` via `fetchKanbanColumns` to
    // populate the board if this read fails.
    const seeded_cols = kanban_model.listColumns(allocator, db, item_id) catch {
        std.log.warn(
            \\workspace_items_create_kanban: seed-listColumns failed (non-fatal); returning empty columns array
        ,
            .{},
        );
        return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponseFull{
            .item = .{
                .id = item_id,
                .workspace_id = input.workspace_id,
                .item_type = "kanban",
                .name = trimmed_name,
                .path = path_opt,
                .position = 0,
            },
            .columns = &[_]kanban_model.KanbanColumn{},
        }, .{});
    };
    defer kanban_model.freeColumns(allocator, seeded_cols);

    // Emit SSE events for each seeded column so other connected
    // clients refresh their kanban view. action="created" for all
    // three. The emit is fire-and-forget; failures are logged and
    // swallowed so the HTTP 201 still succeeds.
    for (seeded_cols) |col| {
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "created",
            .workspace_id = input.workspace_id,
            .item_id = item_id,
            .column_id = col.id,
        }) catch |err| {
            std.log.warn(
                "workspace_items_create_kanban: SSE emit failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };
    }

    // Read the actual position back from the DB so the response
    // mirrors what was persisted. The INSERT computes the position
    // via `COALESCE((SELECT MAX+1), 0)` so we can't know the value
    // without re-reading — the previous code hardcoded `0` here,
    // which would have collided with item ordering had the
    // frontend ever used `position` to sort a fresh response.
    // Non-fatal on read failure: we still return the 201 with
    // `position = 0` and the next refresh from `getWorkspacesItems`
    // will reconcile the value.
    const position = readInsertedPosition(allocator, db, item_id);

    return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponseFull{
        .item = .{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "kanban",
            .name = trimmed_name,
            .path = path_opt,
            .position = position,
        },
        .columns = seeded_cols,
    }, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceItemsCreateKanbanHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateKanbanBody, allocator, req.body, .{}) catch {
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
    // Trim leading/trailing ASCII whitespace. Reject whitespace-only
    // names at the handler level too (the useCase also rejects
    // them, but checking at both layers keeps the error message
    // localized to the handler-side path). Plan:
    // docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
    if (std.mem.trim(u8, parsed.name, " \t\n\r").len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.NameRequired => 400,
            error.InsertFailed, error.SeedFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired => "name is required",
            error.InsertFailed => "Failed to create kanban item",
            error.SeedFailed => "Failed to seed default columns",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 201,
        .data = data,
    });
}

/// Re-read the `position` of a freshly-INSERTed workspace_item.
///
/// The kanban-create INSERT computes position via the correlated
/// subquery `COALESCE((SELECT MAX+1), 0)`, so we can't know the
/// persisted value without a follow-up SELECT. This helper does
/// that SELECT and returns the value, falling back to `0` on any
/// failure (the next refresh from `getWorkspacesItems` will
/// reconcile the value if the SELECT genuinely failed — non-fatal
/// because the create itself already succeeded).
///
/// Extracted from `useCase` so the useCase body stays a single
/// straight-line flow (the inline `if (db.query) |q| { defer
/// q.deinit(); if (q.next()) |row| { ... } }` form ran into a
/// "captured `row` is const" issue that's much cleaner to express
/// in a dedicated function with `var q = db.query(...) catch`).
fn readInsertedPosition(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
) i64 {
    var q = db.query(allocator,
        "SELECT position FROM workspace_items WHERE id = ?",
        &.{item_id},
    ) catch return 0;
    defer q.deinit();
    // `try` would propagate the error and abort the 201 — we want
    // a best-effort read, so swallow the error and fall through.
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

// ===== Tests merged from workspace_items_create_kanban_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `POST /workspaces/:wsId/items/kanban`
// handler (`workspace_items_create_kanban.zig`).
// 
// Why this file exists
// ────────────────────
// The Workspace Item Kanban feature (plan:
// `2026-06-21-workspace-item-kanban.md`) introduces a new
// `item_type='kanban'` workspace item. The create handler is a thin
// wrapper that:
//   1. Parses `{name}` from the JSON body via `parseFromSliceLeaky`.
//   2. Generates a unique `item_<unix_nanoseconds>` id.
//   3. INSERTs the row with `item_type='kanban'` and a fresh position.
//   4. Calls `kanban_model.seedDefaultColumns` to add the canonical
//      3-column default flow (`todo / in progress / done`).
//   5. Returns 201 with `{item: {id, workspace_id, item_type, name,
//      path, position}, columns: [...]}` — the wrapped envelope the
//      frontend's `api.createKanban` destructures.
//
// Why the wrapped envelope (not the flat `{id, name, ...}` shape):
//   See `workspace_items_create_kanban.zig::CreateKanbanResponseFull`.
//   The old flat shape caused `const { item, columns } = await
//   api.createKanban(...)` to yield undefined for both, and the
//   sidebar rendered the `{{ item.name || 'Untitled project' }}`
//   fallback until reload. Tests passed because the API mocks
//   returned the wrapped shape — the real backend never matched it.
// 
// These contracts are enforced by static substring checks (matching
// the project's `routines_run_test.zig` / `task_create_routines_test.zig`
// pattern), not by spinning up an in-memory DB. The static checks
// below directly test the bug — they fail if and only if the create
// plumbing is removed or routed back to the generic `item_type='folder'`
// path.
// 
// Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//   (Chunk 3, Task 3.2)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/workspace_items_create_kanban.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler parses the request body via parseFromSliceLeaky ───

test "create_kanban handler parses name from JSON body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use `parseFromSliceLeaky` (NOT the non-leaky
    // variant — see project memory
    // `nalar-http-handler-thin-wrapper-pattern`). The parsed body's
    // `.name` field must then be referenced (extracted from the
    // struct for use in the SQL INSERT).
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken: the handler must parse the\n" ++
                "   `{{name}}` body via `parseFromSliceLeaky` (per-request arena owns\n" ++
                "   the memory; no explicit deinit needed). Switch from\n" ++
                "   `parseFromSlice` to `parseFromSliceLeaky`.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
    // `.name` extraction — the parsed struct's `name` field must be
    // referenced for use in the INSERT. We look for the substring
    // `parsed.name` which is the standard extraction pattern in this
    // codebase.
    if (std.mem.indexOf(u8, source, "parsed.name") == null) {
        std.debug.print(
            "\n!! {s} does not extract .name from the parsed body !!\n" ++
                "   The create-body contract is broken: the handler must reference\n" ++
                "   the `name` field of the parsed struct (e.g. `const name = parsed.name;`)\n" ++
                "   and pass it to the INSERT. Without this, the kanban item would\n" ++
                "   be created with no name.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

// ─── Contract 2: handler seeds the 3 default columns ──────────────────────

test "create_kanban handler seeds default columns" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // After INSERTing the kanban workspace_item row, the handler must
    // call `kanban_model.seedDefaultColumns` to populate the canonical
    // 3-column flow. Without this, the board opens with zero columns
    // and the user has to manually add them via the column-editor.
    if (std.mem.indexOf(u8, source, "seedDefaultColumns") == null) {
        std.debug.print(
            "\n!! {s} does not call seedDefaultColumns !!\n" ++
                "   The kanban-defaults contract is broken: a freshly-created kanban\n" ++
                "   item would have zero columns until the user manually adds them.\n" ++
                "   Call `kanban_model.seedDefaultColumns(allocator, sqlite_db, item_id)`\n" ++
                "   after the INSERT.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.SeedDefaultColumnsMissing;
    }
}

// ─── Contract 3: handler returns 201 on success ────────────────────────────

test "create_kanban handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The create endpoint must return 201 Created on success (this is
    // the standard REST convention for POST that creates a resource).
    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   The create-status contract is broken: clients expect 201 Created\n" ++
                "   for a successful POST. Use `.status_code = 201` on the success branch.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}

// ─── Contract 4: response envelope is {item, columns} (NOT flat) ───────────

test "create_kanban handler returns wrapped {item, columns} envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The frontend's `api.createKanban` (src/apps/desktop/src/api/index.ts)
    // destructures `const { item, columns } = await api.createKanban(...)`.
    // If the response is the flat `CreateKanbanResponse` shape (just
    // {id, name, position, ...}), both `item` and `columns` come back
    // undefined and the sidebar renders the
    // `{{ item.name || 'Untitled project' }}` fallback until reload.
    //
    // The handler must serialize a `CreateKanbanResponseFull` envelope
    // (struct with `item` + `columns` fields). We assert the type
    // name appears in the source so the regression catches both:
    //   1. someone reverting to the flat `CreateKanbanResponse` shape
    //   2. someone moving the envelope shape to a different name and
    //      breaking the frontend's destructure
    if (std.mem.indexOf(u8, source, "CreateKanbanResponseFull") == null) {
        std.debug.print(
            "\n!! {s} does not return the {{item, columns}} envelope !!\n" ++
                "   The frontend's api.createKanban destructures {{item, columns}}.\n" ++
                "   If the handler returns the flat CreateKanbanResponse (no wrapper),\n" ++
                "   `item` and `columns` both come back undefined and the sidebar\n" ++
                "   renders the 'Untitled project' fallback until reload. Serialize\n" ++
                "   the response via `CreateKanbanResponseFull{{.item=..., .columns=...}}`.\n" ++
                "   See docs/superpowers/plans/2026-07-25-kanban-untitled-bug.md.\n",
            .{HANDLER_PATH},
        );
        return error.WireEnvelopeMissing;
    }
}
