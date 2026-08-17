//! `POST /api/workspaces/:workspace_id/items/agent`.
//!
//! Creates a new workspace item of `item_type='agent'` and the
//! matching 1-1 row in the `agents` sibling table, in a single
//! BEGIN/COMMIT transaction.
//!
//! Body: `{name, path}` — both required (per spec: the Agent item has
//! a cwd like Kanban/Design). `name` is trimmed and must be non-empty
//! after trim.
//!
//! Steps:
//!   1. Parse the JSON body via `parseFromSliceLeaky` (per-request
//!      arena owns the parsed struct's memory).
//!   2. Generate a unique item id via `helpers.unixTimestampNanos` —
//!      same pattern as `workspace_items_create_kanban.zig`.
//!   3. BEGIN TRANSACTION.
//!   4. INSERT INTO `workspace_items` with `item_type='agent'` and a
//!      fresh position (`COALESCE(MAX(position), -1) + 1`).
//!   5. INSERT INTO `agents` with the SAME id (per spec D3 — the
//!      agent's id IS the workspace_item id; 1-1 invariant).
//!   6. COMMIT TRANSACTION.
//!   7. Return 201 with `{item, agent}` envelope (the frontend's
//!      `api.createAgent` destructures both).
//!
//! No seed data — the agent starts with empty knowledge list AND
//! empty tool allowlist (zero tools by default per spec D1 —
//! secure-by-default).
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md (Task 4)
//! Spec: docs/superpowers/specs/2026-08-15-agent-mode-design.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = nalarcore.helpers;

/// Request body for the agent-item create endpoint. Both fields are
/// required (the Agent has a cwd like Kanban/Design).
const CreateAgentBody = struct {
    name: []const u8,
    path: []const u8,
};

/// Response item — mirrors `CreateKanbanResponse` minus the kanban-
/// specific fields. `path` mirrors the request body.
pub const CreateAgentItemResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8, // always "agent"
    name: []const u8,
    path: ?[]const u8 = null,
    position: i64,
};

/// Response agent row. Mirrors `src/models/agent.zig` field set.
pub const CreateAgentAgentResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8, // always "" for new agents
    created_at: []const u8,
    updated_at: []const u8,
};

/// Wire envelope: `{item, agent}`. The frontend's `api.createAgent`
/// destructures `item` and `agent` separately — same wrapped-envelope
/// pattern that the kanban create endpoint uses, but Agent has no
/// `columns` array (agents don't seed kanban columns).
pub const CreateAgentResponseFull = struct {
    item: CreateAgentItemResponse,
    agent: CreateAgentAgentResponse,
};

pub const WorkspaceItemsCreateAgentError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    PathRequired,
    EmptyName,
    OutOfMemory,
    DatabaseError,
};

pub const WorkspaceItemsCreateAgentInput = struct {
    workspace_id: []const u8,
    body: CreateAgentBody,
};

pub const WorkspaceItemsCreateAgentResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: WorkspaceItemsCreateAgentInput,
) WorkspaceItemsCreateAgentError!WorkspaceItemsCreateAgentResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.EmptyName;
    if (input.body.path.len == 0) return error.PathRequired;

    // Generate item id. SAME pattern as workspace_items_create_kanban.zig
    // (helpers.unixTimestampNanos is cross-platform; std.c.clock_gettime
    // doesn't compile on Windows in Zig 0.16).
    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});

    // BEGIN/COMMIT so the 2 INSERTs are atomic. A crash mid-flow
    // would otherwise leave a workspace_items row without an agent
    // sibling (breaking the 1-1 invariant).
    db.exec(allocator, "BEGIN", &[_][]const u8{}) catch return error.DatabaseError;
    errdefer {
        db.exec(allocator, "ROLLBACK", &[_][]const u8{}) catch {};
    }

    // 1. INSERT INTO workspace_items with item_type='agent' and a
    //    fresh position. NULLIF(?, '') stores NULL when the caller
    //    didn't pass a path (matching the kanban convention).
    db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, 'agent', ?, NULLIF(?, ''), COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, trimmed_name, input.body.path, input.workspace_id },
    ) catch return error.DatabaseError;

    // 2. INSERT INTO agents with the SAME id (spec D3 — agents.id
    //    shares the workspace_item_id space; UNIQUE(workspace_item_id)
    //    enforces 1-1 at the DB layer).
    db.exec(allocator,
        "INSERT INTO agents (id, workspace_item_id) VALUES (?, ?)",
        &.{ item_id, input.workspace_id },
    ) catch return error.DatabaseError;

    // COMMIT.
    db.exec(allocator, "COMMIT", &[_][]const u8{}) catch return error.DatabaseError;

    // Read back the freshly-inserted position (mirrors the kanban
    // CREATE flow — see workspace_items_create_kanban.zig::readInsertedPosition).
    const position = readInsertedPosition(allocator, db, item_id);

    // Build the wire envelope. created_at / updated_at are populated
    // by SQLite's CURRENT_TIMESTAMP — we use empty strings here; the
    // frontend doesn't read them on create (it refetches via getWorkspacesItems).
    return try std.json.Stringify.valueAlloc(allocator, CreateAgentResponseFull{
        .item = .{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "agent",
            .name = trimmed_name,
            .path = input.body.path,
            .position = position,
        },
        .agent = .{
            .id = item_id,
            .workspace_item_id = input.workspace_id,
            .description = "",
            .created_at = "",
            .updated_at = "",
        },
    }, .{});
}

/// Re-read the `position` of a freshly-INSERTed workspace_item. Mirrors
/// `workspace_items_create_kanban.zig::readInsertedPosition` — the
/// INSERT computes position via correlated subquery, so we can't know
/// the persisted value without a follow-up SELECT. Best-effort on
/// failure (returns 0).
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
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceItemsCreateAgentHandler(
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

    const parsed = std.json.parseFromSliceLeaky(CreateAgentBody, allocator, req.body, .{}) catch {
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
    // names at the handler level too (the useCase also rejects them).
    if (std.mem.trim(u8, parsed.name, " \t\n\r").len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }
    if (parsed.path.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path is required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired, error.MissingBody, error.InvalidJson,
            error.NameRequired, error.PathRequired, error.EmptyName => 400,
            error.DatabaseError, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired, error.EmptyName => "name is required",
            error.PathRequired => "path is required",
            error.DatabaseError => "Failed to create agent item",
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