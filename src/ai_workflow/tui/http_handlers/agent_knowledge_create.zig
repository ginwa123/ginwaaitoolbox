//! `POST /api/agents/:agent_id/knowledge`.
//!
//! Adds a markdown knowledge file to an Agent. Body: `{file_path, label?, position?}`.
//! `file_path` MUST be absolute (`std.fs.path.isAbsolute`) — relative
//! paths return 400.
//!
//! Layered as:
//!   - `useCase` — validate agent + absolute path → INSERT with
//!     `position = MAX + 1` (COALESCE) → SELECT new row.
//!   - `agentKnowledgeCreateHandler` — thin orchestrator over
//!     `useCase`: parses path/body, delegates, maps outcome to HTTP.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = nalarcore.helpers;

/// HTTP request body for knowledge-create. Decoupled from the
/// `KnowledgeCreateInput` domain struct so the wire format can
/// evolve independently (e.g. adding `?` optional fields) without
/// touching the use-case.
const CreateKnowledgeBody = struct {
    file_path: []const u8,
    label: []const u8 = "",
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = struct {
    id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    position: i64,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const KnowledgeCreateError = error{
    /// `agent_id` path param was missing or empty.
    AgentIdRequired,
    /// `file_path` field was missing or empty.
    FilePathRequired,
    /// `file_path` is not absolute.
    NotAbsolutePath,
    /// `db.query` failed while looking up the agent.
    LookupFailed,
    /// The workspace_item row did not exist or was not of type `'agent'`.
    AgentNotFound,
    /// `db.exec` failed on the INSERT.
    InsertFailed,
    /// Re-fetching the row after INSERT failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `std.fmt.allocPrint` failed on id generation. Unreachable
    /// under arena allocator (test builds with `testing.allocator`
    /// can hit it), but the type system requires the variant so
    /// `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the knowledge-create use-case.
pub const KnowledgeCreateInput = struct {
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
};

/// Output of the knowledge-create use-case. `knowledge` is owned by
/// the caller (lifetime = request arena).
pub const KnowledgeCreateOutput = struct {
    knowledge: Knowledge,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a knowledge row for the given agent. Validates that the
/// agent exists + is of type `'agent'`, that the file_path is
/// absolute, then INSERTs with `position = MAX(position) + 1`
/// (COALESCE so the first row gets position 0, not -1 + 1). The
/// use-case is transport-agnostic: it works for both the
/// per-request arena (production HTTP handler) and
/// `testing.allocator` (unit tests below) — all allocations go
/// through the passed-in allocator.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: KnowledgeCreateInput,
) KnowledgeCreateError!KnowledgeCreateOutput {
    if (input.agent_id.len == 0) return error.AgentIdRequired;
    if (input.file_path.len == 0) return error.FilePathRequired;
    if (!std.fs.path.isAbsolute(input.file_path)) return error.NotAbsolutePath;

    // Validate agent exists + is an agent.
    var q = db.query(allocator,
        "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'agent'",
        &[_][]const u8{input.agent_id},
    ) catch return error.LookupFailed;
    defer q.deinit();
    const row = q.next() catch null;
    if (row == null) return error.AgentNotFound;
    // Drop the row's values[] — we only care that a row was found.
    // In production the arena reaps it; in tests this leaks by
    // design (per user's "no need to clear one by one" rule).
    if (row) |r | r.deinit(allocator);

    // Generate id + compute position.
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "know_{d}", .{ts});

    // INSERT with COALESCE for position (mirrors kanban_column_create).
    db.exec(allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position, created_at, updated_at) VALUES (?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM agent_knowledge WHERE agent_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ id, input.agent_id, input.file_path, input.label, input.agent_id },
    ) catch return error.InsertFailed;

    // Read back position.
    var q2 = db.query(allocator,
        "SELECT position FROM agent_knowledge WHERE id = ?",
        &.{id},
    ) catch return error.RefetchFailed;
    defer q2.deinit();
    const r = (q2.next() catch null) orelse return error.RowVanished;
    defer r.deinit(allocator);
    const position = std.fmt.parseInt(i64, r.values[0], 10) catch 0;

    return .{
        .knowledge = .{
            .id = id,
            .agent_id = input.agent_id,
            .file_path = input.file_path,
            .label = input.label,
            .position = position,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentKnowledgeCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.AgentIdRequired => 400,
            error.FilePathRequired => 400,
            error.NotAbsolutePath => 400,
            error.LookupFailed => 500,
            error.AgentNotFound => 404,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.AgentIdRequired => "agent_id required",
            error.FilePathRequired => "file_path is required",
            error.NotAbsolutePath => "file_path must be absolute",
            error.LookupFailed => "DB error",
            error.AgentNotFound => "agent not found",
            error.InsertFailed => "Failed to insert knowledge",
            error.RefetchFailed => "Failed to read position",
            error.RowVanished => "Row missing after insert",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.knowledge, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 5 behavioural tests cover the use-case:
//
//   1. Validation: empty agent_id → AgentIdRequired
//   2. Validation: empty file_path → FilePathRequired
//   3. Validation: relative file_path → NotAbsolutePath
//   4. AgentNotFound: workspace_item doesn't exist
//   5. Happy path: first row gets position 0; COALESCE handles empty agents correctly

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

    // Seed: 1 workspace_item of type 'agent' + matching agents row.
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
        useCase(alloc, &ctx.db, .{
            .agent_id = "",
            .file_path = "/tmp/a.md",
            .label = "",
        }),
    );
}

test "useCase: empty file_path returns FilePathRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.FilePathRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .file_path = "",
            .label = "",
        }),
    );
}

test "useCase: relative file_path returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .file_path = "relative/path.md",
            .label = "",
        }),
    );
}

test "useCase: non-existent agent returns AgentNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.AgentNotFound,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_404",
            .file_path = "/tmp/a.md",
            .label = "",
        }),
    );
}

test "useCase: happy path inserts with position 0 (COALESCE handles empty agents)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .file_path = "/tmp/a.md",
        .label = "First",
    });
    defer alloc.free(output.knowledge.id);
    // First row: COALESCE(NULL, -1) + 1 = 0. Critical: NOT 1 (off-by-one trap).
    try testing.expectEqual(@as(i64, 0), output.knowledge.position);
    try testing.expectEqualStrings("/tmp/a.md", output.knowledge.file_path);
    try testing.expectEqualStrings("First", output.knowledge.label);
}