//! Per-session `LlmConfig` resolution for opt-in `--auth` mode.
//!
//! Why this exists: under `--auth` each user's LLM config (profiles,
//! `active_profile`, tools checklist, compaction knobs, MCP servers — the
//! same JSON shape as `config.json`) lives in `users.config_json`
//! (Migration 092) and `config.json` is documented as ignored. The
//! *Settings* handlers honour that. The `LlmConfig` singleton does not:
//! it is loaded from `config.json` once at boot and is never rewritten in
//! auth mode — `pabrik_config_put.zig` returns early after persisting to
//! the database, because one global pointer cannot serve per-user config
//! (the user who saved last would win for everybody).
//!
//! So every runtime reader of `getLlmConfig(di)` kept describing the
//! on-disk file. A `--auth` user's saved model / `api_key` / `base_url` /
//! `url_style` / tools checklist were silently ignored and every chat ran
//! on `config.json`'s `active_profile`: the Settings screen read the
//! database (honest) while the turn read the singleton (wrong).
//! `skill_evals_config.zig` documents the same trap for one feature and
//! resolves it per session; this module does it for the whole `LlmConfig`.
//!
//! `null` from either entry point means "the singleton is authoritative"
//! and covers every case where the database is not: file mode (`--auth`
//! off), no singleton, a session with no owner, a user who never saved
//! settings, a corrupt row. All of them fall back to the previous
//! behaviour, so the failure mode stays the pre-existing one.
//!
//! Callers own the lifetime: pass a run/request arena (production) or
//! `deinit` both the config and its strings (tests). Do not mutate the
//! returned config — one call resolves one config and others may share it.
//!
//! THE RULE (one module, one owner): this file is the only place that decides
//! which `LlmConfig` a user-scoped read sees. Call sites use one of exactly
//! two entry points and MUST NOT hand-roll `getLlmConfig(di)` for user-scoped
//! data:
//!
//!   * `forSession` — anything that has a `sessions.id` (the workflow loop,
//!     the message and compaction read paths, the context-window cascade,
//!     the session-create profile snapshot).
//!   * `auth_common.requestUserConfig` (`http_handlers`) — request-scoped
//!     handlers that have a cookie but no session row yet (workspace/agent/
//!     kanban seeding, web status); it resolves the cookie to an owner and
//!     calls `forOwner` here, so the rule still has one implementation.
//!
//! Direct `getLlmConfig(di)` reads that legitimately stay outside:
//! boot (`main.zig`) and the Settings handlers (they read/write
//! `users.config_json` themselves). The two feature-specific narrow
//! resolvers share this module's owner lookup and full-config parse:
//! `skill_evals_config.zig` delegates to `forOwner` (its struct owns no
//! memory, so the copy is free); `web_search_config.zig` reuses
//! `sessionOwner` and keeps its narrow parse only because the providers map
//! owns heap strings tied to the full config's lifetime.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const config_mod = @import("../modules/config/Config.zig");

/// The `LlmConfig` in force for `session_id`, or null when the process-global
/// singleton should be read instead.
///
/// Requires `auth_enabled` and a session row carrying an owner — both are
/// cheap reads on the caller's hot path, and both are what makes the
/// database (not the file) the authority. The returned pointer is allocated
/// with `allocator` (an arena in production) and borrows nothing else.
pub fn forSession(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ?*config_mod.LlmConfig {
    const di = pabrikcore.getSingleton() catch return null;
    // File mode: the config PUT swaps the singleton synchronously, so it
    // already tracks the user's settings. Reading the database here would
    // add a second source that can only ever disagree with it.
    if (!di.auth_enabled) return null;
    if (session_id.len == 0) return null;

    const owner = sessionOwner(allocator, db, session_id) catch return null;
    defer allocator.free(owner);
    return forOwner(allocator, db, owner);
}

/// The `LlmConfig` stored in `users.config_json` for `owner`, or null when
/// that user has no saved config (or it cannot be used).
///
/// Split out from `forSession` so it can be tested — and called by the
/// request-scoped handlers, which already resolved the owner from the
/// session cookie — without the process-global singleton: there is no
/// `clearSingleton`, so a test that installed one would leak into every
/// other test in the binary.
///
/// No `auth_enabled` check on purpose: the caller owns that decision. A
/// non-auth caller passing the shared/system sentinel gets null (that user
/// has no row), which degrades to the singleton.
pub fn forOwner(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    owner: []const u8,
) ?*config_mod.LlmConfig {
    if (owner.len == 0) return null;
    const raw = pabrikcore.user_config_store.loadRaw(allocator, db, owner) catch return null;
    const content = raw orelse return null;
    defer allocator.free(content);
    return fromJsonText(allocator, content);
}

/// Parse one user's saved config into a heap `LlmConfig` owned by
/// `allocator`, or null on any parse failure — a corrupt row degrades to
/// the singleton rather than failing a chat turn.
///
/// The mapping is `LlmConfig.initFromJsonText`, the same one the on-disk
/// path uses, so a stored row and a `config.json` with identical bytes
/// produce identical configs (that is the whole point of the fix).
pub fn fromJsonText(
    allocator: std.mem.Allocator,
    content: []const u8,
) ?*config_mod.LlmConfig {
    if (content.len == 0) return null;
    const cfg = allocator.create(config_mod.LlmConfig) catch return null;
    cfg.* = config_mod.LlmConfig.initFromJsonText(allocator, content) catch {
        allocator.destroy(cfg);
        return null;
    };
    return cfg;
}

/// The owner of `session_id`, duped into `allocator`.
///
/// Shared helper for the narrow resolvers (`skill_evals_config.zig`,
/// `web_search_config.zig`) so all three read the same row through the same
/// query. Single source of truth for owner resolution — do not duplicate.
pub fn sessionOwner(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
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

// =====================================================================
// Tests (in-memory SQLite with the real migration chain)
// =====================================================================

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
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

fn insertUser(db: *sqlite.SqliteBackend, id: []const u8, config_json: ?[]const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO users (id, email, password_hash, config_json) VALUES (?, ?, 'h', ?)",
        &[_][]const u8{ id, id, config_json orelse "" },
    );
}

fn insertSession(db: *sqlite.SqliteBackend, id: []const u8, owner: []const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO sessions (id, name, status, user_id) VALUES (?, 's', 'active', ?)",
        &[_][]const u8{ id, owner },
    );
}

