//! `GET /api/workspaces/:workspace_id/items/:item_id/agent`.
//!
//! Returns `{agent, knowledge, tools}` for the agent bound to this
//! workspace_item. The frontend's AgentView consumes this payload to
//! populate both the Knowledge panel and the Tools panel in one
//! round-trip.
//!
//! - `agent` — the `agents` row (description, timestamps)
//! - `knowledge` — array of `AgentKnowledgeRow` ordered by position DESC
//! - `tools` — array of `string` (tool_names) ordered by tool_name ASC,
//!             filtered to `enabled = 1` only
//!
//! Returns 400 when the workspace_item's `item_type` is not `'agent'`,
//! 404 when the workspace_item doesn't exist.
//!
//! Layered as:
//!   - `useCase` — orchestrates the 3 reads (agent, knowledge, tools)
//!     + validates the workspace_item is an agent. Returns a typed
//!     `AgentGetOutput` with all owned slices.
//!   - `agentsGetHandler` — thin orchestrator over `useCase`:
//!     resolves the singleton DB handle, delegates, marshals the
//!     output to JSON, maps errors to status codes.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so the handler does NOT free anything. Tests using
//! `testing.allocator` MUST free the slices themselves (see the
//! test block below).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// Wire shape for a knowledge row in the GET response.
pub const AgentKnowledgeRow = struct {
    id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    /// Inline manual text ('' = file-backed row).
    content: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Wire shape for a system-prompt row in the GET response (Migration 080).
pub const AgentSystemPromptRow = struct {
    id: []const u8,
    agent_id: []const u8,
    title: []const u8,
    content: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Wire shape for the agent row in the GET response.
pub const AgentRow = struct {
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
pub const AgentGetError = error{
    /// `workspace_id` or `item_id` path param was missing or empty.
    IdsRequired,
    /// The workspace_item row did not exist.
    ItemNotFound,
    /// The workspace_item exists but its `item_type` is not `'agent'`.
    ItemNotAgent,
    /// A `db.query` failed.
    DatabaseError,
    /// `allocator.dupe` failed while copying slice fields. Unreachable
    /// under arena allocator but the type system requires the
    /// variant so `try` propagates.
    OutOfMemory,
};

/// Inputs to the agent-get use-case.
pub const AgentGetInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
};

/// Output of the agent-get use-case. All slices are owned by the
/// caller (lifetime = request arena in production).
pub const AgentGetOutput = struct {
    agent: AgentRow,
    knowledge: []const AgentKnowledgeRow,
    tools: []const []const u8,
    /// Per-agent named system-prompt blocks (Migration 080), ordered
    /// position DESC — same ordering convention as knowledge.
    system_prompts: []const AgentSystemPromptRow,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the agent row + knowledge + tools for a workspace_item.
/// Validates the workspace_item exists + is of type `'agent'`, then
/// loads the 3 sub-collections. The use-case is transport-agnostic:
/// it works for both the per-request arena (production HTTP handler)
/// and `testing.allocator` (unit tests below) — all allocations go
/// through the passed-in allocator.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: AgentGetInput,
) AgentGetError!AgentGetOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    // Validate item exists + is an agent.
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.DatabaseError;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "agent")) return error.ItemNotAgent;

    // Load agent row.
    const agent = loadAgentRow(allocator, db, input.item_id) catch return error.DatabaseError;

    // Load knowledge rows.
    var knowledge = std.ArrayList(AgentKnowledgeRow).empty;
    errdefer {
        for (knowledge.items) |k| freeKnowledgeRow(allocator, k);
        knowledge.deinit(allocator);
    }
    {
        var qk = db.query(allocator,
            \\SELECT id, agent_id, file_path, label, content, position,
            \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
            \\FROM agent_knowledge WHERE agent_id = ?
            \\ORDER BY position DESC
        , &[_][]const u8{input.item_id}) catch return error.DatabaseError;
        defer qk.deinit();
        while ((qk.next() catch null)) |r| {
            defer r.deinit(allocator);
            const position = std.fmt.parseInt(i64, r.values[5], 10) catch 0;
            try knowledge.append(allocator, .{
                .id = try allocator.dupe(u8, r.values[0]),
                .agent_id = try allocator.dupe(u8, r.values[1]),
                .file_path = try allocator.dupe(u8, r.values[2]),
                .label = try allocator.dupe(u8, r.values[3]),
                .content = try allocator.dupe(u8, r.values[4]),
                .position = position,
                .created_at = try allocator.dupe(u8, r.values[6]),
                .updated_at = try allocator.dupe(u8, r.values[7]),
            });
        }
    }
    const knowledge_owned = try knowledge.toOwnedSlice(allocator);

    // Load enabled tool names.
    var tools = std.ArrayList([]u8).empty;
    errdefer {
        for (tools.items) |n| allocator.free(n);
        tools.deinit(allocator);
    }
    {
        var qt = db.query(allocator,
            "SELECT tool_name FROM agent_tools WHERE agent_id = ? AND enabled = 1 ORDER BY tool_name ASC",
            &[_][]const u8{input.item_id}) catch return error.DatabaseError;
        defer qt.deinit();
        while ((qt.next() catch null)) |r| {
            defer r.deinit(allocator);
            try tools.append(allocator, try allocator.dupe(u8, r.values[0]));
        }
    }
    const tools_owned = try tools.toOwnedSlice(allocator);

    // Load system-prompt rows (Migration 080), position DESC.
    var system_prompts = std.ArrayList(AgentSystemPromptRow).empty;
    errdefer {
        for (system_prompts.items) |p| freeSystemPromptRow(allocator, p);
        system_prompts.deinit(allocator);
    }
    {
        var qp = db.query(allocator,
            \\SELECT id, agent_id, title, content, position,
            \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
            \\FROM agent_system_prompt WHERE agent_id = ?
            \\ORDER BY position DESC
        , &[_][]const u8{input.item_id}) catch return error.DatabaseError;
        defer qp.deinit();
        while ((qp.next() catch null)) |r| {
            defer r.deinit(allocator);
            const position = std.fmt.parseInt(i64, r.values[4], 10) catch 0;
            try system_prompts.append(allocator, .{
                .id = try allocator.dupe(u8, r.values[0]),
                .agent_id = try allocator.dupe(u8, r.values[1]),
                .title = try allocator.dupe(u8, r.values[2]),
                .content = try allocator.dupe(u8, r.values[3]),
                .position = position,
                .created_at = try allocator.dupe(u8, r.values[5]),
                .updated_at = try allocator.dupe(u8, r.values[6]),
            });
        }
    }
    const system_prompts_owned = try system_prompts.toOwnedSlice(allocator);

    return .{
        .agent = agent,
        .knowledge = knowledge_owned,
        .tools = tools_owned,
        .system_prompts = system_prompts_owned,
    };
}

