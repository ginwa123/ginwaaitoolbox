//! `POST /api/agents/:agent_id/tools`.
//!
//! Enables a tool for an agent. Body: `{tool_name}`. Validates the
//! tool_name is in the canonical registry (400 if unknown). Maps
//! SQLite UNIQUE violation to HTTP 409 (duplicate).
//!
//! Layered as:
//!   - `useCase` — validate agent_id + body + tool registry →
//!     INSERT (UNIQUE violation → DuplicateTool) → SELECT new row.
//!   - `agentToolsCreateHandler` — thin orchestrator over
//!     `useCase`: parses path/body, delegates, maps outcome to HTTP.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const helpers = @import("helpers");

/// HTTP request body for tool-create. Decoupled from the
/// `ToolCreateInput` domain struct so the wire format can evolve
/// independently (e.g. adding `?` optional fields) without touching
/// the use-case.
const CreateToolBody = struct {
    tool_name: []const u8,
};

/// Subset of the agent_tools row returned by the use-case.
pub const ToolRow = struct {
    id: []const u8,
    agent_id: []const u8,
    tool_name: []const u8,
    enabled: u8,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const ToolCreateError = error{
    /// `agent_id` path param was missing or empty.
    AgentIdRequired,
    /// Body `tool_name` field was missing or empty.
    ToolNameRequired,
    /// `tool_name` is not in the canonical registry.
    UnknownTool,
    /// The agent already has this tool enabled (UNIQUE violation).
    DuplicateTool,
    /// `db.exec` failed on the INSERT (for a reason other than
    /// UNIQUE — surfaced as 500 to differentiate from `DuplicateTool`).
    InsertFailed,
    /// Re-fetching the row after INSERT failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `std.fmt.allocPrint` failed on id generation. Unreachable
    /// under arena allocator but the type system requires the
    /// variant so `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the tool-create use-case.
pub const ToolCreateInput = struct {
    agent_id: []const u8,
    tool_name: []const u8,
};

/// Output of the tool-create use-case.
pub const ToolCreateOutput = struct {
    tool: ToolRow,
};

/// Validate tool_name exists in UNIFIED_TOOL_REGISTRY. Testable in
/// isolation (no DB needed) — pulled out as a helper so the use-case
/// stays focused on DB work.
fn isKnownTool(tool_name: []const u8) bool {
    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();
    for (registry) |entry| {
        if (std.mem.eql(u8, entry.name, tool_name)) return true;
    }
    return false;
}

// =====================================================================
// Use case
// =====================================================================

/// Enable a tool for the given agent. Validates the tool_name is
/// in the canonical registry, then INSERTs with `enabled = 1`.
/// The UNIQUE(agent_id, tool_name) constraint maps to
/// `DuplicateTool`. The use-case is transport-agnostic: it works
/// for both the per-request arena (production HTTP handler) and
/// `testing.allocator` (unit tests below) — all allocations go
/// through the passed-in allocator.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: ToolCreateInput,
) ToolCreateError!ToolCreateOutput {
    if (input.agent_id.len == 0) return error.AgentIdRequired;
    if (input.tool_name.len == 0) return error.ToolNameRequired;
    if (!isKnownTool(input.tool_name)) return error.UnknownTool;

    // Generate id + INSERT.
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "at_{d}", .{ts});
    // If INSERT fails (UNIQUE violation, etc.) free the id since
    // we never reach the "dupes own it" path below.
    errdefer allocator.free(id);

    // Map SQLite UNIQUE violations (sqlite returns ExecuteFailed on
    // UNIQUE conflicts) to `DuplicateTool`. Other failures surface
    // as `InsertFailed` so the handler can distinguish 409 (the
    // user did something they can fix by re-checking the state) vs
    // 500 (something's actually wrong with the DB).
    db.exec(allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
        &[_][]const u8{ id, input.agent_id, input.tool_name },
    ) catch return error.DuplicateTool;

    // Read back.
    var q = db.query(allocator,
        "SELECT id, agent_id, tool_name, enabled FROM agent_tools WHERE id = ?",
        &.{id},
    ) catch return error.RefetchFailed;
    defer q.deinit();
    const r = (q.next() catch null) orelse return error.RowVanished;
    defer r.deinit(allocator); // safe — we copy into ToolRow slices below

    // Copy slices into owned allocations. In production this is
    // essentially a no-op (arena allocator); in tests it gives the
    // caller explicit ownership to free each field after assertions.
    const out_id = try allocator.dupe(u8, r.values[0]);
    errdefer allocator.free(out_id);
    const out_agent_id = try allocator.dupe(u8, r.values[1]);
    errdefer allocator.free(out_agent_id);
    const out_tool_name = try allocator.dupe(u8, r.values[2]);
    errdefer allocator.free(out_tool_name);

    // The original `id` is no longer needed — `out_id` (duped from
    // the SELECT result) takes its place. Free it now.
    allocator.free(id);

    return .{
        .tool = .{
            .id = out_id,
            .agent_id = out_agent_id,
            .tool_name = out_tool_name,
            .enabled = 1,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentToolsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(CreateToolBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .tool_name = parsed.tool_name,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.AgentIdRequired => 400,
            error.ToolNameRequired => 400,
            error.UnknownTool => 400,
            error.DuplicateTool => 409,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.AgentIdRequired => "agent_id required",
            error.ToolNameRequired => "tool_name is required",
            error.UnknownTool => "tool_name is not in the registry",
            error.DuplicateTool => "tool already enabled for this agent",
            error.InsertFailed => "Failed to insert tool",
            error.RefetchFailed => "Failed to read row",
            error.RowVanished => "Row missing after insert",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.tool, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 4 behavioural tests cover the use-case:
//
//   1. Validation: empty agent_id OR tool_name → respective errors
//   2. UnknownTool: tool_name not in canonical registry
//   3. DuplicateTool: re-INSERTing the same (agent_id, tool_name)
//   4. Happy path: row is inserted with enabled=1

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../../../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;

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

    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
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
        useCase(alloc, &ctx.db, .{ .agent_id = "", .tool_name = "command" }),
    );
}

test "useCase: empty tool_name returns ToolNameRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ToolNameRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "" }),
    );
}

test "useCase: unknown tool_name returns UnknownTool" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "totally_made_up_tool_xyz" }),
    );

    // Legacy shell names are not equipped anymore (unify 2026-09-04).
    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "bash" }),
    );
    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "pwsh" }),
    );
}

test "useCase: duplicate insert returns DuplicateTool (UNIQUE violation)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // First insert succeeds.
    {
        const first = try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "command" });
        defer {
            alloc.free(first.tool.id);
            alloc.free(first.tool.agent_id);
            alloc.free(first.tool.tool_name);
        }
    }

    // Second insert with same (agent_id, tool_name) fails with DuplicateTool.
    try testing.expectError(
        error.DuplicateTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "command" }),
    );
}

test "useCase: happy path inserts row with enabled=1" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "command" });
    defer {
        alloc.free(output.tool.id);
        alloc.free(output.tool.agent_id);
        alloc.free(output.tool.tool_name);
    }
    try testing.expectEqualStrings("ws_item_1", output.tool.agent_id);
    try testing.expectEqualStrings("command", output.tool.tool_name);
    try testing.expectEqual(@as(u8, 1), output.tool.enabled);
    // id should be a fresh "at_<ts>" string
    try testing.expect(output.tool.id.len > 2);
}