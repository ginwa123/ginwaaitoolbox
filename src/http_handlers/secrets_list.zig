//! `GET /api/workspaces/:workspace_id/secrets`.
//!
//! Returns `{secrets, count}` for one workspace, ordered by name.
//!
//! NO VALUE APPEARS IN THIS RESPONSE — not masked, not hinted, not
//! truncated. A secret's value lives in POST/PATCH request bodies and
//! stops there, so the browser cannot read back what it wrote. That is the
//! accepted cost of never holding a live credential in a DOM, and "it
//! crossed the network and we chose not to render it" is not a guarantee —
//! it is one XSS away from a leak (Design Decision 9,
//! docs/superpowers/plans/2026-10-02-workspace-secrets.md).
//!
//! Scoping: `workspace_id` is a path param that lands in the query's
//! `WHERE` clause inside `secrets_store.listSecrets`. There is no
//! "all secrets" mode, so no code path here can return another
//! workspace's rows.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const secrets_store = @import("../agentic_loop/secrets_store.zig");

pub const SecretsListError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

pub const SecretsListInput = struct {
    workspace_id: []const u8,
};

pub const SecretsListOutput = struct {
    /// Owned slice; the caller frees it with
    /// `secrets_store.freeSecretRows`.
    secrets: []secrets_store.SecretRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: SecretsListInput,
) SecretsListError!SecretsListOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    const rows = secrets_store.listSecrets(allocator, db, input.workspace_id) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // The rest of the store's shared error set belongs to the write
        // paths, which `listSecrets` cannot reach. Naming them keeps this
        // switch exhaustive, so a variant added to `SecretsError` breaks the
        // build here rather than reaching the client unmapped.
        error.IdsRequired,
        error.NameRequired,
        error.ValueRequired,
        error.InvalidName,
        error.NameTaken,
        error.NotFound,
        error.InsertFailed,
        error.UpdateFailed,
        error.DeleteFailed,
        => unreachable,
    };
    return .{ .secrets = rows };
}

// =====================================================================
// Error mapping
// =====================================================================
//
// Two exhaustive switches, one for the status and one for the message, so a
// variant added to `SecretsListError` fails the build here rather than
// surfacing as an unhandled error at runtime.
//
// They are functions rather than inline blocks inside the handler for one
// reason: `useCase` returns the error, never the HTTP answer, so a
// 400-where-a-500-belongs mistake is invisible to every useCase test
// unless the mapping is itself callable.

fn statusFor(err: SecretsListError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired => 400,
        error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: SecretsListError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn secretsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer secrets_store.freeSecretRows(allocator, output.secrets);

    const data = try http_response.makeSecretListResponse(allocator, output.secrets);
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = nalarcore.sqlite;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

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

    try migration.Migration101CreateWorkspaceSecrets.up(&db, testing.allocator);
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES
        \\  ('sec_a', 'ws_1', 'APPLE', 'v_apple_do_not_leak'),
        \\  ('sec_b', 'ws_1', 'ZEBRA', 'v_zebra_do_not_leak'),
        \\  ('sec_c', 'ws_2', 'MANGO', 'v_mango_do_not_leak')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "useCase: an empty workspace_id is WorkspaceIdRequired, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "" }),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
}

test "useCase: returns one workspace's secrets, ordered by name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer secrets_store.freeSecretRows(alloc, output.secrets);

    try testing.expectEqual(@as(usize, 2), output.secrets.len);
    try testing.expectEqualStrings("APPLE", output.secrets[0].name);
    try testing.expectEqualStrings("ZEBRA", output.secrets[1].name);
    try testing.expectEqualStrings("sec_a", output.secrets[0].id);
    try testing.expect(output.secrets[0].created_at.len > 0);
    try testing.expect(output.secrets[0].updated_at.len > 0);
}

test "useCase: a workspace with no secrets lists empty rather than erroring" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_nobody" });
    defer secrets_store.freeSecretRows(alloc, output.secrets);
    try testing.expectEqual(@as(usize, 0), output.secrets.len);
}

test "useCase: never returns another workspace's secrets" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const ws1 = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer secrets_store.freeSecretRows(alloc, ws1.secrets);
    const ws2 = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2" });
    defer secrets_store.freeSecretRows(alloc, ws2.secrets);

    // No leak in either direction, and no "empty because mis-scoped" false
    // negative in the one workspace that does have secrets.
    try testing.expectEqual(@as(usize, 2), ws1.secrets.len);
    try testing.expectEqual(@as(usize, 1), ws2.secrets.len);
    try testing.expectEqualStrings("MANGO", ws2.secrets[0].name);
}

test "useCase: a failed query is a 500 DB error, never a silent empty list" {
    // Degrading a read failure into `[]` is what makes "nothing to show" and
    // "we could not look" indistinguishable, so the mapping is pinned.
    try testing.expectEqual(@as(u16, 500), statusFor(error.QueryFailed));
    try testing.expectEqualStrings("DB error", messageFor(error.QueryFailed));
    try testing.expectEqual(@as(u16, 500), statusFor(error.OutOfMemory));
}

