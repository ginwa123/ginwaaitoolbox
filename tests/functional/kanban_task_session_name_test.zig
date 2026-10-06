// Functional tests: `sessions.name` MUST equal `workspace_item_tasks.name`
// after a kanban task create.
//
// Zig port of `tests/functional/kanban_task_session_name_test.py`
// (same test names, same order).
//
// PYTHON DOCSTRING, PRESERVED:
//
//   """Functional tests: ``sessions.name`` MUST equal
//   ``workspace_item_tasks.name`` after create.
//
//   Regression for the user-reported bug "task name and session name
//   should same" (task_1787671636395_1). The user opened a kanban
//   board, created a card with a real title ("settings like on notifi
//   when error not showup in frontend  also retry ms"), then opened a
//   chatview / sidebar list and saw the linked session row's ``name``
//   column holding the literal task_id (e.g. ``task_1787671269086_0``)
//   instead of the title.
//
//   The contract this file pins:
//
//       For every API path that creates a kanban task + linked session,
//       the very next ``SELECT sessions.name FROM sessions WHERE id =
//       task_id`` must return the user-typed task title — never the
//       task_id, never ``"New Session"``, never an empty string.
//
//   If a future refactor diverges one path from this contract, the
//   matching test fails. The 2026-08-13 PR #225 fixed three paths but
//   left gaps in the legacy ``mode='create'``-without-unattended lazy
//   session-init path; this suite catches both the original regression
//   and any new gap.
//
//   Plan: docs/superpowers/plans/2026-09-02-kanban-task-session-name-bind.md
//   Task: task_1787671636395_1
//   """
//
// ── PORTING NOTES ───────────────────────────────────────────────────────
// * Every test boots with `stub_llm_profile = true` — the Python
//   `llm_harness` fixture. `create_and_run` starts a worker that then
//   fails against the stub; we only care that the `sessions` row is
//   written with the right name BEFORE the worker starts.
//
// * `_read_session_name` opened `<temp_dir>/.config/pabrik/agent.db`
//   with Python's stdlib `sqlite3`. This package links no SQLite, so
//   the port spawns the `sqlite3` COMMAND-LINE tool and parses its
//   `-json` output — the idiom `session_human_touched_at_test.zig`
//   established. Tests that read the DB skip when the CLI is absent.
//
// * `_read_session_name_after` (the poll used by the lazy-init test)
//   keeps its full 5s / 50ms budget. The gap it bridges is real: the
//   `INSERT OR IGNORE INTO sessions` runs in the ASYNC `insert_worker`
//   task scheduled by `di.emit_run_agent`, so the HTTP response arrives
//   before the row exists.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers — wire
// ============================================================================

