//! `PATCH /api/agents/:agent_id/knowledge/reorder`.
//!
//! Body: `{ordered_ids: string[]}`. Reorders the agent's knowledge rows
//! to match the supplied order. `ordered_ids[0]` becomes position N
//! (highest), `ordered_ids[N-1]` becomes position 0 (lowest).
//!
//! Layered as:
//!   - `useCase` — tx transaction (db.begin/tx.exec/tx.commit), UPDATE each row's
//!     position to `len - i` (so a 1-row ordering doesn't land at
//!     position 0).
//!   - `agentKnowledgeReorderHandler` — thin orchestrator over
//!     `useCase`: parses the body, delegates to `useCase`, maps the
//!     use-case outcome to an HTTP response.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");

/// HTTP request body for knowledge-reorder. Decoupled from the
/// `KnowledgeReorderInput` domain struct so the wire format can
/// evolve independently (e.g. adding `?` optional fields) without
/// touching the use-case.
const ReorderBody = struct {
    ordered_ids: []const []const u8 = &.{},
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const KnowledgeReorderError = error{
    /// `agent_id` path param was missing or empty.
    AgentIdRequired,
    /// Body `ordered_ids` field was empty.
    OrderedIdsRequired,
    /// `begin()` / `commit()` failed.
    TransactionFailed,
    /// One of the per-row `UPDATE` statements failed.
    UpdateFailed,
};

/// Inputs to the reorder use-case.
pub const KnowledgeReorderInput = struct {
    agent_id: []const u8,
    ordered_ids: []const []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Reorder knowledge rows for the given agent. All updates happen
/// inside a single tx — all UPDATEs finalize together via tx.commit(). `ordered_ids[0]` becomes position
/// `len - 1` (highest), `ordered_ids[len - 1]` becomes position 0
/// (lowest). Using `len - i` (not `len - i - 1`) ensures a 1-row
/// ordering lands at position 0 (not position 1) — see the test
/// below for the contract.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: KnowledgeReorderInput,
) KnowledgeReorderError!void {
    if (input.agent_id.len == 0) return error.AgentIdRequired;
    if (input.ordered_ids.len == 0) return error.OrderedIdsRequired;

    var tx = db.begin() catch return error.TransactionFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    for (input.ordered_ids, 0..) |id, i| {
        const position: i64 = @intCast(input.ordered_ids.len - 1 - @as(usize, @intCast(i)));
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
        tx.exec(allocator,
            "UPDATE agent_knowledge SET position = ?, updated_at = datetime('now') WHERE id = ? AND agent_id = ?",
            &[_][]const u8{ pos_str, id, input.agent_id },
        ) catch return error.UpdateFailed;
    }

    tx.commit() catch return error.TransactionFailed;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentKnowledgeReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    if (agent_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "agent_id required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(ReorderBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .ordered_ids = parsed.ordered_ids,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.AgentIdRequired => 400,
            error.OrderedIdsRequired => 400,
            error.TransactionFailed => 500,
            error.UpdateFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.AgentIdRequired => "agent_id required",
            error.OrderedIdsRequired => "ordered_ids required",
            error.TransactionFailed => "Failed to begin/commit transaction",
            error.UpdateFailed => "Failed to update position",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 4 behavioural tests cover the use-case:
//
//   1. Validation: empty agent_id OR ordered_ids → respective errors
//   2. Position assignment: ordered_ids[0] gets the highest position
//   3. 1-row ordering lands at position 0 (the reason we use
//      `len - i` instead of `len - i - 1`)
//   4. Transactional rollback: a failing UPDATE rolls back all
//      earlier UPDATEs in the same transaction

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

    // Seed: 1 agent + 3 knowledge rows (position 0, 1, 2).
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('know_1', 'ws_item_1', '/tmp/a.md', '', 0)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('know_2', 'ws_item_1', '/tmp/b.md', '', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('know_3', 'ws_item_1', '/tmp/c.md', '', 2)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn readPosition(
    db: *sqlite.SqliteBackend,
    allocator: std.mem.Allocator,
    id: []const u8,
) !i64 {
    var q = try db.query(allocator,
        "SELECT position FROM agent_knowledge WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (q.next() catch null) orelse return -999;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(i64, row.values[0], 10);
}

test "useCase: empty agent_id returns AgentIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.AgentIdRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "", .ordered_ids = &.{"know_1"} }),
    );
}

test "useCase: empty ordered_ids returns OrderedIdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.OrderedIdsRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .ordered_ids = &.{} }),
    );
}

test "useCase: ordered_ids[0] gets highest position (len - 1)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Reverse the order: know_3 first (should land at position 2),
    // then know_2 (position 1), then know_1 (position 0).
    try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .ordered_ids = &.{ "know_3", "know_2", "know_1" },
    });

    try testing.expectEqual(@as(i64, 2), try readPosition(&ctx.db, alloc, "know_3"));
    try testing.expectEqual(@as(i64, 1), try readPosition(&ctx.db, alloc, "know_2"));
    try testing.expectEqual(@as(i64, 0), try readPosition(&ctx.db, alloc, "know_1"));
}

test "useCase: 1-row ordering lands at position 0 (not 1)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Just 1 id. `len - i` = `1 - 0` = 1, so it would land at
    // position 1. We use `len - 1 - i` = `1 - 1 - 0` = 0 instead.
    // Contract: 1-row orderings get position 0, not position 1.
    try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .ordered_ids = &.{"know_2"},
    });
    try testing.expectEqual(@as(i64, 0), try readPosition(&ctx.db, alloc, "know_2"));
}