test "the list read cannot select a value column: asserted on the SQL text" {
    // Asserted on the source rather than on a result set. A result can only
    // show that the column is absent today; the regression this guards is
    // someone helpfully adding `value` to the shared read projection later,
    // at which point a result-set assertion would have to be rewritten
    // along with the leak.
    const store_src = @embedFile("../agentic_loop/secrets_store.zig");

    const start = std.mem.indexOf(u8, store_src, "const SELECT_COLUMNS =") orelse
        return error.SelectColumnsNotFound;
    // The declaration runs to the first blank line, so the doc comment that
    // follows (which necessarily talks about `value`) is not in the window.
    const end = std.mem.indexOf(u8, store_src[start..], "\n\n") orelse
        return error.SelectColumnsUnterminated;
    const projection = store_src[start..][0..end];

    // Positive check first: an empty or mislocated window would otherwise
    // pass the absence check below for the wrong reason.
    try testing.expect(std.mem.indexOf(u8, projection, "FROM workspace_secrets") != null);
    try testing.expect(std.mem.indexOf(u8, projection, "value") == null);
}

test "the list response body carries no stored value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer secrets_store.freeSecretRows(alloc, output.secrets);

    const json = try http_response.makeSecretListResponse(alloc, output.secrets);
    defer alloc.free(json);

    // Names and timestamps travel; credentials do not.
    try testing.expect(std.mem.indexOf(u8, json, "APPLE") != null);
    try testing.expect(std.mem.indexOf(u8, json, "v_apple_do_not_leak") == null);
    try testing.expect(std.mem.indexOf(u8, json, "v_zebra_do_not_leak") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
}

// ─── Static route contracts for the whole secrets group ─────────────────
//
// Lives here, in the group's entry-point handler, rather than in a
// standalone `secrets_routes_test.zig` — this repo keeps an impl file and
// its tests in ONE file, and `documents_list.zig` owns the identical
// contract for the documents group.
//
// `matchRoute` walks routes in REGISTRATION ORDER and returns on the first
// hit (router.zig:614), so registration order is the shadowing axis and a
// comment is not a check. Asserted against `main.zig` as text here, and
// over a real wire by the Python functional harness
// (`tests/functional/harness.py`).

fn mainSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/main.zig",
        allocator,
        .limited(4 * 1024 * 1024),
    );
}

const REQUIRED_ROUTES = [_][]const u8{
    "authed.get(\"/api/workspaces/:workspace_id/secrets\"",
    "authed.post(\"/api/workspaces/:workspace_id/secrets\"",
    "authed.patch(\"/api/workspaces/:workspace_id/secrets/:secret_id\"",
    "authed.delete(\"/api/workspaces/:workspace_id/secrets/:secret_id\"",
};

test "secrets routes: all four verbs are registered in main.zig" {
    const alloc = testing.allocator;
    const raw = try mainSource(alloc);
    defer alloc.free(raw);

    var missing: usize = 0;
    for (REQUIRED_ROUTES) |needle| {
        if (std.mem.indexOf(u8, raw, needle) == null) {
            missing += 1;
            std.debug.print("missing secrets route registration: {s}\n", .{needle});
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "secrets routes: the two literal routes precede the two :secret_id routes" {
    const alloc = testing.allocator;
    const raw = try mainSource(alloc);
    defer alloc.free(raw);

    // Byte offsets, not a reviewer's eye. A `:secret_id` route registered
    // first would capture `/secrets` — a POST to the collection would land
    // on the PATCH/DELETE handler, and every create would fail at runtime
    // with a 404 no useCase test can see.
    const list_at = std.mem.indexOf(u8, raw, REQUIRED_ROUTES[0]) orelse
        return error.ListRouteMissing;
    const create_at = std.mem.indexOf(u8, raw, REQUIRED_ROUTES[1]) orelse
        return error.CreateRouteMissing;
    const patch_at = std.mem.indexOf(u8, raw, REQUIRED_ROUTES[2]) orelse
        return error.PatchRouteMissing;
    const delete_at = std.mem.indexOf(u8, raw, REQUIRED_ROUTES[3]) orelse
        return error.DeleteRouteMissing;

    try testing.expect(list_at < patch_at);
    try testing.expect(list_at < delete_at);
    try testing.expect(create_at < patch_at);
    try testing.expect(create_at < delete_at);
}

test "secrets handlers are re-exported from http_handlers/mod.zig" {
    const mod_src = @embedFile("mod.zig");
    for ([_][]const u8{
        "secretsListHandler",
        "secretsCreateHandler",
        "secretsUpdateHandler",
        "secretsDeleteHandler",
    }) |name| {
        try testing.expect(std.mem.indexOf(u8, mod_src, name) != null);
    }
}
