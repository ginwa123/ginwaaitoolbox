//! `PATCH /api/agents/:agent_id/knowledge/:knowledge_id`.
//!
//! Updates file_path and/or label of an existing knowledge entry.
//! Body: `{file_path?, label?}` (both optional; at least one required).
//! `file_path` MUST be absolute if provided.
//!
//! Layered as:
//!   - `useCase` — validate ids + body → build dynamic UPDATE SQL
//!     (Zig 0.16 dropped std.io.fixedBufferStream, so we use
//!     `ArrayList.appendSlice` for the static SQL fragments) →
//!     UPDATE → SELECT refetch → return typed Knowledge.
//!   - `agentKnowledgeUpdateHandler` — thin orchestrator over
//!     `useCase`: parses path/body, delegates, maps outcome to HTTP.
//!
//! Memory: the per-request arena reaps all allocations at request
//! end, so neither layer needs explicit nor free.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// HTTP request body. Decoupled from the domain `KnowledgeUpdateInput`
/// so the wire format can evolve independently (e.g. adding `?`
/// optional fields) without touching the use-case.
const UpdateKnowledgeBody = struct {
    file_path: ?[]const u8 = null,
    label: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = struct {
    id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    /// Inline manual text ('' = file-backed row).
    content: []const u8,
    position: i64,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (intentional — adding a new variant fails to compile in
/// the handler until both switches are updated, keeping status
/// codes in lockstep with the error set).
pub const KnowledgeUpdateError = error{
    /// `agent_id` or `knowledge_id` path param was missing or empty.
    IdsRequired,
    /// Body had neither `file_path` nor `label` (nothing to update).
    NothingToUpdate,
    /// `file_path` provided but not absolute.
    NotAbsolutePath,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 404).
    RowNotFound,
    /// `allocator.alloc` failed while building the dynamic SQL.
    /// Unreachable under arena allocator but the type system requires
    /// the variant so `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the knowledge-update use-case.
pub const KnowledgeUpdateInput = struct {
    agent_id: []const u8,
    knowledge_id: []const u8,
    file_path: ?[]const u8,
    label: ?[]const u8,
    /// Inline manual text. Providing it switches the row to
    /// content-backed; null leaves the column untouched.
    content: ?[]const u8 = null,
};

/// Output of the knowledge-update use-case. `knowledge` is owned by
/// the caller (lifetime = request arena).
pub const KnowledgeUpdateOutput = struct {
    knowledge: Knowledge,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing knowledge row. Validates that at least one of
/// `file_path` / `label` / `content` is provided, that any provided
/// NON-EMPTY `file_path` is absolute (empty string = clear the column,
/// i.e. switch the row to content-backed), then UPDATE-with-dynamic-SQL
/// the requested fields and SELECT-refetch the row. The use-case is
/// transport-agnostic: it works for both the per-request arena
/// (production HTTP handler) and `testing.allocator` (unit tests
/// below) — all allocations go through the passed-in allocator.
///
/// Empty-string semantics (2026-08-22 fix, PR #291 follow-up):
///   - `file_path = ""` → clears the path (row becomes inline-text).
///     NOT a NotAbsolutePath error — the edit dialog's mode switch
///     sends `{file_path: "", content: "..."}` atomically.
///   - `content = ""`  → clears the text (row becomes file-backed).
///     Bound via COALESCE(?, '') because SqliteBackend.exec binds
///     empty slices as SQL NULL, which violates NOT NULL.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: KnowledgeUpdateInput,
) KnowledgeUpdateError!KnowledgeUpdateOutput {
    if (input.agent_id.len == 0 or input.knowledge_id.len == 0) {
        return error.IdsRequired;
    }
    if (input.file_path == null and input.label == null and input.content == null) {
        return error.NothingToUpdate;
    }
    if (input.file_path) |fp| {
        // Empty string = clear the column (mode switch to text-backed).
        // Only NON-empty paths must be absolute.
        if (fp.len > 0 and !std.fs.path.isAbsolute(fp)) return error.NotAbsolutePath;
    }

    // Build dynamic UPDATE SQL. Zig 0.16 dropped
    // std.io.fixedBufferStream, so we use ArrayList.appendSlice for
    // the static fragments. file_path/content use COALESCE(?, '') so
    // an empty-slice bind lands as '' not NULL (NOT NULL columns).
    var sql_list: std.ArrayList(u8) = .empty;
    defer sql_list.deinit(allocator);
    try sql_list.appendSlice(allocator, "UPDATE agent_knowledge SET updated_at = datetime('now')");
    if (input.file_path != null) try sql_list.appendSlice(allocator, ", file_path = COALESCE(?, '')");
    if (input.label != null) try sql_list.appendSlice(allocator, ", label = ?");
    if (input.content != null) try sql_list.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql_list.appendSlice(allocator, " WHERE id = ? AND agent_id = ?");

    // Bind args. Max 5 slots: file_path, label, content, knowledge_id, agent_id.
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
    args_buf[arg_idx] = input.agent_id;
    arg_idx += 1;

    // Build argv slice for db.exec — pass an owned slice.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    for (args_buf[0..arg_idx]) |a| try argv_list.append(allocator, a);

    db.exec(allocator, sql_list.items, argv_list.items) catch return error.UpdateFailed;

    // Read back.
    var q = db.query(allocator,
        "SELECT id, agent_id, file_path, label, content, position FROM agent_knowledge WHERE id = ?",
        &[_][]const u8{input.knowledge_id},
    ) catch return error.RefetchFailed;
    defer q.deinit();
    const r = (q.next() catch null) orelse return error.RowNotFound;
    defer r.deinit(allocator); // safe — we dupe the slices below
    const position = std.fmt.parseInt(i64, r.values[5], 10) catch 0;

    // Dupe the slices out of row.values[] so the Knowledge struct
    // owns them. Production: arena allocator reaps these at request
    // end. Tests: caller frees explicitly.
    const id = try allocator.dupe(u8, r.values[0]);
    errdefer allocator.free(id);
    const agent_id = try allocator.dupe(u8, r.values[1]);
    errdefer allocator.free(agent_id);
    const file_path = try allocator.dupe(u8, r.values[2]);
    errdefer allocator.free(file_path);
    const label = try allocator.dupe(u8, r.values[3]);
    errdefer allocator.free(label);
    const content = try allocator.dupe(u8, r.values[4]);
    errdefer allocator.free(content);

    return .{
        .knowledge = .{
            .id = id,
            .agent_id = agent_id,
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

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentKnowledgeUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const knowledge_id = req.params.get("knowledge_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(UpdateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
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
            error.IdsRequired => "agent_id and knowledge_id required",
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
// impl + tests in one file (project convention for Agent Mode).
// 5 behavioural tests cover the use-case:
//
//   1. Validation: empty ids OR neither field → respective errors
//   2. NotAbsolutePath: relative file_path rejected
//   3. Happy path: updates file_path AND label
//   4. file_path only: updates just file_path
//   5. label only: updates just label

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;
const Migration079AddContentToAgentKnowledge = @import("../migrations/migration.zig").Migration079AddContentToAgentKnowledge;

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

    // Seed: 1 agent + 1 knowledge row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('know_1', 'ws_item_1', '/tmp/orig.md', 'Original', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty agent_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "",
            .knowledge_id = "know_1",
            .file_path = "/tmp/new.md",
            .label = null,
        }),
    );
}

test "useCase: empty knowledge_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "",
            .file_path = "/tmp/new.md",
            .label = null,
        }),
    );
}

