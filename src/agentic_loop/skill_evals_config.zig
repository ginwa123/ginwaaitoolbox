//! Per-session resolution of the `skill_evals` block.
//!
//! Why this exists: under `--auth` every user owns a `users.config_json`
//! row, and both config handlers read and write that row and nothing else.
//! The `LlmConfig` singleton, though, is only ever rewritten by the
//! config PUT's live-reload block — which sits *after* the auth branch
//! has already returned ("Auth mode: persist to users.config_json and
//! return early"). So in auth mode the singleton keeps describing the
//! on-disk `config.json` and never sees what the user saved.
//!
//! That is the "Skill Evals are off" trap: the Settings checkbox reads
//! the database (true) while the tool reads the singleton (false), so the
//! toggle looks like it works and every call refuses.
//!
//! Swapping the singleton from the auth PUT is NOT the fix. The singleton
//! is one global pointer and auth config is per-user, so that would make
//! whichever user saved last win for everybody. Resolve the switch per
//! session instead.

const std = @import("std");
const nalarcore = @import("nalarcore");
const config_mod = @import("../modules/config/Config.zig");

/// Just enough of the user's config to reach the block.
/// `ignore_unknown_fields` keeps every unrelated key in the document from
/// being a parse error.
const UserConfigHolder = struct {
    skill_evals: config_mod.SkillEvalsJson = .{},
};

/// The `skill_evals` block in force for `session_id`, or null when
/// `ctx.config.skill_evals` is already authoritative and should be read
/// directly.
///
/// Null means "no per-user override applies" and covers every case where
/// the database is not the authority: file mode (the PUT swaps the
/// singleton there), no live singleton, a session with no owner, a user
/// who never saved settings, or a config that failed to parse. All of them
/// fall back to today's behaviour, so the failure mode is the
/// pre-existing one rather than a new breakage.
pub fn resolve(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ?config_mod.SkillEvalsConfig {
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

/// The `skill_evals` block stored for one user, or null when they have no
/// saved config at all.
///
/// Split out from `resolve` so it can be tested without the process-global
/// singleton: there is no `clearSingleton`, so a test that installed one
/// would leak into every other test in the binary.
pub fn resolveForOwner(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    owner: []const u8,
) ?config_mod.SkillEvalsConfig {
    const raw = nalarcore.user_config_store.loadRaw(allocator, db, owner) catch return null;
    // No saved config for this user means they never opened Settings, so the
    // singleton is still the better guess. An absent row is not a request to
    // switch the feature off.
    const content = raw orelse return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(UserConfigHolder, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    // `skillEvalsFromJson` turns `apply_mode` into an enum by value before
    // this returns, so `deinit` cannot free anything the caller still holds.
    return config_mod.skillEvalsFromJson(parsed.value.skill_evals);
}

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

// ─── tests ───────────────────────────────────────────────────────────────

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

fn insertUser(db: *sqlite.SqliteBackend, id: []const u8, config_json: ?[]const u8) !void {
    try db.exec(testing.allocator,
        \\INSERT INTO users (id, email, password_hash, config_json)
        \\VALUES (?, ?, 'x', ?)
    , &[_][]const u8{ id, id, config_json orelse "" });
}

test "resolveForOwner returns the block the user saved (the auth-mode trap)" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u1",
        "{\"notify_on_complete\":true,\"skill_evals\":{\"enabled\":true,\"max_skills_per_run\":3,\"fact_lease_seconds\":42}}");

    const got = resolveForOwner(testing.allocator, &ctx.db, "u1");
    try testing.expect(got != null);
    try testing.expect(got.?.enabled);
    try testing.expectEqual(@as(u32, 3), got.?.max_skills_per_run);
    try testing.expectEqual(@as(u32, 42), got.?.fact_lease_seconds);
}

test "resolveForOwner returns null for a user who never saved settings" {
    // The fallback must be the singleton, not "off": an absent row is not a
    // request to disable the feature.
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expect(resolveForOwner(testing.allocator, &ctx.db, "nobody") == null);
}

test "a saved config with no skill_evals key reads as OFF, not as an error" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u2", "{\"notify_on_complete\":true,\"mcp_servers\":[]}");

    const got = resolveForOwner(testing.allocator, &ctx.db, "u2");
    try testing.expect(got != null);
    try testing.expect(!got.?.enabled);
}

test "unrelated keys and nested objects do not break the parse" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u3",
        "{\"profiles_models\":[{\"name\":\"p\",\"models\":{\"x\":\"y\"}}],\"skill_evals\":{\"enabled\":true,\"apply_mode\":\"off\"}}");

    const got = resolveForOwner(testing.allocator, &ctx.db, "u3");
    try testing.expect(got != null);
    try testing.expect(got.?.enabled);
    try testing.expectEqual(config_mod.SkillEvalsConfig.ApplyMode.off, got.?.apply_mode);
}

test "resolve degrades to the singleton when no singleton is installed" {
    // File mode and unit-test dispatch both land here: without a live
    // singleton the caller must keep reading `ctx.config` rather than
    // silently switching the feature off.
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u4", "{\"skill_evals\":{\"enabled\":true}}");
    try testing.expect(resolve(testing.allocator, &ctx.db, "any_session") == null);
}

test "BOTH gates route through resolve - the exposure gate and the runtime gate" {
    // Two independent gates read this switch. When only one of them was
    // fixed, the tool stayed visible in tools[] (the allowlist filter has no
    // skill_evals awareness) and every call still refused - the exact symptom
    // this module exists to remove. Pin both call sites so a refactor cannot
    // silently drop either.
    const run_src = @embedFile("run_skill_eval.zig");
    const wf_src = @embedFile("workflow.zig");

    if (std.mem.indexOf(u8, run_src, "skill_evals_config.resolve(") == null) {
        std.debug.print("!! execRunSkillEval no longer resolves the per-user block !!\n", .{});
        return error.RuntimeGateNotWired;
    }
    if (std.mem.indexOf(u8, wf_src, "skill_evals_config.resolve(") == null) {
        std.debug.print("!! filterAndMergeTools no longer resolves the per-user block !!\n", .{});
        return error.ExposureGateNotWired;
    }
    // The switch must not be read off the singleton directly any more.
    if (std.mem.indexOf(u8, run_src, "ctx.config.skill_evals.enabled") != null) {
        std.debug.print("!! execRunSkillEval reads the singleton again !!\n", .{});
        return error.RuntimeGateReverted;
    }
}