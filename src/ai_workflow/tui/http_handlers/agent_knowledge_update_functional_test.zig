//! ISOLATED functional tests for the agent-knowledge UPDATE flow
//! (PATCH /api/agents/:agent_id/knowledge/:knowledge_id).
//!
//! WHY THIS FILE EXISTS (lesson from PR #291, 2026-08-22):
//! The edit dialog's File↔Text mode switch sends BOTH source fields in
//! one PATCH — the inactive one as `""`. The first implementation
//! passed all unit tests but 400'd/500'd in real use because:
//!   1. `std.fs.path.isAbsolute("")` is false → `file_path: ""` was
//!      rejected as "not absolute" (400).
//!   2. `SqliteBackend.exec` binds EMPTY slices as SQL NULL →
//!      `content: ""` violated the NOT NULL constraint (500).
//! Neither failure is visible to a mock-level test; both only appear
//! when the REAL useCase runs against a REAL SQLite database with the
//! EXACT wire payload the frontend sends.
//!
//! LESSON (user directive): verify HTTP-body-shaped behaviour with
//! isolated functional tests that replay the exact JSON body the
//! client sends — do NOT spin up a live server for verification.
//! These tests run the production `useCase` against an in-memory DB
//! seeded via the real migrations (076 + 079), no sockets involved.
//!
//! Coverage:
//!   A. file→text switch: `{file_path:"", content:"..."}` → 200-shape,
//!      row flips to content-backed.
//!   B. text→file switch: `{file_path:"/abs", content:""}` → row flips
//!      to file-backed, content cleared (NOT a NULL crash).
//!   C. relative non-empty path still rejected (guard stays).
//!   D. route-order contract: `/knowledge/reorder` must be registered
//!      BEFORE `/knowledge/:knowledge_id` in main.zig, or the literal
//!      route is shadowed and reorder PATCHes hit the update handler
//!      with knowledge_id="reorder".

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const update_mod = @import("agent_knowledge_update.zig");
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../../../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;
const Migration079AddContentToAgentKnowledge = @import("../../../migrations/migration.zig").Migration079AddContentToAgentKnowledge;

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
    var ctx = try setupDb();
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
    var ctx = try setupDb();
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
    var ctx = try setupDb();
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
