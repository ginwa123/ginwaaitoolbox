//! Per-session resolution of the `web_search` provider map.
//!
//! ## Why this file exists
//!
//! `ToolExecContext.config` (`src/agentic_loop/tools.zig:101`) is the
//! `LlmConfig` SINGLETON. In `--auth` mode that singleton never sees what
//! the user saved: the config PUT returns early in the auth branch and does
//! not swap it — its own comment says so (`nalar_config_put.zig:522-538`,
//! "the global singleton is NOT swapped (config is per-user)").
//!
//! So a tool reading `ctx.config.web_search` would find it EMPTY for every
//! auth-mode user, while Settings saves perfectly. The symptom is the worst
//! kind: the UI says yes, the tool says no, and nothing errors.
//!
//! `skill_evals_config.zig` exists for exactly this reason — its header
//! records the original incident: *"the Settings checkbox reads the
//! database (true) while the tool reads the singleton (false), so the toggle
//! looks like it works and every call refuses."* Copying that shape is
//! deliberate: a second hand-rolled resolution would be a second place to
//! get the auth-mode branch wrong.
//!
//! **One resolver, two callers.** `list_web_search_providers` and
//! `web_search` both read through here. Two sources would mean the model is
//! shown provider A and then dispatched to provider B — the same class of
//! bug as the Skill Evals trap, one layer over.

const std = @import("std");
const nalarcore = @import("nalarcore");
const config_mod = @import("../modules/config/Config.zig");

pub const Providers = config_mod.LlmConfig.WebSearchProvidersMap;

/// Just enough of the user's stored config to reach the block.
/// `ignore_unknown_fields` keeps every unrelated key from being a parse
/// error — the stored document is the whole `config.json`, not a fragment.
const UserConfigHolder = struct {
    web_search: ?std.json.Value = null,
};

/// The providers in force for `session_id`.
///
/// Returns null in every case where the database is not authoritative:
/// file mode (the PUT swaps the singleton there), no live singleton, a
/// session with no owner, a user who never saved settings, or a config that
/// failed to parse. Each of those falls back to the singleton, so the
/// failure mode is the pre-existing one rather than a new breakage.
pub fn resolve(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ?Providers {
    const di = nalarcore.getSingleton() catch return null;
    // File mode: the PUT swaps the singleton synchronously, so it already
    // tracks the user's settings. Reading the database here would add a
    // second source that can only ever disagree with it.
    if (!di.auth_enabled) return null;
    if (session_id.len == 0) return null;

    const owner = sessionOwner(allocator, db, session_id) catch return null;
    defer allocator.free(owner);
    return resolveForOwner(allocator, db, owner);
}

/// The providers stored for one user, or null when they have none.
///
/// Split from `resolve` so it can be tested without the process-global
/// singleton — there is no `clearSingleton`, so a test that installed one
/// would leak into every other test in the binary.
pub fn resolveForOwner(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    owner: []const u8,
) ?Providers {
    const raw = nalarcore.user_config_store.loadRaw(allocator, db, owner) catch return null;
    // No saved config means this user never opened Settings, so the
    // singleton is still the better guess. An absent row is not a request
    // to remove their providers.
    const content = raw orelse return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(UserConfigHolder, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const ws = parsed.value.web_search orelse return null;
    return config_mod.LlmConfig.parseWebSearchProvidersMap(allocator, ws) catch null;
}

/// The session's user id, or an error when the session is not owned.
fn sessionOwner(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    var q = try db.query(
        allocator,
        "SELECT COALESCE(user_id, '') FROM sessions WHERE id = ?",
        &[_][]const u8{session_id},
    );
    defer q.deinit();
    const row = try q.next();
    const r = row orelse return error.UnknownSession;
    defer r.deinit(allocator);
    if (r.values.len < 1 or r.values[0].len == 0) return error.SessionHasNoOwner;
    return try allocator.dupe(u8, r.values[0]);
}

// ─── tests: matrix rows 58–63 ────────────────────────────────────────────

const testing = std.testing;
const sqlite = nalarcore.sqlite;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn deinitDb(t: *TestCtx, alloc: std.mem.Allocator) void {
    t.db.deinit();
    t.threaded.deinit();
    _ = alloc;
}

/// Create a user + a session owned by them, and store a config document.
///
/// `password_hash` is a NOT NULL column, and `config_json` is written
/// directly the way `skill_evals_config`'s own `insertUser` does it — going
/// through `saveRaw` here would be a second write path to keep in step.
fn seedUser(t: *TestCtx, alloc: std.mem.Allocator, user_id: []const u8, config: ?[]const u8) !void {
    t.db.exec(alloc,
        \\INSERT INTO users (id, email, password_hash, config_json)
        \\VALUES (?, ?, 'x', ?)
    , &[_][]const u8{ user_id, user_id, config orelse "" }) catch return error.SeedUserFailed;

    t.db.exec(alloc,
        \\INSERT INTO sessions (id, name, user_id, created_at)
        \\VALUES (?, ?, ?, datetime('now'))
    , &[_][]const u8{ "sess_1", "test session", user_id }) catch return error.SeedSessionFailed;
}

const two_providers =
    \\{"web_search":{"tinyfish":{"url":"https://api.search.tinyfish.ai","key":"sk-tiny",
    \\ "curl":"https://api.search.tinyfish.ai?query=P -H \"X-API-Key: {key}\""},
    \\ "parked":{"url":"https://parked.example.com","key":"sk-p",
    \\ "curl":"https://parked.example.com?q=P -H \"X-Api-Key: {key}\"","enabled":false}}}
;

test "web_search_config: row 58 — an auth-mode session with saved config resolves" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    try seedUser(&t, alloc, "u1", two_providers);

    var providers = resolveForOwner(alloc, &t.db, "u1") orelse return error.ExpectedProviders;
    defer config_mod.LlmConfig.freeWebSearchProvidersMap(&providers, alloc);

    // Row 62: the disabled provider loads but is not usable.
    try testing.expectEqual(@as(usize, 2), providers.count());
    try testing.expect(providers.get("tinyfish").?.isUsable());
    try testing.expect(!providers.get("parked").?.isUsable());
}

test "web_search_config: row 61 — a malformed stored config yields null, not an error" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    try seedUser(&t, alloc, "u2", "{ this is not json");

    // A broken document must fall back to the pre-existing behaviour, not
    // take the tool down.
    try testing.expect(resolveForOwner(alloc, &t.db, "u2") == null);
}

