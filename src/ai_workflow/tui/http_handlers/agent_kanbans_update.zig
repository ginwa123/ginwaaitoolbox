//! `PATCH /api/workspaces/:workspace_id/items/:item_id/agent_kanban`.
//!
//! Body: `{description}`. Updates the description of the agent-kanbans
//! config bound to this kanban workspace_item. Returns 200 with the
//! updated row, or 400/404 for validation errors (same as
//! `agent_kanbans_get.zig`).
//!
//! Layered as:
//!   - `useCase` — validate workspace_item is a kanban with an
//!     `agent_kanbans` row → UPDATE description → SELECT updated row.
//!   - `agentKanbansUpdateHandler` — thin orchestrator over `useCase`.
//!
//! Memory: the per-request arena reaps all allocations at request end,
//! so neither layer needs explicit `free`s.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// HTTP request body for agent-kanban update.
const UpdateAgentKanbanBody = struct {
    description: []const u8 = "",
};

/// Subset of the agent_kanbans row returned by the use-case. Field
/// strings are owned by the caller (lifetime = request arena).
pub const AgentKanban = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const AgentKanbanUpdateError = error{
    /// `workspace_id` or `item_id` path param was missing or empty.
    IdsRequired,
    /// `db.query` failed while looking up the workspace_item.
    LookupFailed,
    /// The workspace_item row did not exist.
    ItemNotFound,
    /// The workspace_item exists but its `item_type` is not `'kanban'`.
    NotAKanban,
    /// The kanban has no `agent_kanbans` row yet (opt-in config).
    NotConfigured,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed (consistency violation).
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `allocator.dupe` failed while copying slice fields.
    OutOfMemory,
};

/// Inputs to the agent-kanban-update use-case.
pub const AgentKanbanUpdateInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    description: []const u8,
};

/// Output of the agent-kanban-update use-case.
pub const AgentKanbanUpdateOutput = struct {
    agent_kanban: AgentKanban,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an agent-kanbans config's description. Validates that the
/// workspace_item exists, is of type `'kanban'`, and has an
/// `agent_kanbans` row. Transport-agnostic (arena + testing allocators).
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: AgentKanbanUpdateInput,
) AgentKanbanUpdateError!AgentKanbanUpdateOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    // Validate item exists + is a kanban.
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.LookupFailed;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "kanban")) return error.NotAKanban;

    // Require an existing config row (spec D3: id == workspace_item_id).
    // Empty-slice-as-NULL guard: COALESCE keeps '' descriptions intact.
    db.exec(allocator,
        "UPDATE agent_kanbans SET description = COALESCE(?, ''), updated_at = datetime('now') WHERE workspace_item_id = ?",
        &[_][]const u8{ input.description, input.item_id },
    ) catch return error.UpdateFailed;

    // Read back the updated row.
    var q2 = db.query(allocator,
        "SELECT id, workspace_item_id, description, IFNULL(created_at, ''), IFNULL(updated_at, '') FROM agent_kanbans WHERE workspace_item_id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.RefetchFailed;
    defer q2.deinit();
    const updated_row = (q2.next() catch null) orelse return error.NotConfigured;
    defer updated_row.deinit(allocator); // safe — we dupe into the struct below

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
        .agent_kanban = .{
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

/// Thin orchestrator over `useCase`.
pub fn agentKanbansUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateAgentKanbanBody, allocator, req.body, .{}) catch {
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
            error.NotAKanban => 400,
            error.NotConfigured => 404,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.LookupFailed => "Failed to query workspace_item",
            error.ItemNotFound => "workspace_item not found",
            error.NotAKanban => "workspace_item is not a kanban",
            error.NotConfigured => "agent_kanbans not configured for this board",
            error.UpdateFailed => "Failed to update agent_kanban",
            error.RefetchFailed => "Failed to read updated agent_kanban",
            error.RowVanished => "agent_kanbans row vanished after UPDATE",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .agent_kanban = output.agent_kanban }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention). Behavioural coverage:
//
//   1. Validation: empty workspace_id OR item_id → IdsRequired
//   2. ItemNotFound / NotAKanban paths
//   3. Happy path: description updated + persisted

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration081CreateAgentKanbans = @import("../../../migrations/migration.zig").Migration081CreateAgentKanbans;

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

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration081CreateAgentKanbans.up(&db, testing.allocator);

    // Seed: configured kanban + bare kanban + agent item.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'kanban', 'My Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_kanbans (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', 'old description')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_bare', 'ws_1', 'kanban', 'Bare Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_agent', 'ws_1', 'agent', 'An agent')",
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
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .item_id = "ws_item_1", .description = "new" }),
    );
}

test "useCase: empty item_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "", .description = "new" }),
    );
}

test "useCase: non-existent workspace_item returns ItemNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_404", .description = "new" }),
    );
}

test "useCase: workspace_item of type agent returns NotAKanban" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAKanban,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_agent", .description = "new" }),
    );
}

test "useCase: happy path updates description and returns row" {
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
        alloc.free(output.agent_kanban.id);
        alloc.free(output.agent_kanban.workspace_item_id);
        alloc.free(output.agent_kanban.description);
        alloc.free(output.agent_kanban.created_at);
        alloc.free(output.agent_kanban.updated_at);
    }
    try testing.expectEqualStrings("ws_item_1", output.agent_kanban.id);
    try testing.expectEqualStrings("freshly updated", output.agent_kanban.description);

    // Verify persistence with a fresh query.
    var q = try ctx.db.query(alloc,
        "SELECT description FROM agent_kanbans WHERE id = 'ws_item_1'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (q.next() catch null).?;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("freshly updated", row.values[0]);
}

test "useCase: empty description persists as empty string, not NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "ws_item_1",
        .description = "",
    });
    defer {
        alloc.free(output.agent_kanban.id);
        alloc.free(output.agent_kanban.workspace_item_id);
        alloc.free(output.agent_kanban.description);
        alloc.free(output.agent_kanban.created_at);
        alloc.free(output.agent_kanban.updated_at);
    }
    // Empty-slice-as-NULL regression: '' must round-trip as '', not NULL.
    try testing.expectEqualStrings("", output.agent_kanban.description);
}
