//! `ensureDefaultProject` — the one implementation of this invariant:
//!
//!   Every workspace has a default project. If we look for one and don't
//!   find it, we create it before doing anything else.
//!
//! A "default project" is a `workspace_items` row of `item_type = 'agent'`
//! whose `path` is the **server user's home directory**, plus the matching
//! 1-1 `agents` sibling row and a seeded tool allowlist — i.e. exactly what
//! `workspace_items_create_agent.zig` would have produced, so a default is
//! as usable as a hand-made agent.
//!
//! Why `agent` and why `$HOME`:
//!
//!   * `agent` is the only `item_type` whose "add a chat" action skips the
//!     task-type picker on BOTH clients (`Sidebar.vue::handleAddTask` and
//!     `createTaskStartDecision` in `CreateTaskFlow.kt`). Any other type
//!     would make "New Chat" a two-step flow on at least one platform.
//!
//!   * `$HOME` in `path` is the whole trick. `session_create.zig::
//!     resolveCwdFromTaskOrItem` resolves a session's cwd as
//!     `task.cwd → workspace_items.path → createSandbox(...)`. Neither
//!     client sends a `cwd`, so setting `path = $HOME` here makes every chat
//!     created in this project run with the home directory as its cwd — with
//!     no new request field, no new resolution step, and no change to the
//!     chat route's arity on either client.
//!
//! ## Why the home directory is resolved HERE and never by a client
//!
//! A browser does not know the server user's home, and the Android app has
//! no endpoint that returns it. So `path` is resolved server-side via
//! `SystemFolder.getHomeDirectory`, which already implements the
//! `HOME → USERPROFILE → HOMEDRIVE+HOMEPATH` chain.
//!
//! An empty or non-absolute home is a **hard error**, not a silent `""`.
//! `db_path.zig:36-43` spells out why that matters: downstream `*Absolute`
//! filesystem calls ABORT the process on a relative path. And a default
//! stored with `path = ''` would fall through to `createSandbox`, so the
//! agent would silently run in a temp directory instead of where the user
//! asked. A visible 500 beats either.
//!
//! ## Idempotence, and why it is not optional
//!
//! Three callers race for this: the items **list** read (on every sidebar
//! load), `POST /api/workspaces`, and the "New Chat" tap itself. So:
//!
//!   * the read is a single indexed lookup (the `idx_workspace_items_default_lookup`
//!     index from Migration 094), and the common case is found — no writes;
//!   * the create is guarded by the partial UNIQUE index on
//!     `(workspace_id) WHERE is_default = 1`, so a concurrent second insert
//!     fails at the database, and the loser re-reads the winner's row
//!     instead of erroring.
//!
//! Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const SystemFolder = nalarcore.system_folder.SystemFolder;

/// The display name of an auto-created default project. Cosmetic only —
/// both clients follow the `is_default` flag, never the name, so a user is
/// free to rename it without breaking anything.
pub const DEFAULT_PROJECT_NAME = "Project Default";

pub const EnsureDefaultProjectError = error{
    WorkspaceIdRequired,
    /// No usable home directory: missing, empty, or relative. See the
    /// module comment — a bad `path` is worse than a visible error.
    HomeNotFound,
    DatabaseError,
    OutOfMemory,
};