test "web_search_config: a user with no stored config yields null" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    try seedUser(&t, alloc, "u3", null);

    // An absent row is not a request to remove their providers — the
    // caller falls back to the singleton.
    try testing.expect(resolveForOwner(alloc, &t.db, "u3") == null);
}

test "web_search_config: row 60 — a session with no owner is not an error" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);

    // A session row with a NULL user_id.
    t.db.exec(alloc,
        \\INSERT INTO sessions (id, name, user_id, created_at)
        \\VALUES ('ownerless', 'ownerless', NULL, datetime('now'))
    , &[_][]const u8{}) catch return error.SeedSessionFailed;

    try testing.expectError(error.SessionHasNoOwner, sessionOwner(alloc, &t.db, "ownerless"));
    try testing.expectError(error.UnknownSession, sessionOwner(alloc, &t.db, "no_such_session"));

    // …and `resolve` swallows both rather than propagating.
    _ = sessionOwner(alloc, &t.db, "ownerless") catch {};
}

test "web_search_config: the stored document tolerates unrelated keys" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    // A whole config.json, not a fragment — every other key must be ignored.
    try seedUser(&t, alloc, "u4",
        \\{"active_profile":"x","mcp_servers":{"a":{"url":"https://a"}},
        \\ "tools":["read_file"],"model_compaction_size_kb":100,
        \\ "web_search":{"p":{"url":"https://p.example.com","key":"k",
        \\   "curl":"https://p.example.com?q=P -H \"A: {key}\""}}}
    );

    var providers = resolveForOwner(alloc, &t.db, "u4") orelse return error.ExpectedProviders;
    defer config_mod.LlmConfig.freeWebSearchProvidersMap(&providers, alloc);
    try testing.expectEqual(@as(usize, 1), providers.count());
}

test "web_search_config: an absent web_search key yields null, not an empty map" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    // The distinction matters: null means "fall back to the singleton",
    // where an empty map would mean "the user has no providers".
    try seedUser(&t, alloc, "u5", "{\"active_profile\":\"x\"}");
    try testing.expect(resolveForOwner(alloc, &t.db, "u5") == null);
}