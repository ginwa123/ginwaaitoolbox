//! `DELETE /api/agents/:agent_id/system_prompt/:prompt_id`.
//! Removes a system-prompt entry. Returns `{ok: true}` on success.
//!
//! Layered as:
//!   - `useCase` — business logic (validate params → DELETE row).
//!   - `agentSystemPromptDeleteHandler` — thin orchestrator over
//!     `useCase`: parses the path params, resolves the singleton DB
//!     handle, delegates to `useCase`, maps the use-case outcome to
//!     an HTTP response.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit `free`s.
//!
//! Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md
//! Task: task_1787408958280_1

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const SystemPromptDeleteError = error{
    /// `agent_id` or `prompt_id` path param was missing or empty.
    IdsRequired,
    /// `db.exec` failed on the DELETE.
    DeleteFailed,
};

/// Inputs to the delete-system-prompt use-case.
pub const SystemPromptDeleteInput = struct {
    agent_id: []const u8,
    prompt_id: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a system-prompt row for the given agent. The use-case is
/// transport-agnostic: it works for both the per-request arena
/// (production HTTP handler) and `testing.allocator` (unit tests
/// below) — all allocations go through the passed-in allocator.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: SystemPromptDeleteInput,
) SystemPromptDeleteError!void {
    if (input.agent_id.len == 0 or input.prompt_id.len == 0) {
        return error.IdsRequired;
    }

    db.exec(allocator,
        "DELETE FROM agent_system_prompt WHERE id = ? AND agent_id = ?",
        &[_][]const u8{ input.prompt_id, input.agent_id },
    ) catch return error.DeleteFailed;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentSystemPromptDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const prompt_id = req.params.get("prompt_id") orelse "";

    useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .prompt_id = prompt_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "agent_id and prompt_id required",
            error.DeleteFailed => "Failed to delete",
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
// Behavioural tests cover the use-case:
//
//   1. Validation: empty agent_id OR prompt_id → IdsRequired
//   2. Happy path: a matching row is removed
//   3. Idempotency: a non-existent prompt_id doesn't error

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;
const Migration080AddAgentSystemPrompt = @import("../migrations/migration.zig").Migration080AddAgentSystemPrompt;

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

    // Migration 076 (Agent Mode) only creates the `agents`,
    // `agent_knowledge`, `agent_tools` tables. The `workspace_items`
    // table it references is the FULL version — see
    // agent_knowledge_delete.zig for why we re-create it here.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );

    try Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up(&db, testing.allocator);
    // Production DBs run every migration in order — the harness must
    // mirror that, or the agent_system_prompt table (Migration 080) is
    // missing.
    try Migration080AddAgentSystemPrompt.up(&db, testing.allocator);

    // Seed: 1 workspace_item of type 'agent' + matching agents row +
    // 1 system-prompt row, so the happy-path test has something to delete.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content, position) VALUES ('asp_1', 'ws_item_1', 'Persona', 'You are X', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn countPrompts(
    db: *sqlite.SqliteBackend,
    allocator: std.mem.Allocator,
    agent_id: []const u8,
) !u32 {
    var q = try db.query(allocator,
        "SELECT COUNT(*) FROM agent_system_prompt WHERE agent_id = ?",
        &[_][]const u8{agent_id},
    );
    defer q.deinit();
    const row = (q.next() catch null) orelse return 0;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

test "useCase: empty agent_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "", .prompt_id = "asp_1" }),
    );
}

test "useCase: empty prompt_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .prompt_id = "" }),
    );
}

test "useCase: matches scoped by both id AND agent_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: 1 row before
    try testing.expectEqual(@as(u32, 1), try countPrompts(&ctx.db, alloc, "ws_item_1"));

    try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .prompt_id = "asp_1" });

    // After: 0 rows
    try testing.expectEqual(@as(u32, 0), try countPrompts(&ctx.db, alloc, "ws_item_1"));
}

test "useCase: non-matching prompt_id is a no-op (no error)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectEqual(@as(u32, 1), try countPrompts(&ctx.db, alloc, "ws_item_1"));

    // prompt_id that doesn't exist — DELETE just affects 0 rows,
    // and `exec` returns success. No error.
    try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .prompt_id = "asp_404" });

    try testing.expectEqual(@as(u32, 1), try countPrompts(&ctx.db, alloc, "ws_item_1"));
}