/// Load the agents row (description + timestamps) — all slices
/// dup'd into the returned `AgentRow` so the caller doesn't have to
/// worry about the source row.
fn loadAgentRow(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    agent_id: []const u8,
) AgentGetError!AgentRow {
    var q = db.query(allocator,
        "SELECT id, workspace_item_id, description, IFNULL(created_at, ''), IFNULL(updated_at, '') FROM agents WHERE id = ?",
        &[_][]const u8{agent_id},
    ) catch return error.DatabaseError;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .description = try allocator.dupe(u8, row.values[2]),
        .created_at = try allocator.dupe(u8, row.values[3]),
        .updated_at = try allocator.dupe(u8, row.values[4]),
    };
}

/// Free every slice field on a single knowledge row.
fn freeKnowledgeRow(allocator: std.mem.Allocator, k: AgentKnowledgeRow) void {
    allocator.free(k.id);
    allocator.free(k.agent_id);
    allocator.free(k.file_path);
    if (k.label.len > 0) allocator.free(k.label);
    if (k.content.len > 0) allocator.free(k.content);
    if (k.created_at.len > 0) allocator.free(k.created_at);
    if (k.updated_at.len > 0) allocator.free(k.updated_at);
}

/// Free every slice field on a single system-prompt row.
fn freeSystemPromptRow(allocator: std.mem.Allocator, p: AgentSystemPromptRow) void {
    allocator.free(p.id);
    allocator.free(p.agent_id);
    if (p.title.len > 0) allocator.free(p.title);
    if (p.content.len > 0) allocator.free(p.content);
    if (p.created_at.len > 0) allocator.free(p.created_at);
    if (p.updated_at.len > 0) allocator.free(p.updated_at);
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Resolves the singleton DB
/// handle, delegates to `useCase`, and maps the use-case outcome
/// to an HTTP response.
pub fn agentsGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.ItemNotFound => 404,
            error.ItemNotAgent => 400,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.ItemNotFound => "workspace_item not found",
            error.ItemNotAgent => "workspace_item is not an agent",
            error.DatabaseError => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .agent = output.agent,
        .knowledge = output.knowledge,
        .tools = output.tools,
        .system_prompts = output.system_prompts,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention for Agent Mode).
