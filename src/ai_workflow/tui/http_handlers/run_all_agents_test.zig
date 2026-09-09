//! TDD tests for the bulk `POST .../kanban/columns/:column_id/run_all_agents`
//! endpoint (plan: docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md,
//! Tasks 1+2, Option C).
//!
//! Why this file exists
//! ────────────────────
//! The kanban column header `...` menu needs a "Run all agents" action
//! that starts agents on every idle task in the column — including
//! tasks not yet loaded by pagination. The frontend must NOT loop
//! client-side (it only sees the loaded page); the backend SELECTs
//! all task ids for the column server-side and reuses the existing
//! single-task `startAgentUseCase` per id (keeping its 404/409 guards).
//!
//! Test strategy (two layers, mirroring tasks_get_test.zig):
//!   - Behavioural: `runAllAgentsWithStarter` (the injectable-core of
//!     the use-case) against a bare in-memory SQLite DB. The fake
//!     starter consults the real `isTaskRunning` guard so the
//!     started/skipped split exercises production semantics without
//!     scheduling real LLM workers. The one-line live binding to
//!     `startAgentUseCase` is locked by a static contract below.
//!   - Static-contract: source greps locking the handler/useCase
//!     split, the status-code mapping, the mod.zig re-export, the
//!     main.zig route placement (columns family, never the
//!     /tasks/:task_id family — matchRoute shadowing rule), and the
//!     test_runner registration.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const text_normalize = @import("helpers").text_normalize;
const run_all_agents = @import("run_all_agents.zig");

const IMPL_PATH = "src/ai_workflow/tui/http_handlers/run_all_agents.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const TEST_RUNNER_PATH = "src/ai_workflow/tui/test_runner.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// =====================================================================
// Behavioural harness: bare in-memory DB + fake starter
// =====================================================================

const TestDb = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestDb) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupDb() !TestDb {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

/// Post-Migration-072 minimal schema: the kanban join table holds the
/// 1:1 task-to-board placement (workspace_item_tasks has NO
/// kanban_column_id column). Mirrors the kanban_model.zig test setup.
fn setupColumnSchema(ctx: *TestDb) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    // isTaskRunning only reads worker.session_id; the minimal schema
    // is enough (extra production columns are never referenced).
    try ctx.db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY, session_id TEXT NOT NULL)
    , &.{});
}

/// Seed one column (c1) with three tasks (A idle, B running, C idle).
/// B gets a `worker` row so the real `isTaskRunning` guard fires.
fn seedThreeTaskColumn(ctx: *TestDb) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES " ++
            "('task-A', 'A', 'item_1'), ('task-B', 'B', 'item_1'), ('task-C', 'C', 'item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES " ++
            "('task-A', 'c1', 0), ('task-B', 'c1', 1), ('task-C', 'c1', 2)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO worker (id, session_id) VALUES ('w-B', 'task-B')",
        &.{});
}

/// Fake per-task starter with production guard semantics: consults
/// the real `isTaskRunning` (seeded `worker` row ⇒ skipped), honours
/// a scripted fail-list (⇒ failed), otherwise ⇒ started. Never
/// touches `di.emit_run_agent`, so no real LLM worker is scheduled.
const FakeCtx = struct {
    db: *sqlite.SqliteBackend,
    fail_ids: []const []const u8 = &.{},
};

fn fakeRun(ptr: ?*anyopaque, task_id: []const u8) run_all_agents.PerTaskResult {
    const c: *FakeCtx = @ptrCast(@alignCast(ptr.?));
    for (c.fail_ids) |f| {
        if (std.mem.eql(u8, f, task_id)) return .failed;
    }
    if (nalarcore.ai_mod.llm_history.isTaskRunning(testing.allocator, c.db, task_id)) return .skipped;
    return .started;
}

fn fakeStarter(ctx: *FakeCtx) run_all_agents.TaskStarter {
    return .{ .ptr = ctx, .run = fakeRun };
}

fn containsId(ids: []const []u8, want: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, want)) return true;
    }
    return false;
}

// ─── Behavioural 1: empty column_id is rejected before any DB work ───

test "runAllAgents rejects empty column_id" {
    var ctx = try setupDb();
    defer ctx.deinit();
    var fake = FakeCtx{ .db = &ctx.db };

    // Empty-slice-as-NULL rule: "" must never reach a `WHERE id = ?`
    // binding (SqliteBackend binds "" as SQL NULL). The use-case
    // validates first and returns EmptyColumnId.
    const result = run_all_agents.runAllAgentsWithStarter(
        testing.allocator,
        &ctx.db,
        "",
        fakeStarter(&fake),
    );
    try testing.expectError(error.EmptyColumnId, result);
}