/// Parse OWNED bytes into a `harness.Json`.
///
/// A `harness.Json` aliases the `Response` body it was parsed from, so a
/// helper may not RETURN one. Helpers below return owned bytes and each
/// test parses locally.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// The string at `key`, or a hard failure naming the field.
fn objectStr(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse {
        std.debug.print("missing `{s}` in response object\n", .{key});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{
        .json_body = body,
        .expect = &.{201},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/kanban {"name": ...}` → item id. Owned.
fn createKanban(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("kanban create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("kanban create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("kanban create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// The wire body of `POST .../items/:kanban/kanban/tasks`.
///
/// Mirrors the frontend's `addKanbanTask(mode, payload)` call:
///
///   - `create`         — legacy (no session INSERT; bare-row insert
///                        only when `is_auto_retry_until_stop` is
///                        supplied).
///   - `create_session` — plain "Create task" button. Inserts a full
///                        sessions row (no worker kick-off).
///   - `create_and_run` — "Create task & run agent" button. Inserts a
///                        full sessions row AND starts the worker
///                        (requires a non-empty `queue_message`).
const KanbanTaskBody = struct {
    mode: []const u8,
    name: []const u8,
    description: []const u8 = "test description",
    is_auto_retry_until_stop: ?[]const u8 = null,
    queue_message: ?[]const u8 = null,
};

/// POST `/workspaces/:ws/items/:kanban/kanban/tasks` with the given mode.
/// Returns the WHOLE response body, owned.
fn createTaskViaKanbanEndpoint(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    mode: []const u8,
    is_auto_retry_until_stop: ?[]const u8,
    queue_message: ?[]const u8,
) ![]u8 {
    // The frontend concatenates name + "\n\n" + description for
    // `create_and_run`; the handler 400s on an empty queue_message
    // (kanban_tasks_create.zig:127-135).
    const auto_queue = if (queue_message == null and std.mem.eql(u8, mode, "create_and_run"))
        try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ name, "test description" })
    else
        null;
    defer if (auto_queue) |q| gpa.free(q);

    const body = try std.json.Stringify.valueAlloc(gpa, KanbanTaskBody{
        .mode = mode,
        .name = name,
        .description = "test description",
        .is_auto_retry_until_stop = is_auto_retry_until_stop,
        .queue_message = queue_message orelse auto_queue,
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// POST `/workspaces/:ws/items/:item/tasks` — the GENERIC endpoint, NOT
/// the kanban-scoped one. `task_type='standard'` is the default.
///
/// This endpoint also creates a kanban task when the parent item is a
/// kanban (task_create.zig::useCase auto-assigns to the first column
/// at MAX(kanban_position)+1).
///
/// `is_auto_retry_until_stop` is `?[]const u8` on the wire — the
/// handler inserts a bare sessions row (no profile column) when the
/// field is set. This is the unattended-mode flag.
const GenericTaskBody = struct {
    name: []const u8,
    description: []const u8 = "test description",
    task_type: []const u8 = "standard",
    is_auto_retry_until_stop: ?[]const u8 = null,
};

fn createTaskViaGenericEndpoint(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    is_auto_retry_until_stop: ?[]const u8,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, GenericTaskBody{
        .name = name,
        .task_type = "standard",
        .is_auto_retry_until_stop = is_auto_retry_until_stop,
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `resp["task"]["id"]` — owned.
fn taskIdOf(body: []const u8) ![]u8 {
    var doc = try parseJson(body);
    defer doc.deinit();
    const task = doc.object("task") orelse {
        std.debug.print("create response has no `task`: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    const id = switch (task.get("id") orelse {
        std.debug.print("create response task has no id: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("create response task id is not a string: {s}\n", .{body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `resp["id"]` on a response whose ROOT is the task object.
///
/// The generic `POST /items/:item/tasks` endpoint answers with the task
/// itself (no `{ task: ... }` envelope), unlike the kanban-scoped one.
fn rootIdOf(body: []const u8) ![]u8 {
    var doc = try parseJson(body);
    defer doc.deinit();
    const o = switch (doc.value().*) {
        .object => |m| m,
        else => {
            std.debug.print("generic /tasks response is not an object: {s}\n", .{body});
            return error.TestUnexpectedResult;
        },
    };
    const id = switch (o.get("id") orelse {
        std.debug.print("generic /tasks response has no id: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("generic /tasks response id is not a string: {s}\n", .{body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

// ============================================================================
// Helpers — sqlite3 CLI
// ============================================================================

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}); skipping DB assertions\n",
            .{code},
        );
        return error.SkipZigTest;
    }
}

/// `sqlite3 -json` prints ZERO BYTES for an empty result set, not `[]`.
fn parseSqliteJson(out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, gpa, out, .{});
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try out.writer.writeByte('\'');
        try out.writer.writeByte(c);
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

/// The agent DB inside the isolated tmpdir HOME.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Run one statement against `db_path`, return the CLI's stdout (owned).
///
/// `.timeout 5000` is the `busy_timeout` the server's WAL connection
/// needs; a bare CLI invocation would otherwise fail with SQLITE_BUSY.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// Read `sessions.name` straight from the SQLite DB.
///
/// Returns null when no row matches (the session hasn't been INSERTed
/// yet — the `mode='create'`-without-unattended lazy path until the
/// user types their first chat message). The returned slice is OWNED.
fn readSessionName(temp_dir: []const u8, session_id: []const u8) !?[]u8 {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    const lit = try sqlLit(session_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT name FROM sessions WHERE id = {s}",
        .{lit},
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len == 0) return null; // no such row
    const o = switch (arr.items[0]) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    const cell = o.get("name") orelse return null;
    return switch (cell) {
        .string => |s| try gpa.dupe(u8, s),
        .null => null,
        else => error.TestUnexpectedResult,
    };
}

fn freeOpt(opt: ?[]u8) void {
    if (opt) |s| gpa.free(s);
}

/// Poll the DB for a `sessions` row matching `session_id` until one
/// appears OR `timeout_ms` elapses.
///
/// Required for the lazy-init path (test 7). The chain is:
///
///     POST /api/llm/session -> useCase -> di.emit_run_agent (synchronous)
///         -> insert_worker (scheduled on the Io group, NOT synchronous)
///         -> returns HTTP response
///     (HTTP response arrives BEFORE insert_worker runs)
///
/// So a single immediate read can return null because the async
/// `insert_worker` task that owns the actual INSERT has not been
/// scheduled yet. Polling bridges that without making the test's
/// semantics looser (we still verify the row eventually lands with the
/// right name — just on a small time budget).
fn readSessionNameAfter(temp_dir: []const u8, session_id: []const u8, timeout_ms: i64) !?[]u8 {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + timeout_ms;
    while (true) {
        if (try readSessionName(temp_dir, session_id)) |got| return got;
        if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) return null;
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
}

/// Assert `got` equals `want`, printing the value on failure.
///
/// TAKES OWNERSHIP of `got`: it is the `?[]u8` `readSessionName`
/// allocated, and nothing else holds a reference to it.
fn expectSessionName(got: ?[]u8, want: ?[]const u8, detail: []const u8) !void {
    defer freeOpt(got);
    const g = got orelse "<no row>";
    if (want) |w| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print("{s}: expected '{s}', got '{s}'\n", .{ detail, w, g });
            return error.TestUnexpectedResult;
        }
    } else {
        if (got != null) {
            std.debug.print("{s}: expected NO sessions row, got '{s}'\n", .{ detail, g });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 1: mode='create_session'
// ============================================================================

// The plain "Create task" button (`mode='create_session'`) must insert
// a sessions row whose `name` column equals the user-typed task title.
//
// Pre-fix the binding was missing — sessions.name held `task_id` as a
// placeholder. Post-fix (kanban_tasks_create.zig step-5) the bind is
// explicit: `standard_result.name` (the task name) for the
// `(id, name, status, cwd, ...)` tuple.
test "create_session_binds_session_name_to_task_name" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-namebind-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-namebind");
    defer gpa.free(kanban_id);

    const task_title = "Investigate settings notification bug";
    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        task_title,
        "create_session",
        null,
        null,
    );
    defer gpa.free(resp);

    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    {
        var doc = try parseJson(resp);
        defer doc.deinit();
        const session = doc.object("session") orelse {
            std.debug.print("create_session response has no `session`: {s}\n", .{resp});
            return error.TestUnexpectedResult;
        };
        const sid = switch (session.get("id") orelse {
            std.debug.print("session has no id: {s}\n", .{resp});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, sid, task_id)) {
            std.debug.print(
                "task.id == session.id contract: task='{s}', session='{s}'\n",
                .{ task_id, sid },
            );
            return error.TestUnexpectedResult;
        }
        const status = try objectStr(session, "status");
        if (!std.mem.eql(u8, status, "idle")) {
            std.debug.print("create_session must return status='idle', got '{s}'\n", .{status});
            return error.TestUnexpectedResult;
        }
    }

    // If the value is the task_id (e.g. 'task_<timestamp>'), the
    // INSERT OR IGNORE in kanban_tasks_create.zig step-5 is binding the
    // wrong column.
    try expectSessionName(
        try readSessionName(h.temp_dir, task_id),
        task_title,
        "create_session sessions.name",
    );
}

// ============================================================================
// Test 2: mode='create_and_run'
// ============================================================================

// `mode='create_and_run'` (the "Create task & run agent" button) must
// bind `sessions.name = task.name` — same contract as create_session,
// because both paths share kanban_tasks_create.zig's step-5 full
// INSERT.
//
// The worker may not actually finish (stub-llm-profile harness so the
// LLM call fails silently), but the sessions row must be written with
// the correct name BEFORE the worker starts.
test "create_and_run_binds_session_name_to_task_name" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-namebind-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-namebind");
    defer gpa.free(kanban_id);

    const task_title = "Run agent to investigate X";
    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        task_title,
        "create_and_run",
        null,
        null,
    );
    defer gpa.free(resp);

    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    {
        var doc = try parseJson(resp);
        defer doc.deinit();
        const session = doc.object("session") orelse {
            std.debug.print("create_and_run response has no `session`: {s}\n", .{resp});
            return error.TestUnexpectedResult;
        };
        const status = try objectStr(session, "status");
        if (!std.mem.eql(u8, status, "send")) {
            std.debug.print("create_and_run must return status='send', got '{s}'\n", .{status});
            return error.TestUnexpectedResult;
        }
    }

    try expectSessionName(
        try readSessionName(h.temp_dir, task_id),
        task_title,
        "create_and_run sessions.name",
    );
}

// ============================================================================
// Test 3: legacy mode='create' WITH unattended flag
// ============================================================================

// Legacy `mode='create'` is preserved for backward compat. When the
// dialog's Unattended toggle is ON, the handler forwards
// `is_auto_retry_until_stop='1'` into task_create.zig::useCase, which
// inserts a bare sessions row (no profile column) with
// `name = task.name`.
//
// Pinning this contract guards against a regression that drops the
// `if (is_create_only) parsed.is_auto_retry_until_stop else null`
// ternary at kanban_tasks_create.zig:178.
test "create_legacy_with_unattended_binds_session_name_to_task_name" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-namebind-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-namebind");
    defer gpa.free(kanban_id);

    const task_title = "Legacy unattended task";
    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        task_title,
        "create",
        "1",
        null,
    );
    defer gpa.free(resp);

    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    // Legacy mode returns session=null (the handler doesn't add a
    // session envelope for mode='create').
    {
        var doc = try parseJson(resp);
        defer doc.deinit();
        if (doc.object("session") != null) {
            std.debug.print(
                "legacy mode='create' should NOT add a session envelope, got: {s}\n",
                .{resp},
            );
            return error.TestUnexpectedResult;
        }
    }

    try expectSessionName(
        try readSessionName(h.temp_dir, task_id),
        task_title,
        "legacy create+unattended sessions.name",
    );
}

// ============================================================================
// Test 4: legacy mode='create' WITHOUT unattended flag
// ============================================================================

// Legacy `mode='create'` with NO unattended flag should leave the
// sessions table untouched. The session row is created LAZILY when the
// user opens the chat and types the first message (via
// POST /api/llm/session, see test 7 below).
//
// Pinning the "no row yet" state here is important — if a future
// refactor starts inserting unconditionally, the session would be
// created with the wrong name before the user ever opens the chat.
test "create_legacy_without_unattended_creates_no_session_row" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-namebind-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-namebind");
    defer gpa.free(kanban_id);

    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        "Title-only legacy task",
        // No is_auto_retry_until_stop — handler forwards null into
        // useCase, so useCase skips its bare sessions INSERT.
        "create",
        null,
        null,
    );
    defer gpa.free(resp);
    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    try expectSessionName(
        try readSessionName(h.temp_dir, task_id),
        null,
        "legacy create without unattended sessions.name",
    );
}

// ============================================================================
// Test 5: generic endpoint WITH unattended flag
// ============================================================================

// The generic POST /workspaces/:ws/items/:item/tasks endpoint (NOT the
// kanban-scoped one) also creates a kanban task when the parent is a
// kanban. With `is_auto_retry_until_stop='1'` set, task_create.zig's
// useCase inserts a bare sessions row with `name = task.name`.
//
// This is the same code path as test 3, exercised via the
// non-kanban-scoped endpoint. Both must bind correctly.
test "standard_task_via_generic_endpoint_with_unattended_binds_name" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-namebind-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-namebind");
    defer gpa.free(kanban_id);

    const task_title = "Generic endpoint unattended task";
    const resp = try createTaskViaGenericEndpoint(
        &h,
        ws_id,
        kanban_id,
        task_title,
        "1",
    );
    defer gpa.free(resp);

    // The generic endpoint's response IS the task object.
    const task_id = try rootIdOf(resp);
    defer gpa.free(task_id);

    try expectSessionName(
        try readSessionName(h.temp_dir, task_id),
        task_title,
        "generic /tasks + unattended sessions.name",
    );
}

// ============================================================================
// Test 6: generic endpoint WITHOUT unattended flag
// ============================================================================

// Generic POST /tasks endpoint WITHOUT unattended flag must leave the
// sessions table untouched (useCase skips its bare INSERT). Same
// rationale as test 4 — the row is created lazily by the chat
// first-message flow (test 7).
test "standard_task_via_generic_endpoint_without_unattended_creates_no_row" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-namebind-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-namebind");
    defer gpa.free(kanban_id);

    const resp = try createTaskViaGenericEndpoint(
        &h,
        ws_id,
        kanban_id,
        "Generic endpoint lazy task",
        // No is_auto_retry_until_stop.
        null,
    );
    defer gpa.free(resp);

    const task_id = try rootIdOf(resp);
    defer gpa.free(task_id);

    try expectSessionName(
        try readSessionName(h.temp_dir, task_id),
        null,
        "generic /tasks without unattended sessions.name",
    );
}

// ============================================================================
// Test 7: the LAZY-INIT gap — chat first-message must bind the title
// ============================================================================

// REGRESSION PIN: when a kanban task is created WITHOUT an explicit
// session INSERT (the legacy mode='create' without unattended, OR the
// generic /tasks endpoint without unattended, OR the LLM agent tool
// create_kanban_task when unattended+profile are both unset), the
// session row is created LAZILY by the chatview's first-message
// POST /api/llm/session call.
//
// The backend's session_create.zig's useCase receives
// `parsed.session_name` (empty when the frontend doesn't send it) and
// falls back to the literal default `"New Session"` — that's the bug.
// The expected behaviour: when the resolved session_id matches an
// existing `workspace_item_tasks` row, the handler should resolve the
// session name from the task's title.
//
// Pre-fix the sidebar would show "New Session" for every kanban task
// whose chat the user opened without first creating a session.
test "chat_first_message_after_lazy_create_binds_session_name_to_task_name" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-namebind-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-namebind");
    defer gpa.free(kanban_id);

    const task_title = "Lazy-init kanban task";

    // 1. Create the task WITHOUT any session-init fields.
    const resp = try createTaskViaGenericEndpoint(&h, ws_id, kanban_id, task_title, null);
    defer gpa.free(resp);
    const task_id = try rootIdOf(resp);
    defer gpa.free(task_id);

    // 2. Sanity: the sessions row doesn't exist yet.
    try expectSessionName(
        try readSessionName(h.temp_dir, task_id),
        null,
        "sanity before chat first-message",
    );

    // 3. Send the first chat message — the frontend's ChatView does this
    // via api.sendChatMessage, which POSTs to /api/llm/session with
    // NO `session_name` field.
    const turn = try std.fmt.allocPrint(gpa,
        \\{{"session_id":"{s}","queue_message":"Hello agent, please help with this task","cwd_session":"","image_urls":"","selected_profile_model":"","is_auto_retry_until_stop":""}}
    , .{task_id});
    defer gpa.free(turn);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = turn,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    // 4. Poll for the sessions row to appear — the async insert_worker
    // scheduled by di.emit_run_agent may run microseconds (local dev)
    // or hundreds of milliseconds (CI runner) after the response.
    const got = try readSessionNameAfter(h.temp_dir, task_id, 5_000);
    if (got == null) {
        const tail = try h.tailLog(io, gpa, 40);
        defer gpa.free(tail);
        std.debug.print(
            "chat first-message POST must trigger lazy session-row init for task_id='{s}'. " ++
                "Got no row within 5s.\n--- log tail ---\n{s}\n",
            .{ task_id, tail },
        );
        return error.TestUnexpectedResult;
    }
    defer freeOpt(got);

    // - If got is the task_id: session_create.zig is binding
    //   name=session_id by accident (very wrong).
    // - If got is 'New Session': session_create.zig's
    //   parsed.session_name='' fallback is winning.
    if (!std.mem.eql(u8, got.?, task_title)) {
        const tail = try h.tailLog(io, gpa, 40);
        defer gpa.free(tail);
        std.debug.print(
            "sessions.name must equal the user-typed task title after chat " ++
                "first-message lazy-init: expected '{s}', got '{s}'.\n" ++
                "--- log tail ---\n{s}\n",
            .{ task_title, got.?, tail },
        );
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = parseJson;
    _ = objectStr;
    _ = createWorkspace;
    _ = createKanban;
    _ = createTaskViaKanbanEndpoint;
    _ = createTaskViaGenericEndpoint;
    _ = taskIdOf;
    _ = rootIdOf;
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = parseSqliteJson;
    _ = sqlLit;
    _ = dbPath;
    _ = sqliteRun;
    _ = readSessionName;
    _ = freeOpt;
    _ = readSessionNameAfter;
    _ = expectSessionName;
}