/// Free a config `fromJsonText`/`forOwner` handed out, then the pointer.
fn freeResolved(cfg: *config_mod.LlmConfig) void {
    cfg.deinit();
    testing.allocator.destroy(cfg);
}

test "forOwner: absent, empty and unknown owners degrade to the singleton" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expect(forOwner(testing.allocator, &ctx.db, "") == null);
    try insertUser(&ctx.db, "u_no_config", null);
    try testing.expect(forOwner(testing.allocator, &ctx.db, "u_no_config") == null);
    try testing.expect(forOwner(testing.allocator, &ctx.db, "u_missing") == null);
}

test "forOwner: a saved profile is what a chat turn gets" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const body =
        "{\"active_profile\":\"mine\",\"profiles_models\":{\"mine\":{\"model\":\"user-model\"," ++
        "\"base_url\":\"http://user.example/v1\",\"api_key\":\"user-key\",\"url_style\":\"openai\"}}}";
    try insertUser(&ctx.db, "u1", body);

    const cfg = forOwner(testing.allocator, &ctx.db, "u1") orelse return error.ConfigNotResolved;
    defer freeResolved(cfg);

    try testing.expectEqualStrings("mine", cfg.active_profile.?);
    const eff = cfg.resolveEffectiveProfile("mine");
    try testing.expectEqualStrings("user-model", eff.model);
    try testing.expectEqualStrings("http://user.example/v1", eff.base_url);
    try testing.expectEqualStrings("user-key", eff.api_key);
    // The same cascade the workflow calls with an EMPTY profile name must
    // also land on the user's active_profile, not on top-level defaults.
    const via_active = cfg.resolveEffectiveProfile("");
    try testing.expectEqualStrings("user-model", via_active.model);
    try testing.expectEqualStrings("user-key", via_active.api_key);
}

test "forOwner: the tools checklist comes from the user's row" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u_tools", "{\"tools\":[\"search_skills\",\"use_skill\"]}");

    const cfg = forOwner(testing.allocator, &ctx.db, "u_tools") orelse return error.ConfigNotResolved;
    defer freeResolved(cfg);

    const tools = cfg.tools orelse return error.ToolsNotParsed;
    try testing.expectEqual(@as(usize, 2), tools.len);
    try testing.expectEqualStrings("search_skills", tools[0]);
    try testing.expectEqualStrings("use_skill", tools[1]);
}

test "forOwner: a corrupt row degrades instead of failing the turn" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u_bad", "{ this is not json");
    try testing.expect(forOwner(testing.allocator, &ctx.db, "u_bad") == null);
    try testing.expect(fromJsonText(testing.allocator, "") == null);
    try testing.expect(fromJsonText(testing.allocator, "null") == null);
}

test "fromJsonText: matches the on-disk parse for identical bytes" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Same bytes in both places: the database copy must produce the same
    // config a config.json with those bytes would (that is the promise the
    // fix rests on — file mode and auth mode cannot diverge).
    const body =
        "{\"active_profile\":\"p\",\"profiles_models\":{\"p\":{\"model\":\"m\"," ++
        "\"base_url\":\"http://x/v1\",\"api_key\":\"k\"}},\"tools\":[\"used_tools\"]}";
    try insertUser(&ctx.db, "u_same", body);

    const from_db = forOwner(testing.allocator, &ctx.db, "u_same") orelse return error.ConfigNotResolved;
    defer freeResolved(from_db);
    const from_text = fromJsonText(testing.allocator, body) orelse return error.ConfigNotResolved;
    defer freeResolved(from_text);

    try testing.expectEqualStrings(from_text.model, from_db.model);
    try testing.expectEqualStrings(from_text.active_profile.?, from_db.active_profile.?);
    try testing.expectEqualStrings(
        from_text.profiles_models.get("p").?.api_key,
        from_db.profiles_models.get("p").?.api_key,
    );
    try testing.expectEqual(from_text.tools.?.len, from_db.tools.?.len);
}

test "sessionOwner: owner is read from the session, absent owner is an error" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u_owner", null);
    try insertSession(&ctx.db, "s_owned", "u_owner");
    try insertSession(&ctx.db, "s_orphan", "");

    const owner = try sessionOwner(testing.allocator, &ctx.db, "s_owned");
    defer testing.allocator.free(owner);
    try testing.expectEqualStrings("u_owner", owner);

    try testing.expectError(error.SessionHasNoOwner, sessionOwner(testing.allocator, &ctx.db, "s_orphan"));
    try testing.expectError(error.UnknownSession, sessionOwner(testing.allocator, &ctx.db, "s_missing"));
}
