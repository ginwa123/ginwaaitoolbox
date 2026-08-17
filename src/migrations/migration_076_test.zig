//! Behavioural regression checks for Migration 076
//! (`agents` + `agent_knowledge` + `agent_tools` tables — Agent Mode feature).
//!
//! Why this file exists
//! ────────────────────
//! Migration 076 backs the Agent Mode workspace-item type. It creates 3
//! tables + 5 indexes:
//!   - `agents` — 1-1 with `workspace_items`, UNIQUE workspace_item_id,
//!     description default '', ON DELETE CASCADE from workspace_items
//!   - `agent_knowledge` — N-1 with agents, file_path NOT NULL,
//!     label default '', position default 0, ON DELETE CASCADE from agents
//!   - `agent_tools` — N-1 with agents, tool_name NOT NULL,
//!     enabled default 1, UNIQUE (agent_id, tool_name),
//!     ON DELETE CASCADE from agents
//!
//! Secure-by-default: an empty `agent_tools` allowlist means zero tools
//! for the agent (per user call: "No tools allowed, if not set").
//!
//! Plan: docs/superpowers/plans/2026-08-15-agent-mode.md
//! Spec: docs/superpowers/specs/2026-08-15-agent-mode-design.md
//! Task: task_1786962724740_0

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration076 = @import("migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;

/// Top-level named struct (NOT inline anonymous) per project memory
/// `zig-anonymous-struct-type-identity.md` — Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

/// Helper: run the migration, then return the list of column names for a
/// given table (ordered by `cid`, the original CREATE order).
fn columnsOf(ctx: *TestCtx, table: []const u8) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info(?) ORDER BY cid",
        &[_][]const u8{table},
    );
    defer q.deinit();
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |c| alloc.free(c);
        list.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try list.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    // Transfer ownership of the slice (and each element) to the caller.
    // Caller MUST `free` the slice header AND each element. We use
    // `toOwnedSlice` so the ArrayList's buffer is detached and the
    // returned slice header survives past function return.
    return try list.toOwnedSlice(alloc);
}

/// Helper: assert `list` contains exactly `expected` (in order). Uses comptime
/// `expected` so the comparison can be inlined.
fn expectColumnsEqual(list: []const []const u8, comptime expected: anytype) !void {
    const expected_len: usize = expected.len;
    try testing.expectEqual(expected_len, list.len);
    var i: usize = 0;
    while (i < expected_len) : (i += 1) {
        try testing.expectEqualStrings(expected[i], list[i]);
    }
}

test "Migration076 creates agents table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, the agents table doesn't exist.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agents'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have agents
        }
    }

    try Migration076.up(&ctx.db, alloc);

    // Post-migration: table exists in sqlite_master.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agents'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.AgentsTableNotCreated;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("agents", row.values[0]);
    }

    // Columns must be exactly: id, workspace_item_id, description, created_at, updated_at.
    const cols = try columnsOf(&ctx, "agents");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    const expected = [_][]const u8{ "id", "workspace_item_id", "description", "created_at", "updated_at" };
    try expectColumnsEqual(cols, &expected);
}

test "Migration076 creates agent_knowledge table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration076.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_knowledge");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Spec columns: id, agent_id, file_path, label, position, created_at, updated_at.
    const expected = [_][]const u8{
        "id", "agent_id", "file_path", "label", "position", "created_at", "updated_at",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration076 creates agent_tools table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration076.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_tools");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Spec columns: id, agent_id, tool_name, enabled, created_at.
    const expected = [_][]const u8{
        "id", "agent_id", "tool_name", "enabled", "created_at",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration076 agents.workspace_item_id is UNIQUE" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration076.up(&ctx.db, alloc);

    // Probe sqlite_master for a UNIQUE index on the agents.workspace_item_id column.
    // The standard SQLite convention is that UNIQUE constraints create
    // auto-named indexes "sqlite_autoindex_<table>_<n>"; query sqlite_master.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='agents'",
        &.{});
    defer q.deinit();
    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        // The UNIQUE constraint produces an auto-index; the existence of
        // ANY index on agents in addition to idx_agents_workspace_item_id
        // is our proxy. We'll do a tighter check via INSERT below.
        // Just record that an index exists.
        found = true;
    }
    try testing.expect(found); // at least one index exists

    // Tighter check: INSERT two rows with the same workspace_item_id. The
    // second must fail with a UNIQUE violation. We need a parent
    // workspace_items row first (FK).
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Test Agent', '/tmp/agent', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});

    // Duplicate INSERT must fail. Catch the SqliteError.
    const result = ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_2', 'ws_item_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration076 agent_tools(agent_id, tool_name) is UNIQUE" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration076.up(&ctx.db, alloc);

    // Verify the named UNIQUE index exists.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='uq_agent_tools_agent_tool'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.UniqueIndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("uq_agent_tools_agent_tool", row.values[0]);

    // Tighter check: insert parent rows, then duplicate tool_name → expect UNIQUE violation.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Test Agent', '/tmp/agent', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    const result = ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_2', 'agent_1', 'bash')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration076 ON DELETE CASCADE: agents dropped when workspace_items row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Enable FK enforcement (off by default in SQLite, on for this test).
    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try Migration076.up(&ctx.db, alloc);

    // Create the parent workspace_items row + agent + 1 knowledge + 1 tool.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('agent_1', 'ws_item_1', 'test')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_1', 'agent_1', '/tmp/x.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    // Sanity: all 4 rows exist.
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agents WHERE id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("1", r.values[0]);
    }

    // Delete the parent workspace_items row. CASCADE should drop agents.
    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'ws_item_1'", &.{});

    // The agent row should be gone (FK CASCADE from agents.workspace_item_id).
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agents WHERE id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

test "Migration076 ON DELETE CASCADE: knowledge + tools dropped when agent row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try Migration076.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_1', 'agent_1', '/tmp/x.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_2', 'agent_1', '/tmp/y.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    // Delete the agent row directly.
    try ctx.db.exec(alloc, "DELETE FROM agents WHERE id = 'agent_1'", &.{});

    // Both knowledge rows + tool row should be CASCADE-deleted.
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_knowledge WHERE agent_id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_tools WHERE agent_id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

test "Migration076 creates agent_knowledge.position + agent_id composite index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration076.up(&ctx.db, alloc);

    // The named index from the spec: idx_agent_knowledge_agent_id_position.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_agent_knowledge_agent_id_position'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.PositionIndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_agent_knowledge_agent_id_position", row.values[0]);
}

test "Migration076 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration076.up(&ctx.db, alloc);
    try Migration076.up(&ctx.db, alloc); // second run must not crash

    // Each of the 3 tables should still exist exactly once.
    for ([_][]const u8{ "agents", "agent_knowledge", "agent_tools" }) |table| {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            &[_][]const u8{table},
        );
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}

test "Migration076 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined but
    // the registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration076.version) return;
    }
    return error.Migration076NotRegistered;
}