pub const DefaultProject = struct {
    /// Heap-allocated and owned by the caller. Everything in this struct
    /// Every string field is **heap-duplicated from `allocator`** and owned by
    /// the caller, so [DefaultProject.deinit] can free all four unconditionally.
    ///
    /// This is not a stylistic preference. An earlier revision assigned
    /// `.name = DEFAULT_PROJECT_NAME` (a comptime constant in rodata) on the
    /// create path while the read path duped it — and `deinit` freed both. Freeing
    /// a string the allocator never handed out is undefined behaviour: it corrupts
    /// the allocator's free-list, and the clobbered memory later reads back as
    /// `0xAA` poison, which reached the UI as a project literally named
    /// `[ 170, 170, 170, … ]`. Uniform ownership is what makes the free sound.
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    /// The server user's home directory.
    path: []const u8,
    position: i64,
    /// True when THIS call created the row. The wire layer uses it to pick
    /// 201 vs 200. False on every subsequent call — that is the invariant.
    created: bool,

    pub fn deinit(self: DefaultProject, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

/// Idempotent. Returns the workspace's default project, creating it when
/// the lookup finds nothing.
pub fn ensureDefaultProject(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    workspace_id: []const u8,
    environment: ?*const std.process.Environ.Map,
    config_tools: ?[]const []const u8,
) EnsureDefaultProjectError!DefaultProject {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    // Fast path: found. One indexed read, no writes. This is the case that
    // runs on every sidebar load once the default exists.
    if (readDefault(allocator, db, workspace_id)) |found| return found;

    // Miss. Resolve the home directory BEFORE opening a transaction so a bad
    // home leaves nothing half-written (the test for this asserts zero rows).
    const home = SystemFolder.getHomeDirectory(allocator, environment) catch return error.HomeNotFound;
    defer allocator.free(home);

    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.HomeNotFound;

    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    // The production handlers rely on the request arena to reap this, but
    // the inline tests use testing.allocator, which leak-detects.
    errdefer allocator.free(item_id);

    // `tx` so the 3 INSERTs are atomic. A crash between the workspace_items
    // row and the agents sibling row would otherwise leave a workspace item
    // that is item_type='agent' with no agent behind it — breaking the 1-1
    // invariant the agent UI depends on.
    var tx = db.begin() catch return error.DatabaseError;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // Every statement below goes through `tx`, never `db`: the tx holds the
    // backend mutex and the lock is not reentrant. (Same constraint as
    // workspace_items_create_agent.zig:139-152.)
    tx.exec(
        allocator,
        \\INSERT INTO workspace_items
        \\  (id, workspace_id, item_type, name, path, position, is_default, created_at, updated_at)
        \\VALUES (?, ?, 'agent', ?, ?,
        \\  COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1,
        \\  1, datetime('now'), datetime('now'))
    , &[_][]const u8{ item_id, workspace_id, DEFAULT_PROJECT_NAME, home, workspace_id }) catch |err| switch (err) {
        // The partial UNIQUE index rejected us: another caller created the
        // default between our read and our write. That is the race working
        // as designed, so roll back and return the winner's row rather than
        // surfacing an error to whoever called us. Note that
        // `SqliteBackend.exec` reports a constraint violation as
        // `error.ExecuteFailed` — the "UNIQUE constraint failed" text only
        // reaches the log, so the error name is the only signal available.
        error.ExecuteFailed => {
            tx.rollback() catch {};
            if (readDefault(allocator, db, workspace_id)) |winner| {
                allocator.free(item_id);
                return winner;
            }
            return error.DatabaseError;
        },
        else => return error.DatabaseError,
    };

    // The agent sibling shares the item's id (spec D3), which
    // `agents.workspace_item_id UNIQUE` turns into a 1-1 invariant.
    tx.exec(
        allocator,
        "INSERT INTO agents (id, workspace_item_id) VALUES (?, ?)",
        &[_][]const u8{ item_id, item_id },
    ) catch return error.DatabaseError;

    // Seed the tool allowlist so a fresh default is immediately usable
    // rather than a NotConfigured dead-end. Inside the same tx, and through
    // `tx` (not `db`) for the mutex reason above.
    tools_equipped.seedDefaultAgentTools(allocator, .{ .tx = &tx }, item_id, config_tools) catch return error.DatabaseError;

    tx.commit() catch return error.DatabaseError;

    // The INSERT computes position via a correlated subquery, so the
    // persisted value isn't known without a follow-up read — same
    // readInsertedPosition pattern as the kanban/agent create handlers.
    return DefaultProject{
        .id = item_id,
        .workspace_id = try allocator.dupe(u8, workspace_id),
        // DUPE, not the constant. `deinit` frees every field, and freeing the
        // comptime string `DEFAULT_PROJECT_NAME` — which lives in rodata and was
        // never handed out by this allocator — corrupts the free-list. The
        // clobbered memory then surfaces as `0xAA` bytes in an unrelated
        // string, which is how a project ended up named
        // `[ 170, 170, 170, … ]`. The read path below already duped, so this
        // makes the two paths agree.
        .name = try allocator.dupe(u8, DEFAULT_PROJECT_NAME),
        .path = try allocator.dupe(u8, home),
        .position = readPosition(allocator, db, item_id),
        .created = true,
    };
}

/// Is this a name a person could have typed?
///
/// The rule is deliberately narrow, because a false positive here **destroys a
/// user's rename**. So it rejects only what memory corruption can actually
/// produce, and nothing else:
///
///   * empty — a NULL or clobbered name;
///   * invalid UTF-8 — the 0xAA poison bytes this feature really did emit are a
///     run of continuation bytes, which is not valid UTF-8 by construction;
///   * any C0/C1 control character — poison that happened to land on
///     codepoints that *are* valid would still be caught here.
///
/// Everything else is accepted, deliberately including non-ASCII and
/// punctuation-only names: "café", "проект", and "." are all names someone
/// chose, and an earlier ASCII-only version of this check would have silently
/// rewritten all three.
fn nameLooksUsable(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;

    // Iterate CODEPOINTS, not bytes. UTF-8 continuation bytes occupy
    // 0x80..0xBF, so testing raw bytes against the C1 range (0x80..0x9F)
    // rejects perfectly good non-ASCII names — "проект" has a 0x80
    // continuation byte in its second character. Only C0 controls and DEL
    // (0x00..0x1F, 0x7F) are safe to test as bytes, because they can never
    // appear inside a multi-byte sequence.
    var view = std.unicode.Utf8View.init(name) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // C0 controls, DEL, and the C1 range. A control character in a
        // project name is either corruption or a paste accident, and
        // rewriting it is the safer of the two outcomes.
        if (cp < 0x20) return false;
        if (cp == 0x7F) return false;
        if (cp >= 0x80 and cp <= 0x9F) return false;
    }
    return true;
}

/// Repair a default project whose stored `name` is garbage, in place.
///
/// The allocator bug that produced such names is fixed, but any row already
/// written before the fix is still sitting in the user's database, and this
/// endpoint reads on every sidebar load — so it is the cheapest place to heal.
/// The rewrite is a single indexed UPDATE by primary key, it only fires on a name
/// no human would have typed, and a user rename is left alone.
fn repairGarbageName(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
    stored_name: []const u8,
) void {
    if (nameLooksUsable(stored_name)) return;
    db.exec(
        allocator,
        "UPDATE workspace_items SET name = ? WHERE id = ?",
        &[_][]const u8{ DEFAULT_PROJECT_NAME, item_id },
    ) catch |err| {
        // Non-fatal on purpose: a stale name is cosmetic, and failing the
        // read over it would be strictly worse than showing it.
        std.log.warn(
            "ensureDefaultProject: could not repair the default project's name (non-fatal): {s}",
            .{@errorName(err)},
        );
        return;
    };
    std.log.info(
        "ensureDefaultProject: repaired a corrupted default project name for item {s}",
        .{item_id},
    );
}

/// Read the workspace's default project, or null when it has none.
/// This is the whole "does a default exist?" query — one row on the hot path.
fn readDefault(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    workspace_id: []const u8,
) ?DefaultProject {
    var q = db.query(
        allocator,
        \\SELECT id, name, path, position FROM workspace_items
        \\WHERE workspace_id = ? AND is_default = 1
    , &[_][]const u8{workspace_id}) catch return null;
    defer q.deinit();

    const row = (q.next() catch null) orelse return null;
    defer row.deinit(allocator);

    // Dup every field up front, before the row's memory is released by
    // `defer` — the same dangling-slice trap that `resolveCwdFromTaskOrItem`
    // fell into, avoided here by never returning a reference into the row.
    const id = allocator.dupe(u8, row.values[0]) catch return null;
    const ws = allocator.dupe(u8, workspace_id) catch {
        allocator.free(id);
        return null;
    };
    const name = allocator.dupe(u8, row.values[1]) catch {
        allocator.free(id);
        allocator.free(ws);
        return null;
    };
    const path = allocator.dupe(u8, row.values[2]) catch {
        allocator.free(id);
        allocator.free(ws);
        allocator.free(name);
        return null;
    };
    const position = std.fmt.parseInt(i64, row.values[3], 10) catch 0;

    // Heal a name corrupted by an earlier build, now that we hold an owned copy
    // and know the row's id. Best effort, and never on a name a user typed.
    if (!nameLooksUsable(name)) {
        repairGarbageName(allocator, db, id, name);
        allocator.free(name);
        return DefaultProject{
            .id = id,
            .workspace_id = ws,
            .name = allocator.dupe(u8, DEFAULT_PROJECT_NAME) catch {
                allocator.free(id);
                allocator.free(ws);
                return null;
            },
            .path = path,
            .position = position,
            .created = false,
        };
    }

    return DefaultProject{
        .id = id,
        .workspace_id = ws,
        .name = name,
        .path = path,
        .position = position,
        .created = false,
    };
}

/// Best-effort: the persisted `position` of a just-INSERTed item. Returns 0
/// on failure — position is a sort hint, and 0 is a legal value for it.
fn readPosition(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
) i64 {
    var q = db.query(allocator, "SELECT position FROM workspace_items WHERE id = ?", &[_][]const u8{item_id}) catch return 0;
    defer q.deinit();
    const row = (q.next() catch null) orelse return 0;
    defer row.deinit(allocator);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

/// True when a workspace row exists. Used to gate the list-side ensure:
/// `useCaseList` returns `[]` for an unknown workspace rather than 404, so
/// there is no existence check to lean on, and an ungated ensure would
/// create an ORPHAN workspace_items row for a workspace that never existed.
pub fn workspaceExists(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    workspace_id: []const u8,
) bool {
    var q = db.query(allocator, "SELECT 1 FROM workspaces WHERE id = ?", &[_][]const u8{workspace_id}) catch return false;
    defer q.deinit();
    const row = q.next() catch null orelse return false;
    defer row.deinit(allocator);
    return true;
}

// =====================================================================
// Handler — POST /api/workspaces/:workspace_id/default-project
// =====================================================================
//
// The cold-start fallback. `GET .../items` (Step 4) already ensures the
// default on the normal path, so most clients never reach this. It exists
// for the one case the list cannot cover: the app was open when Migration
// 094 ran, so its loaded list predates the `is_default` column and a New
// Chat tap would otherwise be a no-op until a manual refetch.
//
// Deliberately takes NO body: this is a command ("give me the default"),
// not a resource creation, and a body would tempt a name/path override
// that the invariant forbids anyway.

const DefaultProjectResponse = struct {
    item: http_response.WorkspaceItemGetResponse,
    created: bool,
    /// Sort hint for the item above. Kept beside it, not inside it, so the
    /// item keeps the exact shape `GET /workspaces/:ws/items` emits — one
    /// WorkspaceItem, two producers.
    position: i64,
};

pub const WorkspaceDefaultProjectInput = struct {
    workspace_id: []const u8,
    /// Live config.json `tools` checklist (null = built-in defaults).
    /// Read from the singleton by the handler, matching
    /// `workspace_items_create_agent.zig`.
    config_tools: ?[]const []const u8 = null,
    environment: ?*const std.process.Environ.Map = null,
};

pub fn useCaseGet(allocator: std.mem.Allocator, db: *nalarcore.sqlite.SqliteBackend, input: WorkspaceDefaultProjectInput) EnsureDefaultProjectError![]const u8 {
    const project = try ensureDefaultProject(allocator, db, input.workspace_id, input.environment, input.config_tools);
    defer project.deinit(allocator);

    const json = try std.json.Stringify.valueAlloc(allocator, DefaultProjectResponse{
        .item = .{
            .id = project.id,
            .workspace_id = project.workspace_id,
            .item_type = "agent",
            .name = project.name,
            .path = project.path,
            .is_default = 1,
        },
        // Reported next to the item rather than inside it: `position` is a
        // per-item sort hint the workspace_items list already carries, and
        // this envelope is a lookup, not a listing.
        .position = project.position,
        .created = project.created,
    }, .{});
    return json;
}

pub fn workspaceDefaultProjectHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;
    const config_tools = nalarcore.getLlmConfig(di).tools;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }

    // An unknown workspace is a 404 here, unlike the list endpoint which
    // answers 200 + []. This is an explicit request for a specific
    // workspace's default, so "no such workspace" is a real answer.
    if (!workspaceExists(allocator, sqlite_db, workspace_id)) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace not found" }),
        });
    }

    const data = useCaseGet(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .config_tools = config_tools,
        .environment = di.environment,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.HomeNotFound, error.DatabaseError, error.OutOfMemory => 500,
        };
        // Never echo the path back — a 500 here means the home directory
        // could not be resolved, and the caller has no need for it.
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.HomeNotFound => "Could not resolve the home directory for the default project",
            error.DatabaseError => "Failed to resolve the default project",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // 201 when this call created the default, 200 when it already existed.
    // The body carries `created` so a client never has to guess.
    const created = std.mem.indexOf(u8, data, "\"created\":true") != null;
    return res.jsonResponse(.{ .status_code = if (created) 201 else 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = @import("nalarcore").sqlite;
const testing = std.testing;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    home: []const u8,

    fn deinit(self: *TestCtx) void {
        self.env.deinit();
        self.threaded.deinit();
        self.db.deinit();
    }
};

fn setupDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Migration 094's shape: is_default NOT NULL DEFAULT 0 plus BOTH
    // indexes. The partial unique index is not optional here — the race
    // guard in ensureDefaultProject is only meaningful if the database
    // rejects a second default, so a test that omitted it would be testing
    // a different system than production runs.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  item_type TEXT NOT NULL,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER NOT NULL DEFAULT 0,
        \\  is_default INTEGER NOT NULL DEFAULT 0,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE UNIQUE INDEX idx_workspace_items_default_per_workspace
        \\ON workspace_items(workspace_id) WHERE is_default = 1
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE INDEX idx_workspace_items_default_lookup
        \\ON workspace_items(workspace_id, is_default)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agents (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL UNIQUE,
        \\  description TEXT,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_tools (
        \\  id TEXT PRIMARY KEY,
        \\  agent_id TEXT NOT NULL,
        \\  tool_name TEXT NOT NULL,
        \\  enabled INTEGER NOT NULL DEFAULT 1,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT, user_id TEXT)", &[_][]const u8{});

    // A real environment map with HOME set, because getHomeDirectory takes
    // one and the whole feature is defined by where HOME lands.
    var env: std.process.Environ.Map = .init(alloc);
    errdefer env.deinit();
    try env.put("HOME", "/home/tester");

    return .{ .db = db, .threaded = threaded, .env = env, .home = "/home/tester" };
}

/// Run a `SELECT COUNT(*)` whose WHERE clause needs the item id(s) interpolated.
/// `template` is a comptime fmt string; pass one `{{s}}` argument per `{{s}}`
/// placeholder. Ids here are generated by the code under test, never user
/// input, so interpolation is safe and keeps the assertions readable.
///
/// comptime because Zig 0.16 requires a compile-time format string for both
/// `bufPrint` and `allocPrint` — a runtime template cannot be formatted at all.
fn countWhereFmt(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    comptime template: []const u8,
    ids: anytype,
) !u32 {
    const sql = try std.fmt.allocPrint(alloc, template, ids);
    defer alloc.free(sql);
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(alloc);
    return std.fmt.parseInt(u32, row.values[0], 10);
}

fn countWhere(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, table: []const u8, where: []const u8) !u32 {
    var buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM {s} WHERE {s}", .{ table, where });
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(alloc);
    return std.fmt.parseInt(u32, row.values[0], 10);
}

test "ensureDefaultProject creates the default on a miss, rooted at HOME" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    try testing.expect(p.created);
    try testing.expectEqualStrings("/home/tester", p.path);
    try testing.expectEqualStrings(DEFAULT_PROJECT_NAME, p.name);

    // The row, and the two siblings that make it a usable agent. The
    // combined WHERE is deliberate: it asserts the type, the flag and the
    // path on the SAME row rather than three independent counts.
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
    try testing.expectEqual(@as(u32, 1), try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM workspace_items WHERE id = '{s}' AND item_type = 'agent' AND is_default = 1 AND path = '/home/tester'", .{p.id}));
    // The 1-1 invariant: the agents row's id AND workspace_item_id are both
    // the item id, which is what `agents.workspace_item_id UNIQUE` relies on.
    try testing.expectEqual(@as(u32, 1), try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM agents WHERE id = '{s}' AND workspace_item_id = '{s}'", .{ p.id, p.id }));

    // The tool allowlist must be seeded, or the default project is a
    // NotConfigured dead-end on first use.
    const seeded = try countWhereFmt(&ctx.db, alloc, "SELECT COUNT(*) FROM agent_tools WHERE agent_id = '{s}'", .{p.id});
    try testing.expect(seeded > 0);
}

test "ensureDefaultProject is idempotent: a second call returns the same id and creates nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const first = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer first.deinit(alloc);

    const second = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer second.deinit(alloc);

    // The invariant, asserted. Same row, and the second call reports that
    // it did not create anything.
    try testing.expectEqualStrings(first.id, second.id);
    try testing.expect(!second.created);
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1' AND is_default = 1"));
}

test "ensureDefaultProject gives each workspace its own default" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const a = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer a.deinit(alloc);
    const b = try ensureDefaultProject(alloc, &ctx.db, "ws_2", &ctx.env, null);
    defer b.deinit(alloc);

    try testing.expect(!std.mem.eql(u8, a.id, b.id));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1' AND is_default = 1"));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_2' AND is_default = 1"));
}