test "useCase: neither file_path nor label returns NothingToUpdate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NothingToUpdate,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "know_1",
            .file_path = null,
            .label = null,
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
            .knowledge_id = "know_1",
            .file_path = "relative/path.md",
            .label = null,
        }),
    );
}

test "useCase: happy path updates both file_path AND label" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = "/tmp/new.md",
        .label = "New label",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.agent_id);
        alloc.free(output.knowledge.file_path);
        alloc.free(output.knowledge.label);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
    }
    try testing.expectEqualStrings("know_1", output.knowledge.id);
    try testing.expectEqualStrings("/tmp/new.md", output.knowledge.file_path);
    try testing.expectEqualStrings("New label", output.knowledge.label);
}

test "useCase: label-only update keeps file_path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = null,
        .label = "Updated label only",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.agent_id);
        alloc.free(output.knowledge.file_path);
        alloc.free(output.knowledge.label);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
    }
    try testing.expectEqualStrings("/tmp/orig.md", output.knowledge.file_path);
    try testing.expectEqualStrings("Updated label only", output.knowledge.label);
}

// ─── content (manual text) tests — plan 2026-08-21-agent-knowledge-manual-text ──

test "useCase: PATCH can set content on an existing row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = null,
        .label = null,
        .content = "new inline text",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.agent_id);
        alloc.free(output.knowledge.file_path);
        alloc.free(output.knowledge.label);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
    }
    // Content is set; file_path unchanged (row keeps its old path).
    try testing.expectEqualStrings("new inline text", output.knowledge.content);
    try testing.expectEqualStrings("/tmp/orig.md", output.knowledge.file_path);
}

