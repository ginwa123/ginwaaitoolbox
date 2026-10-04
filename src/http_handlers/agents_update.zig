//! `PATCH /api/workspaces/:workspace_id/items/:item_id/agent`.
//!
//! Body: `{description}`. Updates the description of the agent
//! bound to this workspace_item. Returns 200 with the updated agent
//! row, or 400/404 for validation errors (same as `agents_get.zig`).
//!
//! Layered as:
//!   - `useCase` — validate workspace_item is an agent → UPDATE
//!     description → SELECT updated row → return Agent row.
//!   - `agentsUpdateHandler` — thin orchestrator over `useCase`:
//!     parses path params + body, delegates, maps outcome to HTTP.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");

/// HTTP request body for agent-update. Decoupled from the
/// `AgentUpdateInput` domain struct so the wire format can evolve
/// independently (e.g. adding `?` optional fields) without touching
/// the use-case.
const UpdateAgentBody = struct {
    description: []const u8 = "",
};

/// Subset of the agents row returned by the use-case. Field strings
/// are owned by the caller (lifetime = request arena).
pub const Agent = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const AgentUpdateError = error{
    /// `workspace_id` or `item_id` path param was missing or empty.
    IdsRequired,
    /// `db.query` failed while looking up the workspace_item.
    LookupFailed,
    /// The workspace_item row did not exist.
    ItemNotFound,
    /// The workspace_item exists but its `item_type` is not `'agent'`.
    NotAnAgent,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed (consistency violation).
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `allocator.dupe` failed while copying slice fields. Unreachable
    /// under arena allocator (test builds can hit it), but the
    /// type system requires the variant so `try` propagates.
    OutOfMemory,
};

/// Inputs to the agent-update use-case.
pub const AgentUpdateInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    description: []const u8,
};

/// Output of the agent-update use-case. `agent` is owned by the
/// caller (lifetime = request arena).
pub const AgentUpdateOutput = struct {
    agent: Agent,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an agent's description. Validates that the workspace_item
/// exists and is of type `'agent'`. The use-case is
/// transport-agnostic: it works for both the per-request arena
/// (production HTTP handler) and `testing.allocator` (unit tests
/// below) — all allocations go through the passed-in allocator.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: AgentUpdateInput,
) AgentUpdateError!AgentUpdateOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    // Validate item exists + is an agent.
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.LookupFailed;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "agent")) return error.NotAnAgent;

    // UPDATE description.
    db.exec(allocator,
        "UPDATE agents SET description = ?, updated_at = datetime('now') WHERE id = ?",
        &[_][]const u8{ input.description, input.item_id },
    ) catch return error.UpdateFailed;

    // Read back the updated row.
    var q2 = db.query(allocator,
        "SELECT id, workspace_item_id, description, IFNULL(created_at, ''), IFNULL(updated_at, '') FROM agents WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.RefetchFailed;
    defer q2.deinit();
    const updated_row = (q2.next() catch null) orelse return error.RowVanished;
    defer updated_row.deinit(allocator); // safe — we dupe into the Agent struct below

    // Dupe the slices out of row.values[] so the Agent struct owns
    // them independently of the row. In production this is no-op
    // (arena allocator); in tests it gives clean ownership for
    // assertions + leak detection.
    const id = try allocator.dupe(u8, updated_row.values[0]);
    errdefer allocator.free(id);
    const ws_item_id = try allocator.dupe(u8, updated_row.values[1]);
    errdefer allocator.free(ws_item_id);
    const description = try allocator.dupe(u8, updated_row.values[2]);
    errdefer allocator.free(description);
    const created_at = try allocator.dupe(u8, updated_row.values[3]);
    errdefer allocator.free(created_at);
    const updated_at = try allocator.dupe(u8, updated_row.values[4]);
    errdefer allocator.free(updated_at);

    return .{
        .agent = .{
            .id = id,
            .workspace_item_id = ws_item_id,
            .description = description,
            .created_at = created_at,
            .updated_at = updated_at,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentsUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateAgentBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .description = parsed.description,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.LookupFailed => 500,
            error.ItemNotFound => 404,
            error.NotAnAgent => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.LookupFailed => "Failed to query workspace_item",
            error.ItemNotFound => "workspace_item not found",
            error.NotAnAgent => "workspace_item is not an agent",
            error.UpdateFailed => "Failed to update agent",
            error.RefetchFailed => "Failed to read updated agent",
            error.RowVanished => "Agent row vanished after UPDATE",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .agent = output.agent }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 4 behavioural tests cover the use-case:
//
//   1. Validation: empty workspace_id OR item_id → IdsRequired
//   2. ItemNotFound: workspace_item doesn't exist
//   3. NotAnAgent: workspace_item exists but item_type != 'agent'
//   4. Happy path: description is updated and the response reflects it

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape instead of relying on
    // Migration 001.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up(&db, testing.allocator);

    // Seed: 1 workspace_item of type 'agent' + matching agents row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', 'old description')",
        &[_][]const u8{},
    );

    // Add a kanban-type workspace_item to verify the NotAnAgent path.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_kanban', 'ws_1', 'kanban', 'A kanban')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty workspace_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "",
            .item_id = "ws_item_1",
            .description = "new",
        }),
    );
}

test "useCase: empty item_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .item_id = "",
            .description = "new",
        }),
    );
}

test "useCase: non-existent workspace_item returns ItemNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .item_id = "ws_item_404",
            .description = "new",
        }),
    );
}

test "useCase: workspace_item of type kanban returns NotAnAgent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAnAgent,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .item_id = "ws_item_kanban",
            .description = "new",
        }),
    );
}

test "useCase: happy path updates description and returns Agent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "ws_item_1",
        .description = "freshly updated",
    });
    defer {
        alloc.free(output.agent.id);
        alloc.free(output.agent.workspace_item_id);
        alloc.free(output.agent.description);
        alloc.free(output.agent.created_at);
        alloc.free(output.agent.updated_at);
    }
    try testing.expectEqualStrings("ws_item_1", output.agent.id);
    try testing.expectEqualStrings("ws_item_1", output.agent.workspace_item_id);
    try testing.expectEqualStrings("freshly updated", output.agent.description);

    // Verify persistence with a fresh query.
    var q = try ctx.db.query(alloc,
        "SELECT description FROM agents WHERE id = 'ws_item_1'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (q.next() catch null).?;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("freshly updated", row.values[0]);
}