test "ensureDefaultProject returns the existing default alongside ordinary items" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    // A workspace that already has projects but no default — the legacy
    // shape this feature has to heal.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('item_kanban', 'ws_1', 'kanban', 'Board', '/tmp/board', 5)
    , &[_][]const u8{});

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    try testing.expect(p.created);
    // The ordinary project is untouched, and the default landed at the TOP
    // (position 6 > 5) so it is visible without scrolling.
    try testing.expectEqual(@as(u32, 2), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "id = 'item_kanban' AND is_default = 0"));
    try testing.expectEqual(@as(i64, 6), p.position);
}

test "ensureDefaultProject writes nothing when the home directory is unusable" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    var no_home: std.process.Environ.Map = .init(alloc);
    defer no_home.deinit();
    // HOME present but EMPTY. On POSIX that historically "succeeded" with
    // "" — which is exactly the case that would store path='' and send the
    // agent to a temp sandbox. It must be a hard error instead.
    try no_home.put("HOME", "");

    try testing.expectError(
        error.HomeNotFound,
        ensureDefaultProject(alloc, &ctx.db, "ws_1", &no_home, null),
    );
    // Nothing half-written: the miss branch must not leave a row behind.
    try testing.expectEqual(@as(u32, 0), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));

    // And no env at all.
    try testing.expectError(
        error.HomeNotFound,
        ensureDefaultProject(alloc, &ctx.db, "ws_1", null, null),
    );
    try testing.expectEqual(@as(u32, 0), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
}

