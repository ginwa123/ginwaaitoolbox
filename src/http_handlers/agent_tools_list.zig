//! `GET /api/agents/:agent_id/tools`.
//!
//! Returns `{tools: [string]}` — the enabled tool_names for the agent.
//! Mirrors the `agentsGetHandler.tools` field, but exposed as its
//! own endpoint so the frontend's Tools panel can refresh without
//! re-fetching knowledge.
//!
//! Layered as:
//!   - `useCase` — SELECT enabled tool_names, return owned slice.
//!   - `agentToolsListHandler` — thin orchestrator over `useCase`:
//!     resolves the singleton DB handle, delegates to `useCase`,
//!     marshals the result to JSON.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const ToolListError = error{
    /// `agent_id` path param was missing or empty.
    AgentIdRequired,
    /// `db.query` failed.
    QueryFailed,
    /// `allocator.dupe` / `toOwnedSlice` failed. In production this
    /// is effectively unreachable (the per-request arena reaps
    /// everything at request end) but the type system requires the
    /// variant so the `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the list-tools use-case.
pub const ToolListInput = struct {
    agent_id: []const u8,
};

/// Output of the list-tools use-case. `tool_names` is owned by the
/// caller (lifetime = request arena — freed by the HTTP server
/// when the request ends).
pub const ToolListOutput = struct {
    tool_names: []const []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the enabled tool_names for the agent. Returns an owned
/// slice of `[]const u8` ordered by tool_name ASC. The use-case is
/// transport-agnostic: it works for both the per-request arena
/// (production HTTP handler) and `testing.allocator` (unit tests
/// below) — all allocations go through the passed-in allocator.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: ToolListInput,
) ToolListError!ToolListOutput {
    if (input.agent_id.len == 0) return error.AgentIdRequired;

    var q = db.query(allocator,
        "SELECT tool_name FROM agent_tools WHERE agent_id = ? AND enabled = 1 ORDER BY tool_name ASC",
        &[_][]const u8{input.agent_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList([]u8) = .empty;
    while ((q.next() catch null)) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try allocator.dupe(u8, r.values[0]));
    }
    return .{ .tool_names = try list.toOwnedSlice(allocator) };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Resolves the singleton DB
/// handle, delegates to `useCase`, and maps the use-case outcome to
/// an HTTP response.
pub fn agentToolsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";

    const output = useCase(allocator, sqlite_db, .{ .agent_id = agent_id }) catch |err| {
        const status: u16 = switch (err) {
            error.AgentIdRequired => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.AgentIdRequired => "agent_id required",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .tools = output.tool_names }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 4 behavioural tests cover the use-case:
//
//   1. Validation: empty agent_id → AgentIdRequired
//   2. Empty result: agent exists but has no tools → empty slice
//   3. Filter by enabled: only enabled=1 tools are returned
//   4. Ordering: tool_names are sorted ASC

const sqlite = @import("nalarcore").sqlite;
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

    // Seed: 1 agent + 4 tools in mixed enabled states.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_1', 'ws_item_1', 'write_file', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_2', 'ws_item_1', 'bash', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_3', 'ws_item_1', 'read_file', 0)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_4', 'ws_item_1', 'glob', 1)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty agent_id returns AgentIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.AgentIdRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "" }),
    );
}

test "useCase: agent with no tools returns empty slice" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert a second agent with no tools.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_empty', 'ws_1', 'agent', 'Empty')",
        &[_][]const u8{},
    );
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_empty', 'ws_item_empty', '')",
        &[_][]const u8{},
    );

    const output = try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_empty" });
    defer alloc.free(output.tool_names);
    try testing.expectEqual(@as(usize, 0), output.tool_names.len);
}

test "useCase: returns only enabled=1 tools, ordered by tool_name ASC" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1" });
    defer {
        for (output.tool_names) |n| alloc.free(n);
        alloc.free(output.tool_names);
    }
    // Seeded: write_file (1), bash (1), read_file (0), glob (1).
    // Expect: bash, glob, write_file (read_file excluded).
    try testing.expectEqual(@as(usize, 3), output.tool_names.len);
    try testing.expectEqualStrings("bash", output.tool_names[0]);
    try testing.expectEqualStrings("glob", output.tool_names[1]);
    try testing.expectEqualStrings("write_file", output.tool_names[2]);
}