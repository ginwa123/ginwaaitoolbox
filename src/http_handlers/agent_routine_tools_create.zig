//! `POST /api/agent-routines/:routine_id/tools`.
//!
//! Enables a tool for an agent-routines config. Body: `{tool_name}`.
//! Validates the tool_name is in the canonical registry (400 if
//! unknown). Maps SQLite UNIQUE violation to HTTP 409 (duplicate).
//!
//! Mirrors `agent_tools_create.zig` with substitutions:
//! table `agent_routine_tools`, parent col `routine_id`, id prefix `art_`.
//!
//! Memory: the per-request arena reaps all allocations at request end,
//! so neither layer needs explicit `free`s.
//!
//! Plan: Routine mode task_1789505553300_1 (option A, mirror agent_routine_*)
//! Task: task_1789505553300_1

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const helpers = @import("helpers");

/// HTTP request body for tool-create.
const CreateToolBody = struct {
    tool_name: []const u8,
};

/// Subset of the agent_routine_tools row returned by the use-case.
pub const ToolRow = struct {
    id: []const u8,
    routine_id: []const u8,
    tool_name: []const u8,
    enabled: u8,
};

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const ToolCreateError = error{
    /// `routine_id` path param was missing or empty.
    RoutineIdRequired,
    /// Body `tool_name` field was missing or empty.
    ToolNameRequired,
    /// `tool_name` is not in the canonical registry.
    UnknownTool,
    /// The workspace_item doesn't exist OR isn't a routine.
    RoutineNotFound,
    /// The routine already has this tool enabled (UNIQUE violation).
    DuplicateTool,
    /// `db.exec` failed on the INSERT (non-UNIQUE reason — 500).
    InsertFailed,
    /// Re-fetching the row after INSERT failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `std.fmt.allocPrint` failed on id generation.
    OutOfMemory,
};