test "ensureDefaultProject rejects an empty workspace id" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        ensureDefaultProject(alloc, &ctx.db, "", &ctx.env, null),
    );
}

test "ensureDefaultProject honours the partial unique index under a simulated race" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const first = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer first.deinit(alloc);

    // Simulate the loser of a race: force the fast path to miss, then try
    // to insert a second default the way the create branch would. The
    // database must refuse it — this is the guarantee the whole
    // ExecuteFailed catch block exists to rely on.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc,
            \\INSERT INTO workspace_items
            \\  (id, workspace_id, item_type, name, path, position, is_default)
            \\VALUES ('item_loser', 'ws_1', 'agent', 'Project Default', '/home/tester', 0, 1)
        , &[_][]const u8{}),
    );
    // Still exactly one default, and the winner is intact.
    try testing.expectEqual(@as(u32, 1), try countWhere(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1' AND is_default = 1"));

    // And a re-read returns the winner, which is what the catch block does.
    const after = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer after.deinit(alloc);
    try testing.expectEqualStrings(first.id, after.id);
}

test "useCaseGet serializes the project and reports whether it created it" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const first = try useCaseGet(alloc, &ctx.db, .{ .workspace_id = "ws_1", .environment = &ctx.env });
    defer alloc.free(first);
    const second = try useCaseGet(alloc, &ctx.db, .{ .workspace_id = "ws_1", .environment = &ctx.env });
    defer alloc.free(second);

    // `"created":true` is what the handler reads to choose 201 vs 200, so
    // this asserts the exact substring the handler greps for.
    try testing.expect(std.mem.indexOf(u8, first, "\"created\":true") != null);
    try testing.expect(std.mem.indexOf(u8, second, "\"created\":false") != null);

    // Both must report the SAME id — the envelope, not just the service.
    // Mirrors DefaultProjectResponse exactly, `position` included: the parser
    // is strict about unknown fields, so a View that omits one fails on the
    // very response it is meant to check.
    const View = struct {
        item: http_response.WorkspaceItemGetResponse,
        created: bool,
        position: i64,
    };
    const p1 = try std.json.parseFromSliceLeaky(View, alloc, first, .{});
    const p2 = try std.json.parseFromSliceLeaky(View, alloc, second, .{});
    try testing.expectEqualStrings(p1.item.id, p2.item.id);
    try testing.expectEqual(@as(i64, 1), p1.item.is_default);
    try testing.expectEqualStrings("/home/tester", p1.item.path.?);
    try testing.expectEqualStrings("agent", p1.item.item_type);
}