// ─── Behavioural 2: unknown column maps to column_not_found (→ 404) ──

test "runAllAgents maps unknown column to column_not_found" {
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    var fake = FakeCtx{ .db = &ctx.db };

    const result = run_all_agents.runAllAgentsWithStarter(
        testing.allocator,
        &ctx.db,
        "col_does_not_exist",
        fakeStarter(&fake),
    );
    try testing.expectError(error.ColumnNotFound, result);
}

// ─── Behavioural 3: [idle-A, running-B, idle-C] → started [A,C] ──────

test "runAllAgents starts idle tasks and skips running ones" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    try seedThreeTaskColumn(&ctx);
    var fake = FakeCtx{ .db = &ctx.db };

    var outcome = try run_all_agents.runAllAgentsWithStarter(
        alloc,
        &ctx.db,
        "c1",
        fakeStarter(&fake),
    );
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), outcome.started.len);
    try testing.expect(containsId(outcome.started, "task-A"));
    try testing.expect(containsId(outcome.started, "task-C"));

    try testing.expectEqual(@as(usize, 1), outcome.skipped.len);
    try testing.expect(containsId(outcome.skipped, "task-B"));

    try testing.expectEqual(@as(usize, 0), outcome.failed.len);
}

// ─── Behavioural 4: single-task failure never aborts the bulk run ────

test "runAllAgents collects single-task failures instead of throwing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();
    try setupColumnSchema(&ctx);
    try seedThreeTaskColumn(&ctx);
    // task-C's starter blows up (e.g. emit_run_agent DB error in
    // production); A must still start and B must still skip.
    const fail_ids: []const []const u8 = &.{"task-C"};
    var fake = FakeCtx{ .db = &ctx.db, .fail_ids = fail_ids };

    var outcome = try run_all_agents.runAllAgentsWithStarter(
        alloc,
        &ctx.db,
        "c1",
        fakeStarter(&fake),
    );
    defer outcome.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), outcome.started.len);
    try testing.expect(containsId(outcome.started, "task-A"));

    try testing.expectEqual(@as(usize, 1), outcome.skipped.len);
    try testing.expect(containsId(outcome.skipped, "task-B"));

    try testing.expectEqual(@as(usize, 1), outcome.failed.len);
    try testing.expect(containsId(outcome.failed, "task-C"));
}

// =====================================================================
// Static contracts: reuse, wire shape, registration, route placement
// =====================================================================

// ─── Contract 1: bulk reuses the single-task use-case (no copied guards)

test "run_all_agents reuses startAgentUseCase per task id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, IMPL_PATH);
    defer allocator.free(source);

    // Option C core: the bulk loop must delegate per-id to the
    // existing single-task use-case (keeping its 404-via-
    // getWorkspaceItemTask + 409-via-isTaskRunning guards). If this
    // substring is missing, the guards were copy-pasted and will
    // drift from start_agent.zig.
    if (std.mem.indexOf(u8, source, "startAgentUseCase") == null) {
        std.debug.print(
            "\n!! {s} does not call startAgentUseCase !!\n" ++
                "   The bulk endpoint must reuse the single-task use-case\n" ++
                "   per id (Option C). Copy-pasted 404/409 guards will\n" ++
                "   drift from start_agent.zig. Call startAgentUseCase\n" ++
                "   inside the per-id loop and map triggered→started,\n" ++
                "   worker_already_running→skipped, task_not_found→failed.\n",
            .{IMPL_PATH},
        );
        return error.StartAgentUseCaseReuseMissing;
    }
}

// ─── Contract 2: handler reads column_id + maps empty → 400 ──────────

test "run_all_agents handler guards empty column_id with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, IMPL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"column_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the column_id path param !!\n" ++
                "   Add `req.params.get(\"column_id\")` + the empty-length guard.\n",
            .{IMPL_PATH},
        );
        return error.ColumnIdPathParamMissing;
    }
    if (std.mem.indexOf(u8, source, "column_id required") == null) {
        std.debug.print(
            "\n!! {s} does not guard an empty column_id !!\n" ++
                "   The empty-slice-as-NULL rule requires a 400 before any\n" ++
                "   DB call: `if (column_id.len == 0) return 400 ...`.\n",
            .{IMPL_PATH},
        );
        return error.ColumnIdGuardMissing;
    }
}

// ─── Contract 3: handler maps unknown column → 404, success → 200 ────

