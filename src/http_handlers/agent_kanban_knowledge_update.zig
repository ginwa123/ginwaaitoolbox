//! `PATCH /api/agent-kanbans/:kanban_id/knowledge/:knowledge_id`.
//!
//! Updates file_path / label / content of an existing knowledge entry.
//! Body: `{file_path?, label?, content?}` (all optional; at least one
//! required). Empty-string semantics mirror agent_knowledge_update.zig:
//! `file_path = ""` clears the path (mode switch to text-backed);
//! `content = ""` clears the text (mode switch to file-backed).
//!
//! Mirrors `agent_knowledge_update.zig` with substitutions:
//! table `agent_kanban_knowledges`, parent col `kanban_id`.
//!
//! Memory: the per-request arena reaps all allocations at request end,
//! so neither layer needs explicit `free`s.
//!
//! Plan: docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
//! Task: task_1787597624259_2

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");

/// HTTP request body.
const UpdateKnowledgeBody = struct {
    file_path: ?[]const u8 = null,
    label: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = struct {
    id: []const u8,
    kanban_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    /// Inline manual text ('' = file-backed row).
    content: []const u8,
    position: i64,
};

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const KnowledgeUpdateError = error{
    /// `kanban_id` or `knowledge_id` path param was missing or empty.
    IdsRequired,
    /// Body had none of file_path / label / content (nothing to update).
    NothingToUpdate,
    /// `file_path` provided but not absolute (empty string is legal —
    /// it means "clear the column").
    NotAbsolutePath,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed.
    RefetchFailed,
    /// Refetched row vanished (surfaces as 404).
    RowNotFound,
    /// `allocator.alloc` failed while building the dynamic SQL.
    OutOfMemory,
};

/// Inputs to the knowledge-update use-case.
pub const KnowledgeUpdateInput = struct {
    kanban_id: []const u8,
    knowledge_id: []const u8,
    file_path: ?[]const u8,
    label: ?[]const u8,
    content: ?[]const u8 = null,
};

/// Output of the knowledge-update use-case.
pub const KnowledgeUpdateOutput = struct {
    knowledge: Knowledge,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing knowledge row. Validates that at least one of
/// `file_path` / `label` / `content` is provided, that any provided
/// NON-EMPTY `file_path` is absolute, then UPDATE-with-dynamic-SQL the
/// requested fields and SELECT-refetch the row. Transport-agnostic.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: KnowledgeUpdateInput,
) KnowledgeUpdateError!KnowledgeUpdateOutput {
    if (input.kanban_id.len == 0 or input.knowledge_id.len == 0) {
        return error.IdsRequired;
    }
    if (input.file_path == null and input.label == null and input.content == null) {
        return error.NothingToUpdate;
    }
    if (input.file_path) |fp| {
        // Empty string = clear the column (mode switch). Only NON-empty
        // paths must be absolute.
        if (fp.len > 0 and !std.fs.path.isAbsolute(fp)) return error.NotAbsolutePath;
    }

    // Build dynamic UPDATE SQL. file_path/content use COALESCE(?, '') so
    // an empty-slice bind lands as '' not NULL (NOT NULL columns).
    var sql_list: std.ArrayList(u8) = .empty;
    defer sql_list.deinit(allocator);
    try sql_list.appendSlice(allocator, "UPDATE agent_kanban_knowledges SET updated_at = datetime('now')");
    if (input.file_path != null) try sql_list.appendSlice(allocator, ", file_path = COALESCE(?, '')");
    if (input.label != null) try sql_list.appendSlice(allocator, ", label = ?");
    if (input.content != null) try sql_list.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql_list.appendSlice(allocator, " WHERE id = ? AND kanban_id = ?");

    // Bind args. Max 5 slots: file_path, label, content, knowledge_id, kanban_id.
    var args_buf: [5][]const u8 = undefined;
    var arg_idx: usize = 0;
    if (input.file_path) |fp| {
        args_buf[arg_idx] = fp;
        arg_idx += 1;
    }
    if (input.label) |lb| {
        args_buf[arg_idx] = lb;
        arg_idx += 1;
    }
    if (input.content) |ct| {
        args_buf[arg_idx] = ct;
        arg_idx += 1;
    }
    args_buf[arg_idx] = input.knowledge_id;
    arg_idx += 1;
    args_buf[arg_idx] = input.kanban_id;
    arg_idx += 1;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    for (args_buf[0..arg_idx]) |a| try argv_list.append(allocator, a);

    db.exec(allocator, sql_list.items, argv_list.items) catch return error.UpdateFailed;

    // Read back.
    var q = db.query(allocator,
        "SELECT id, kanban_id, file_path, label, content, position FROM agent_kanban_knowledges WHERE id = ?",
        &[_][]const u8{input.knowledge_id},
    ) catch return error.RefetchFailed;
    defer q.deinit();
    const r = (q.next() catch null) orelse return error.RowNotFound;
    defer r.deinit(allocator); // safe — we dupe the slices below
    const position = std.fmt.parseInt(i64, r.values[5], 10) catch 0;

    const id = try allocator.dupe(u8, r.values[0]);
    errdefer allocator.free(id);
    const kanban_id = try allocator.dupe(u8, r.values[1]);
    errdefer allocator.free(kanban_id);
    const file_path = try allocator.dupe(u8, r.values[2]);
    errdefer allocator.free(file_path);
    const label = try allocator.dupe(u8, r.values[3]);
    errdefer allocator.free(label);
    const content = try allocator.dupe(u8, r.values[4]);
    errdefer allocator.free(content);

    return .{
        .knowledge = .{
            .id = id,
            .kanban_id = kanban_id,
            .file_path = file_path,
            .label = label,
            .content = content,
            .position = position,
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentKanbanKnowledgeUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const kanban_id = req.params.get("kanban_id") orelse "";
    const knowledge_id = req.params.get("knowledge_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(UpdateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .kanban_id = kanban_id,
        .knowledge_id = knowledge_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NothingToUpdate => 400,
            error.NotAbsolutePath => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowNotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "kanban_id and knowledge_id required",
            error.NothingToUpdate => "file_path or label required",
            error.NotAbsolutePath => "file_path must be absolute",
            error.UpdateFailed => "Failed to update knowledge",
            error.RefetchFailed => "Failed to read row",
            error.RowNotFound => "knowledge row not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.knowledge, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// impl + tests in one file (project convention). Behavioural coverage:
//
//   1. Validation: empty ids OR nothing-to-update → respective errors
//   2. Happy path: updates file_path AND label
//   3. Mode-switch: file_path='' + content set (file→text)
//   4. Mode-switch: content='' + file_path set (text→file)

const sqlite = @import("pabrikcore").sqlite;
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

    // Seed: configured kanban + 1 knowledge row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'kanban', 'My Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ws_item_1', 'ws_item_1')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_kanban_knowledges (id, kanban_id, file_path, label, position) VALUES ('kn_1', 'ws_item_1', '/tmp/orig.md', 'Original', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty kanban_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "", .knowledge_id = "kn_1", .file_path = "/tmp/new.md", .label = null }),
    );
}

test "useCase: nothing to update returns NothingToUpdate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NothingToUpdate,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .knowledge_id = "kn_1", .file_path = null, .label = null }),
    );
}

test "useCase: relative non-empty file_path returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .knowledge_id = "kn_1", .file_path = "relative/path.md", .label = null }),
    );
}