test "workspaceExists distinguishes a real workspace from an invented one" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_real', 'Real')", &[_][]const u8{});

    try testing.expect(workspaceExists(alloc, &ctx.db, "ws_real"));
    // This is the orphan guard. useCaseList returns [] for an unknown
    // workspace rather than 404, so without this probe a list read of
    // "ws_ghost" would create a default for a workspace that never
    // existed.
    try testing.expect(!workspaceExists(alloc, &ctx.db, "ws_ghost"));
    try testing.expect(!workspaceExists(alloc, &ctx.db, ""));
}

// ─── The corrupted-name repair ───────────────────────────────────────────
//
// A build with the bad free wrote default projects whose `name` came back as
// 0xAA poison bytes, which the UI rendered as `[ 170, 170, … ]`. Fixing the
// allocator stops new damage but leaves those rows in the user's database, so
// the read path heals them. These tests pin both halves of the rule: garbage is
// repaired, and a name a person typed is left alone.

test "nameLooksUsable rejects poison bytes and blanks, accepts real names" {
    // The exact shape the bug produced: 0xAA repeated.
    var poison: [8]u8 = undefined;
    @memset(&poison, 0xAA);
    try testing.expect(!nameLooksUsable(&poison));

    // Invalid UTF-8 (a lone continuation byte), and a blank.
    try testing.expect(!nameLooksUsable("\x80"));
    try testing.expect(!nameLooksUsable(""));

    // Real names, including ones a person deliberately chose. A false
    // negative here means the heal would clobber a user's rename, which is
    // the one way this repair could do harm.
    try testing.expect(nameLooksUsable(DEFAULT_PROJECT_NAME));
    try testing.expect(nameLooksUsable("My Home Chat"));
    try testing.expect(nameLooksUsable("project 2"));
    // Non-ASCII is a legitimate name, not corruption. An earlier ASCII-only
    // version of this check rejected all three of these and would have silently
    // rewritten a user's rename.
    try testing.expect(nameLooksUsable("caf\u{00e9}"));
    try testing.expect(nameLooksUsable("\u{043f}\u{0440}\u{043e}\u{043a}\u{0435}\u{043a}\u{0442}"));
    // Punctuation-only is odd but is still something a person typed.
    try testing.expect(nameLooksUsable("."));
    try testing.expect(nameLooksUsable("---"));

    // Control characters ARE rejected, even when the rest is valid UTF-8 —
    // this is the second line of defence behind the UTF-8 check.
    try testing.expect(!nameLooksUsable("New\u{0001}Chat"));
    try testing.expect(!nameLooksUsable("\u{007f}"));
}