test "run_all_agents handler maps ColumnNotFound to 404 and success to 200" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, IMPL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ColumnNotFound") == null) {
        std.debug.print(
            "\n!! {s} does not handle ColumnNotFound !!\n" ++
                "   Unknown columns must map to 404 (frontend shows\n" ++
                "   'column deleted?' hint). Handle error.ColumnNotFound.\n",
            .{IMPL_PATH},
        );
        return error.ColumnNotFoundBranchMissing;
    }
    if (std.mem.indexOf(u8, source, ".status_code = 404") == null) {
        std.debug.print(
            "\n!! {s} does not return a 404 status code !!\n",
            .{IMPL_PATH},
        );
        return error.NotFoundStatusMissing;
    }
    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return a 200 status code !!\n" ++
                "   Success must be 200 with {{success:true, column_id,\n" ++
                "   started, skipped, failed}}.\n",
            .{IMPL_PATH},
        );
        return error.SuccessStatusMissing;
    }
    for ([_][]const u8{ "\"started\"", "\"skipped\"", "\"failed\"" }) |key| {
        if (std.mem.indexOf(u8, source, key) == null) {
            std.debug.print(
                "\n!! {s} success body is missing {s} !!\n" ++
                    "   The frontend summary banner needs all three id lists.\n",
                .{ IMPL_PATH, key },
            );
            return error.SuccessKeyMissing;
        }
    }
}

// ─── Contract 4: mod.zig re-exports the handler next to startAgent ───

test "http_handlers mod re-exports runAllAgentsHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub const runAllAgentsHandler") == null) {
        std.debug.print(
            "\n!! {s} does not re-export runAllAgentsHandler !!\n" ++
                "   main.zig references ai_mod.http_handlers.runAllAgentsHandler;\n" ++
                "   without the re-export the route registration fails to compile.\n" ++
                "   Restore (next to startAgentHandler):\n" ++
                "     pub const runAllAgentsHandler = @import(\"run_all_agents.zig\").runAllAgentsHandler;\n",
            .{MOD_PATH},
        );
        return error.HandlerNotReExported;
    }
}

// ─── Contract 5: route lives in the columns family (Task 2) ──────────

test "main.zig registers POST columns/:column_id/run_all_agents in the columns family" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    const route = "gs.router.post(\"/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents\", ai_mod.http_handlers.runAllAgentsHandler)";
    const route_idx = std.mem.indexOf(u8, source, route) orelse {
        std.debug.print(
            "\n!! {s} does not register the run_all_agents route !!\n" ++
                "   Restore (next to the column routes ~L490-493):\n" ++
                "     {s}\n",
            .{ MAIN_PATH, route },
        );
        return error.RunAllAgentsRouteMissing;
    };

    // Placement: must sit with the columns family (right after the
    // column DELETE), NOT under the /tasks/:task_id family
    // (main.zig:503,526-533,540) — matchRoute walks routes in
    // registration order (router.zig:182), so nesting under /tasks/
    // risks shadowing by the :task_id param routes.
    const anchor = "gs.router.delete(\"/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id\", ai_mod.http_handlers.kanbanColumnsDeleteHandler)";
    const anchor_idx = std.mem.indexOf(u8, source, anchor) orelse {
        std.debug.print("\n!! columns DELETE anchor route missing from {s} !!\n", .{MAIN_PATH});
        return error.ColumnsAnchorMissing;
    };
    if (route_idx < anchor_idx) {
        std.debug.print(
            "\n!! run_all_agents route registered BEFORE the columns family in {s} !!\n" ++
                "   Keep it next to the column routes (~L490-493) so the\n" ++
                "   columns family stays together and the /tasks/:task_id\n" ++
                "   family (L503,526-533,540) can never shadow it.\n",
            .{MAIN_PATH},
        );
        return error.RoutePlacementWrong;
    }

    // Anti-shadowing: no /tasks/-nested variant may exist. A literal
    // like `/tasks/run_all` registered after `GET .../tasks/:task_id`
    // would be captured with task_id="run_all".
    for ([_][]const u8{ "tasks/:task_id/run_all", "tasks/run_all" }) |bad| {
        if (std.mem.indexOf(u8, source, bad) != null) {
            std.debug.print(
                "\n!! {s} contains a /tasks/-nested run_all route ({s}) !!\n" ++
                    "   matchRoute would shadow it under :task_id. The bulk\n" ++
                    "   route must nest under kanban/columns/:column_id only.\n",
                .{ MAIN_PATH, bad },
            );
            return error.RouteShadowedByTasksFamily;
        }
    }
}

// ─── Contract 6: test runner registers this test file ─────────────────

test "test_runner registers run_all_agents_test" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TEST_RUNNER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "run_all_agents_test.zig") == null) {
        std.debug.print(
            "\n!! {s} does not import run_all_agents_test.zig !!\n" ++
                "   Without the import these contracts never run.\n" ++
                "   Restore:\n" ++
                "     _ = @import(\"http_handlers/run_all_agents_test.zig\");\n",
            .{TEST_RUNNER_PATH},
        );
        return error.TestNotRegistered;
    }
}