/// Inputs to the tool-create use-case.
pub const ToolCreateInput = struct {
    routine_id: []const u8,
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

/// Enable a tool for the given agent-routines config. Validates the
/// tool_name is in the canonical registry, then INSERTs with
/// `enabled = 1`. The UNIQUE(routine_id, tool_name) constraint maps to
/// `DuplicateTool`. Transport-agnostic.
///
/// Auto-seeds the `agent_routines` row (with empty description) when
/// it doesn't exist yet — matches the agent world where enabling a
/// tool auto-creates the parent config row. Keeps the frontend's
/// unconfigured→configured flow to a single click.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: ToolCreateInput,
) ToolCreateError!ToolCreateOutput {
    if (input.routine_id.len == 0) return error.RoutineIdRequired;
    if (input.tool_name.len == 0) return error.ToolNameRequired;
    if (!isKnownTool(input.tool_name)) return error.UnknownTool;

    // Validate the workspace_item is a routine + auto-seed the
    // agent_routines row if missing (opt-in config → enabled-tool
    // implies configured). The INSERT is idempotent because of the
    // UNIQUE(workspace_item_id) constraint — we catch the conflict
    // and treat it as success.
    {
        var q = db.query(allocator,
            \\SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'routine'
        , &[_][]const u8{input.routine_id}) catch return error.InsertFailed;
        defer q.deinit();
        const row = q.next() catch null;
        if (row) |r| r.deinit(allocator);
        if (row == null) return error.RoutineNotFound;
    }

    // Auto-seed the agent_routines row. INSERT OR IGNORE so re-enabling
    // the same tool doesn't trip the UNIQUE(workspace_item_id) constraint.
    db.exec(allocator,
        "INSERT OR IGNORE INTO agent_routines (id, workspace_item_id) VALUES (?, ?)",
        &[_][]const u8{ input.routine_id, input.routine_id },
    ) catch {};

    // Generate id + INSERT.
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "art_{d}", .{ts});
    errdefer allocator.free(id);

    // Map SQLite UNIQUE violations to `DuplicateTool`. Other failures
    // surface as `InsertFailed` so the handler can distinguish 409 vs 500.
    db.exec(allocator,
        "INSERT INTO agent_routine_tools (id, routine_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
        &[_][]const u8{ id, input.routine_id, input.tool_name },
    ) catch return error.DuplicateTool;

    // Read back.
    var q = db.query(allocator,
        "SELECT id, routine_id, tool_name, enabled FROM agent_routine_tools WHERE id = ?",
        &.{id},
    ) catch return error.RefetchFailed;
    defer q.deinit();
    const r = (q.next() catch null) orelse return error.RowVanished;
    defer r.deinit(allocator); // safe — we copy into ToolRow slices below

    const out_id = try allocator.dupe(u8, r.values[0]);
    errdefer allocator.free(out_id);
    const out_routine_id = try allocator.dupe(u8, r.values[1]);
    errdefer allocator.free(out_routine_id);
    const out_tool_name = try allocator.dupe(u8, r.values[2]);
    errdefer allocator.free(out_tool_name);

    // The original `id` is no longer needed — out_id takes its place.
    allocator.free(id);

    return .{
        .tool = .{
            .id = out_id,
            .routine_id = out_routine_id,
            .tool_name = out_tool_name,
            .enabled = 1,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentRoutineToolsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const routine_id = req.params.get("routine_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(CreateToolBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .routine_id = routine_id,
        .tool_name = parsed.tool_name,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.RoutineIdRequired => 400,
            error.ToolNameRequired => 400,
            error.UnknownTool => 400,
            error.RoutineNotFound => 404,
            error.DuplicateTool => 409,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.RoutineIdRequired => "routine_id required",
            error.ToolNameRequired => "tool_name is required",
            error.UnknownTool => "tool_name is not in the registry",
            error.RoutineNotFound => "routine not found",
            error.DuplicateTool => "tool already enabled for this routine",
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
// impl + tests in one file (project convention). Behavioural coverage:
//
//   1. Validation: empty routine_id OR tool_name → respective errors
//   2. UnknownTool: tool_name not in canonical registry
//   3. DuplicateTool: re-INSERTing the same (routine_id, tool_name)
//   4. Happy path: row is inserted with enabled=1

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration087CreateAgentRoutines = @import("../migrations/migration.zig").Migration087CreateAgentRoutines;

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
    try Migration087CreateAgentRoutines.up(&db, testing.allocator);

    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'routine', 'My Routine')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_routines (id, workspace_item_id) VALUES ('ws_item_1', 'ws_item_1')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty routine_id returns RoutineIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.RoutineIdRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "", .tool_name = "command" }),
    );
}

test "useCase: empty tool_name returns ToolNameRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ToolNameRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .tool_name = "" }),
    );
}

test "useCase: unknown tool_name returns UnknownTool" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .tool_name = "totally_made_up_tool_xyz" }),
    );

    // Legacy shell names are not equipped anymore (unify 2026-09-04).
    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .tool_name = "bash" }),
    );
    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .tool_name = "pwsh" }),
    );
}

test "useCase: duplicate insert returns DuplicateTool (UNIQUE violation)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // First insert succeeds.
    {
        const first = try useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .tool_name = "command" });
        defer {
            alloc.free(first.tool.id);
            alloc.free(first.tool.routine_id);
            alloc.free(first.tool.tool_name);
        }
    }

    // Second insert with same (routine_id, tool_name) fails with DuplicateTool.
    try testing.expectError(
        error.DuplicateTool,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .tool_name = "command" }),
    );
}

test "useCase: happy path inserts row with enabled=1" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .tool_name = "command" });
    defer {
        alloc.free(output.tool.id);
        alloc.free(output.tool.routine_id);
        alloc.free(output.tool.tool_name);
    }
    try testing.expectEqualStrings("ws_item_1", output.tool.routine_id);
    try testing.expectEqualStrings("command", output.tool.tool_name);
    try testing.expectEqual(@as(u8, 1), output.tool.enabled);
    // id should be a fresh "art_<ts>" string
    try testing.expect(output.tool.id.len > 3);
}