test "a corrupted default project name is repaired on read" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    // Seed a default whose name is poison bytes, the way the bad build did.
    var poison: [8]u8 = undefined;
    @memset(&poison, 0xAA);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, is_default)
        \\VALUES ('item_poison', 'ws_1', 'agent', ?, '/home/tester', 0, 1)
    , &[_][]const u8{&poison});

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    // The caller gets a usable name, not the poison.
    try testing.expectEqualStrings(DEFAULT_PROJECT_NAME, p.name);
    try testing.expect(nameLooksUsable(p.name));

    // And the stored row was actually rewritten, so the next read is clean too.
    const stored = try countWhereFmt(&ctx.db, alloc,
        "SELECT COUNT(*) FROM workspace_items WHERE id = '{s}' AND name = 'Project Default'",
        .{p.id});
    try testing.expectEqual(@as(u32, 1), stored);
}

test "a user rename of the default project is never clobbered" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.deinit();

    const created = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer created.deinit(alloc);
    try ctx.db.exec(alloc,
        "UPDATE workspace_items SET name = 'Work stuff' WHERE id = ?",
        &[_][]const u8{created.id},
    );

    const p = try ensureDefaultProject(alloc, &ctx.db, "ws_1", &ctx.env, null);
    defer p.deinit(alloc);

    // A name a person chose survives the heal, and the row is not rewritten.
    try testing.expectEqualStrings("Work stuff", p.name);
    try testing.expectEqual(@as(u32, 1), try countWhereFmt(&ctx.db, alloc,
        "SELECT COUNT(*) FROM workspace_items WHERE id = '{s}' AND name = 'Work stuff'",
        .{p.id}));
}