// 4 behavioural tests cover the use-case:
//
//   1. Validation: empty workspace_id OR item_id → IdsRequired
//   2. ItemNotFound: workspace_item doesn't exist
//   3. ItemNotAgent: workspace_item exists but item_type != 'agent'
//   4. Happy path: returns agent + knowledge + tools

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../../../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;
const Migration079AddContentToAgentKnowledge = @import("../../../migrations/migration.zig").Migration079AddContentToAgentKnowledge;
const Migration080AddAgentSystemPrompt = @import("../../../migrations/migration.zig").Migration080AddAgentSystemPrompt;

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
    // workspace_items with the full shape.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up(&db, testing.allocator);
    // Production DBs run every migration in order — the harness must
    // mirror that, or the `content` column (Migration 079) is missing.
    try Migration079AddContentToAgentKnowledge.up(&db, testing.allocator);
    // Same for the agent_system_prompt table (Migration 080).
    try Migration080AddAgentSystemPrompt.up(&db, testing.allocator);

    // Seed: 1 agent + 2 knowledge rows + 2 enabled tools + 1 disabled tool.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', 'desc')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('know_1', 'ws_item_1', '/tmp/a.md', 'A', 0)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('know_2', 'ws_item_1', '/tmp/b.md', '', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_1', 'ws_item_1', 'bash', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_2', 'ws_item_1', 'read_file', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_3', 'ws_item_1', 'write_file', 0)",
        &[_][]const u8{},
    );

    // Add a kanban-type workspace_item to verify the ItemNotAgent path.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_kanban', 'ws_1', 'kanban', 'A kanban')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

/// Free everything the use-case allocated for the output.
fn freeOutput(allocator: std.mem.Allocator, output: AgentGetOutput) void {
    allocator.free(output.agent.id);
    allocator.free(output.agent.workspace_item_id);
    allocator.free(output.agent.description);
    allocator.free(output.agent.created_at);
    allocator.free(output.agent.updated_at);
    for (output.knowledge) |k| freeKnowledgeRow(allocator, k);
    allocator.free(output.knowledge);
    for (output.tools) |n| allocator.free(n);
    allocator.free(output.tools);
    for (output.system_prompts) |p| freeSystemPromptRow(allocator, p);
    allocator.free(output.system_prompts);
}

test "useCase: empty workspace_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .item_id = "ws_item_1" }),
    );
}

test "useCase: empty item_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "" }),
    );
}

test "useCase: non-existent workspace_item returns ItemNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_404" }),
    );
}

test "useCase: workspace_item of type kanban returns ItemNotAgent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotAgent,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_kanban" }),
    );
}

test "useCase: happy path returns agent + knowledge DESC + tools enabled ASC" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    // Agent.
    try testing.expectEqualStrings("ws_item_1", output.agent.id);
    try testing.expectEqualStrings("desc", output.agent.description);

    // Knowledge: 2 rows, position DESC. know_2 (position 1) first, know_1 (position 0) second.
    try testing.expectEqual(@as(usize, 2), output.knowledge.len);
    try testing.expectEqualStrings("know_2", output.knowledge[0].id);
    try testing.expectEqualStrings("know_1", output.knowledge[1].id);

    // Tools: 2 enabled, alphabetical. write_file excluded (enabled=0).
    try testing.expectEqual(@as(usize, 2), output.tools.len);
    try testing.expectEqualStrings("bash", output.tools[0]);
    try testing.expectEqualStrings("read_file", output.tools[1]);
}

test "useCase: returns content field for knowledge rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed one inline-content row (position 5 → sorts first under DESC).
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, content, position) VALUES ('know_inline', 'ws_item_1', '', 'Notes', 'inline body', 5)",
        &[_][]const u8{},
    );

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    try testing.expectEqual(@as(usize, 3), output.knowledge.len);
    // know_inline first (position 5 DESC), then know_2 (1), then know_1 (0).
    try testing.expectEqualStrings("know_inline", output.knowledge[0].id);
    try testing.expectEqualStrings("inline body", output.knowledge[0].content);
    // File-backed rows round-trip with empty content.
    try testing.expectEqualStrings("", output.knowledge[1].content);
    try testing.expectEqualStrings("", output.knowledge[2].content);
}

test "useCase: returns system_prompts ordered position DESC (Migration 080)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed two prompt rows: sp_low at position 0, sp_high at position 3.
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content, position) VALUES ('sp_low', 'ws_item_1', 'Low', 'low body', 0)",
        &[_][]const u8{},
    );
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content, position) VALUES ('sp_high', 'ws_item_1', 'High', 'high body', 3)",
        &[_][]const u8{},
    );

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    try testing.expectEqual(@as(usize, 2), output.system_prompts.len);
    // position DESC: sp_high (3) first, sp_low (0) second.
    try testing.expectEqualStrings("sp_high", output.system_prompts[0].id);
    try testing.expectEqualStrings("high body", output.system_prompts[0].content);
    try testing.expectEqualStrings("sp_low", output.system_prompts[1].id);
}