// ─── Mode-switch tests (2026-08-22, PR #291 follow-up) ─────────────────
//
// The edit dialog's File↔Text mode switch sends BOTH source fields in
// one PATCH — the inactive one as "". These tests lock in the
// empty-string semantics: "" = clear this column (not an error).

test "useCase: file_path='' clears path and sets content (file→text switch)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        // Exactly what the edit dialog sends for a text-mode save.
        .file_path = "",
        .label = "Switched",
        .content = "inline body after switch",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.agent_id);
        alloc.free(output.knowledge.label);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
        if (output.knowledge.file_path.len > 0) alloc.free(output.knowledge.file_path);
    }
    // Regression: this used to 400 with "file_path must be absolute"
    // because isAbsolute("") is false.
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
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        // Exactly what the edit dialog sends for a file-mode save.
        .file_path = "/tmp/switched.md",
        .label = "Switched to file",
        .content = "",
    });
    defer {
        alloc.free(output.knowledge.id);
        alloc.free(output.knowledge.agent_id);
        alloc.free(output.knowledge.label);
        alloc.free(output.knowledge.file_path);
        if (output.knowledge.content.len > 0) alloc.free(output.knowledge.content);
    }
    // Regression: content="" used to 500 because SqliteBackend.exec
    // binds empty slices as SQL NULL → NOT NULL constraint fail.
    try testing.expectEqualStrings("", output.knowledge.content);
    try testing.expectEqualStrings("/tmp/switched.md", output.knowledge.file_path);
}

test "useCase: relative non-empty file_path still returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "know_1",
            .file_path = "relative/path.md",
            .label = null,
        }),
    );
}

// ===== Tests merged from agent_knowledge_update_functional_test.zig (2026-09-11 flatten) =====
// ISOLATED functional tests for the agent-knowledge UPDATE flow
// (PATCH /api/agents/:agent_id/knowledge/:knowledge_id).
// 
// WHY THIS FILE EXISTS (lesson from PR #291, 2026-08-22):
// The edit dialog's File↔Text mode switch sends BOTH source fields in
// one PATCH — the inactive one as `""`. The first implementation
// passed all unit tests but 400'd/500'd in real use because:
//   1. `std.fs.path.isAbsolute("")` is false → `file_path: ""` was
//      rejected as "not absolute" (400).
//   2. `SqliteBackend.exec` binds EMPTY slices as SQL NULL →
//      `content: ""` violated the NOT NULL constraint (500).
// Neither failure is visible to a mock-level test; both only appear
// when the REAL useCase runs against a REAL SQLite database with the
// EXACT wire payload the frontend sends.
// 
// LESSON (user directive): verify HTTP-body-shaped behaviour with
// isolated functional tests that replay the exact JSON body the
// client sends — do NOT spin up a live server for verification.
// These tests run the production `useCase` against an in-memory DB
// seeded via the real migrations (076 + 079), no sockets involved.
// 
// Coverage:
//   A. file→text switch: `{file_path:"", content:"..."}` → 200-shape,
//      row flips to content-backed.
//   B. text→file switch: `{file_path:"/abs", content:""}` → row flips
//      to file-backed, content cleared (NOT a NULL crash).
//   C. relative non-empty path still rejected (guard stays).
//   D. route-order contract: `/knowledge/reorder` must be registered
//      BEFORE `/knowledge/:knowledge_id` in main.zig, or the literal
//      route is shadowed and reorder PATCHes hit the update handler
//      with knowledge_id="reorder".

const update_mod = @This();