// ===== Tests merged from workspace_items_default_test.zig (2026-09-29 flatten) =====

// Static contract tests for the default-project route.
//
// ## Why a test that reads source
//
// `matchRoute` walks routes in **registration order** and the first match
// wins. A literal route registered *after* a param route is unreachable —
// the param swallows it. That class of bug is invisible to unit tests,
// because a unit test of the handler never goes through routing at all, and
// it is invisible to a layout test, because nothing is rendered. The only
// way to catch it is to assert on the registration list itself.
//
// The precedent this follows is `run_all_agents.zig:641-673`, which
// carries the same kind of static route assertions for
// `.../kanban/run_all_agents`.
//
// Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md (Step 3)

const default_project_route = ".post(\"/api/workspaces/:workspace_id/default-project\"";
const route_marker = "authed.post(\"/api/workspaces/:workspace_id/";

/// Read `src/http_routes.zig` so the test does not depend on the process working
/// directory. `@embedFile` rather than a runtime open: the assertions must
/// see the route list as COMPILED, otherwise a test run from a different
/// cwd would silently pass by reading nothing.
fn readRouteSource(allocator: std.mem.Allocator) ![]u8 {
    const src = @embedFile("../http_routes.zig");
    return allocator.dupe(u8, src);
}

test "the default-project route is registered" {
    const alloc = testing.allocator;
    const src = try readRouteSource(alloc);
    defer alloc.free(src);

    if (std.mem.indexOf(u8, src, default_project_route) == null) {
        std.debug.print(
            "http_routes.zig does not register {s}\n",
            .{default_project_route},
        );
        return error.DefaultProjectRouteNotRegistered;
    }
}