test "useCase: happy path updates both file_path AND label" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .knowledge_id = "kn_1",
        .file_path = "/tmp/new.md",
        .label = "New label",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.kanban_id);
        alloc.free(output.knowledge.file_path);
        alloc.free(output.knowledge.label);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
    }
    try testing.expectEqualStrings("kn_1", output.knowledge.id);
    try testing.expectEqualStrings("/tmp/new.md", output.knowledge.file_path);
    try testing.expectEqualStrings("New label", output.knowledge.label);
}

test "useCase: file_path='' clears path and sets content (file→text switch)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .knowledge_id = "kn_1",
        .file_path = "",
        .label = "Switched",
        .content = "inline body after switch",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.kanban_id);
        alloc.free(output.knowledge.label);
        if (output.knowledge.file_path.len > 0) alloc.free(output.knowledge.file_path);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
    }
    try testing.expectEqualStrings("", output.knowledge.file_path);
    try testing.expectEqualStrings("inline body after switch", output.knowledge.content);
    try testing.expectEqualStrings("Switched", output.knowledge.label);
}

test "useCase: content='' clears text and sets path (text→file switch)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .knowledge_id = "kn_1",
        .file_path = "/tmp/switched.md",
        .label = "Switched to file",
        .content = "",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.kanban_id);
        alloc.free(output.knowledge.label);
        alloc.free(output.knowledge.file_path);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
    }
    try testing.expectEqualStrings("", output.knowledge.content);
    try testing.expectEqualStrings("/tmp/switched.md", output.knowledge.file_path);
}
