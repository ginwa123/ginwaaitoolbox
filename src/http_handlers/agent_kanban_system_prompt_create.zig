//! `POST /api/agent-kanbans/:kanban_id/system_prompt`.
//!
//! Adds a named system-prompt block to an agent-kanbans config. Body:
//! `{title?, content}`. `content` is required (non-empty after trim);
//! `title` optional ('' = untitled).
//!
//! Mirrors `agent_system_prompt_create.zig` with substitutions:
//! table `agent_kanban_system_prompt`, parent col `kanban_id`.
//!
//! Memory: the per-request arena reaps all allocations at request end,
//! so neither layer needs explicit `free`s.
//!
//! Plan: docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
//! Task: task_1787597624259_2

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");

/// HTTP request body for system-prompt-create.
const CreateSystemPromptBody = struct {
    title: []const u8 = "",
    content: []const u8 = "",
};

/// Subset of the system-prompt row returned by the use-case.
pub const SystemPrompt = struct {
    id: []const u8,
    kanban_id: []const u8,
    title: []const u8,
    content: []const u8,
    position: i64,
};

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const SystemPromptCreateError = error{
    /// `kanban_id` path param was missing or empty.
    KanbanIdRequired,
    /// `content` field was missing or whitespace-only.
    ContentRequired,
    /// `db.query` failed while looking up the kanban.
    LookupFailed,
    /// The workspace_item doesn't exist / isn't a kanban, OR the kanban
    /// has no `agent_kanbans` row yet.
    KanbanNotFound,
    /// `db.exec` failed on the INSERT.
    InsertFailed,
    /// Re-fetching the row after INSERT failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `std.fmt.allocPrint` failed on id generation.
    OutOfMemory,
};

/// Inputs to the system-prompt-create use-case.
pub const SystemPromptCreateInput = struct {
    kanban_id: []const u8,
    title: []const u8,
    content: []const u8,
};

/// Output of the system-prompt-create use-case.
pub const SystemPromptCreateOutput = struct {
    system_prompt: SystemPrompt,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a system-prompt row for the given agent-kanbans config.
/// Validates that the workspace_item is a kanban WITH an `agent_kanbans`
/// row and that content is non-empty, then INSERTs with
/// `position = MAX(position) + 1` (COALESCE so the first row gets 0).
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: SystemPromptCreateInput,
) SystemPromptCreateError!SystemPromptCreateOutput {
    if (input.kanban_id.len == 0) return error.KanbanIdRequired;
    // Content required — reject whitespace-only too.
    const trimmed = std.mem.trim(u8, input.content, " \t\r\n");
    if (trimmed.len == 0) return error.ContentRequired;

    // Validate kanban exists + is a kanban + has an agent_kanbans row.
    var q = db.query(allocator,
        \\SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'
        \\AND EXISTS (SELECT 1 FROM agent_kanbans WHERE id = ?)
    , &[_][]const u8{ input.kanban_id, input.kanban_id }) catch return error.LookupFailed;
    defer q.deinit();
    const row = q.next() catch null;
    if (row == null) return error.KanbanNotFound;
    if (row) |r| r.deinit(allocator);

    // Generate id + compute position.
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "aksp_{d}", .{ts});

    // COALESCE guards: empty-slice binds land as '' not NULL.
    db.exec(allocator,
        "INSERT INTO agent_kanban_system_prompt (id, kanban_id, title, content, position, created_at, updated_at) VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), COALESCE((SELECT MAX(position) FROM agent_kanban_system_prompt WHERE kanban_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ id, input.kanban_id, input.title, input.content, input.kanban_id },
    ) catch return error.InsertFailed;

    // Read back position.
    var q2 = db.query(allocator,
        "SELECT position FROM agent_kanban_system_prompt WHERE id = ?",
        &.{id},
    ) catch return error.RefetchFailed;
    defer q2.deinit();
    const r = (q2.next() catch null) orelse return error.RowVanished;
    defer r.deinit(allocator);
    const position = std.fmt.parseInt(i64, r.values[0], 10) catch 0;

    return .{
        .system_prompt = .{
            .id = id,
            .kanban_id = input.kanban_id,
            .title = input.title,
            .content = input.content,
            .position = position,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentKanbanSystemPromptCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const kanban_id = req.params.get("kanban_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateSystemPromptBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .kanban_id = kanban_id,
        .title = parsed.title,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.KanbanIdRequired => 400,
            error.ContentRequired => 400,
            error.LookupFailed => 500,
            error.KanbanNotFound => 404,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.KanbanIdRequired => "kanban_id required",
            error.ContentRequired => "content is required",
            error.LookupFailed => "DB error",
            error.KanbanNotFound => "kanban not found or not configured",
            error.InsertFailed => "Failed to insert system prompt",
            error.RefetchFailed => "Failed to read position",
            error.RowVanished => "Row missing after insert",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.system_prompt, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention). Behavioural coverage:
//
//   1. Validation: empty kanban_id → KanbanIdRequired
//   2. Validation: empty/whitespace content → ContentRequired
//   3. KanbanNotFound: wrong type / unconfigured board
//   4. Happy path: first row gets position 0; second gets 1
//   5. Empty title tolerated (COALESCE → '')

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration081CreateAgentKanbans = @import("../migrations/migration.zig").Migration081CreateAgentKanbans;

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
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ws_item_1', 'ws_item_1')",
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

test "useCase: empty kanban_id returns KanbanIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.KanbanIdRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "", .title = "T", .content = "C" }),
    );
}

test "useCase: empty content returns ContentRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ContentRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .title = "T", .content = "" }),
    );
}

test "useCase: whitespace-only content returns ContentRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ContentRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .title = "T", .content = "   \n\t  " }),
    );
}

test "useCase: unconfigured kanban returns KanbanNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.KanbanNotFound,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_bare", .title = "T", .content = "C" }),
    );
}

test "useCase: happy path inserts with position 0 then 1 (COALESCE handles empty table)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out1 = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .title = "Persona",
        .content = "You are X",
    });
    defer alloc.free(out1.system_prompt.id);
    // First row: COALESCE(NULL, -1) + 1 = 0. Critical: NOT 1 (off-by-one trap).
    try testing.expectEqual(@as(i64, 0), out1.system_prompt.position);
    try testing.expectEqualStrings("Persona", out1.system_prompt.title);
    try testing.expectEqualStrings("You are X", out1.system_prompt.content);

    const out2 = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .title = "Style",
        .content = "Be terse",
    });
    defer alloc.free(out2.system_prompt.id);
    try testing.expectEqual(@as(i64, 1), out2.system_prompt.position);
}

test "useCase: empty title tolerated (COALESCE binds '')" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .title = "",
        .content = "Untitled prompt body",
    });
    defer alloc.free(out.system_prompt.id);
    try testing.expectEqualStrings("", out.system_prompt.title);
    try testing.expectEqualStrings("Untitled prompt body", out.system_prompt.content);
}