test "the default-project route is registered before any /api/workspaces POST param sibling" {
    const alloc = testing.allocator;
    const src = try readRouteSource(alloc);
    defer alloc.free(src);

    const ours = std.mem.indexOf(u8, src, default_project_route) orelse
        return error.DefaultProjectRouteNotRegistered;

    // Walk every later `authed.post("/api/workspaces/...` registration and
    // fail if one is a bare `:param` in the segment right after
    // `:workspace_id` — that is exactly the shape that would capture
    // `default-project` as a parameter value and shadow us.
    var i = ours + default_project_route.len;
    while (std.mem.indexOfPos(u8, src, i, route_marker)) |pos| {
        const after = pos + route_marker.len;
        // The segment after `/api/workspaces/:workspace_id/`.
        if (src[after] == ':') {
            const tail_end = std.mem.indexOfScalarPos(u8, src, after, '"') orelse src.len;
            std.debug.print(
                "a POST /api/workspaces/:workspace_id/:param route is registered at byte {d}, AFTER default-project at byte {d} - it would shadow it\n",
                .{ pos, ours },
            );
            _ = tail_end;
            return error.DefaultProjectRouteShadowed;
        }
        i = after;
    }
}

test "no POST /api/workspaces/:workspace_id/:param route exists at all" {
    // Stronger than the ordering test above: it proves the collision is
    // impossible today, not merely absent right now. `.../items`,
    // `.../items/agent`, `.../items/kanban`, `.../items/design`,
    // `.../items/routine` are all literals, so they are fine.
    const alloc = testing.allocator;
    const src = try readRouteSource(alloc);
    defer alloc.free(src);

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, route_marker)) |pos| {
        const after = pos + route_marker.len;
        if (src[after] == ':') {
            const end = std.mem.indexOfScalarPos(u8, src, after, '"') orelse src.len;
            std.debug.print(
                "found a bare param route: authed.post(\"/api/workspaces/:workspace_id/{s}\"\n",
                .{src[after..end]},
            );
            return error.ParamRouteAfterWorkspaceId;
        }
        i = after;
    }
}

test "the default-project route uses a literal segment, not a param" {
    // The whole anti-shadowing argument rests on `default-project` being a
    // literal. If someone "simplifies" it to a param, the ordering test
    // above would keep passing while the route quietly became ambiguous —
    // so assert the literal directly.
    const alloc = testing.allocator;
    const src = try readRouteSource(alloc);
    defer alloc.free(src);

    const bad = "authed.post(\"/api/workspaces/:workspace_id/:param/default-project\"";
    if (std.mem.indexOf(u8, src, bad) != null) return error.DefaultProjectRouteIsAParam;

    const good = default_project_route;
    if (std.mem.indexOf(u8, src, good) == null) return error.DefaultProjectRouteNotRegistered;
}