const TestCtx_merged = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb_merged() !TestCtx_merged {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the production schema exactly: workspace_items shape the
    // delete handler's harness established + migrations IN ORDER (076
    // then 079) — production runs every migration sequentially.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up(&db, testing.allocator);
    try Migration079AddContentToAgentKnowledge.up(&db, testing.allocator);

    // Seed: 1 agent + 1 FILE-BACKED knowledge row (the case the edit
    // dialog opens on by default).
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('know_1', 'ws_item_1', '/tmp/orig.md', 'Original', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn freeKnowledge(alloc: std.mem.Allocator, k: update_mod.Knowledge) void {
    alloc.free(k.id);
    alloc.free(k.agent_id);
    alloc.free(k.file_path);
    alloc.free(k.label);
    if (k.content.len > 0) alloc.free(k.content);
}

// ─── A. file→text switch (regression: used to 400 NotAbsolutePath) ──────

test "functional: file→text switch payload {file_path:'', content} succeeds end-to-end" {
    const alloc = testing.allocator;
    var ctx = try setupDb_merged();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // EXACT body the edit dialog sends for a Text-mode save on a
    // file-backed row (JSON round-trip so the wire shape is honest).
    const Body = struct {
        label: []const u8,
        content: []const u8,
        file_path: []const u8,
    };
    const body_json =
        \\{"label":"Switched","content":"inline body after switch","file_path":""}
    ;
    // parseFromSliceLeaky (arena-less) would leak under testing.allocator;
    // use the allocating variant and free its Parsed wrapper.
    var parsed = try std.json.parseFromSlice(Body, alloc, body_json, .{});
    defer parsed.deinit();

    const output = try update_mod.useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = parsed.value.file_path,
        .label = parsed.value.label,
        .content = parsed.value.content,
    });
    defer freeKnowledge(alloc, output.knowledge);

    // Row flipped to content-backed: path cleared, content set.
    try testing.expectEqualStrings("", output.knowledge.file_path);
    try testing.expectEqualStrings("inline body after switch", output.knowledge.content);
    try testing.expectEqualStrings("Switched", output.knowledge.label);

    // And the DB row itself is consistent (refetch independently).
    var q = try ctx.db.query(alloc,
        "SELECT file_path, content FROM agent_knowledge WHERE id = 'know_1'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("", r.values[0]);
    try testing.expectEqualStrings("inline body after switch", r.values[1]);
}

// ─── B. text→file switch (regression: used to 500 NOT NULL constraint) ──

test "functional: text→file switch payload {file_path, content:''} succeeds end-to-end" {
    const alloc = testing.allocator;
    var ctx = try setupDb_merged();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed as INLINE first so we're genuinely switching text→file.
    try ctx.db.exec(alloc,
        "UPDATE agent_knowledge SET file_path = '', content = 'original inline' WHERE id = 'know_1'",
        &[_][]const u8{},
    );

    const Body = struct {
        label: []const u8,
        file_path: []const u8,
        content: []const u8,
    };
    const body_json =
        \\{"label":"NowAFile","file_path":"/tmp/switched.md","content":""}
    ;
    var parsed = try std.json.parseFromSlice(Body, alloc, body_json, .{});
    defer parsed.deinit();

    const output = try update_mod.useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = parsed.value.file_path,
        .label = parsed.value.label,
        .content = parsed.value.content,
    });
    defer freeKnowledge(alloc, output.knowledge);

    // Row flipped to file-backed: content cleared to '' (NOT a crash),
    // path set.
    try testing.expectEqualStrings("/tmp/switched.md", output.knowledge.file_path);
    try testing.expectEqualStrings("", output.knowledge.content);

    // Independent refetch: content column must be '' not NULL.
    var q = try ctx.db.query(alloc,
        "SELECT file_path, content FROM agent_knowledge WHERE id = 'know_1'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("/tmp/switched.md", r.values[0]);
    try testing.expectEqualStrings("", r.values[1]);
}

// ─── C. guard stays: non-empty relative path still rejected ─────────────

test "functional: non-empty relative file_path still returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb_merged();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        update_mod.useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "know_1",
            .file_path = "rel/path.md",
            .label = null,
            .content = null,
        }),
    );
}

// ─── D. route-order contract: /reorder must precede /:knowledge_id ──────

test "functional: main.zig registers /knowledge/reorder BEFORE /knowledge/:knowledge_id" {
    const alloc = testing.allocator;
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/main.zig",
        alloc,
        .limited(1024 * 1024),
    );
    defer alloc.free(raw);

    const reorder_idx = std.mem.indexOf(u8, raw, "\"/api/agents/:agent_id/knowledge/reorder\"") orelse
        return error.ReorderRouteMissing;
    const param_idx = std.mem.indexOf(u8, raw, "\"/api/agents/:agent_id/knowledge/:knowledge_id\"") orelse
        return error.ParamRouteMissing;

    // The router matches routes in REGISTRATION order; the literal
    // `reorder` route MUST come first or every reorder PATCH is
    // captured by the :knowledge_id param route (knowledge_id="reorder").
    if (reorder_idx > param_idx) {
        std.debug.print(
            "\n!! main.zig registers /knowledge/:knowledge_id BEFORE /knowledge/reorder — reorder is shadowed !!\n",
            .{},
        );
        return error.ReorderRouteShadowed;
    }
}
