//! Shared auth helpers for opt-in `--auth` mode.
//!
//! `users` (Migration 077) stores identity; `auth_sessions` (Migration 089)
//! stores one row per active `nalar_session` cookie (SHA-256 hash -> user).
//! When `--auth` is off, middleware passes everything through.

const std = @import("std");
const nalarcore = @import("nalarcore");

pub const cookie_name = "nalar_session";
pub const session_max_age_secs: u32 = 30 * 24 * 3600; // 30 days

/// Paths that never require auth even when `--auth` is on.
/// Exact match only (not prefix) to avoid accidentally opening /api/authX.
pub fn isAuthExempt(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/api/auth/login")) return true;
    if (std.mem.eql(u8, path, "/api/auth/logout")) return true;
    if (std.mem.eql(u8, path, "/health")) return true;
    if (std.mem.eql(u8, path, "/api/health")) return true;
    return false;
}

/// Extract `nalar_session` cookie value. Returns null for missing,
/// empty, or malformed Cookie headers (empty is treated as absent,
/// never as a value — see the `""`-as-value pitfall).
pub fn parseSessionToken(headers: anytype) ?[]const u8 {
    const cookie = headers.get("Cookie") orelse headers.get("cookie") orelse return null;
    if (cookie.len == 0) return null;
    var it = std.mem.splitScalar(u8, cookie, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len <= cookie_name.len + 1) continue;
        if (!std.mem.startsWith(u8, trimmed, cookie_name ++ "=")) continue;
        const val = std.mem.trim(u8, trimmed[cookie_name.len + 1 ..], " \t\"");
        if (val.len == 0) return null;
        // Basic sanity: opaque hex token we issue is 64 chars.
        // Accept anything non-empty here; DB lookup is the real gate.
        return val;
    }
    return null;
}

/// Hex-encode SHA-256(token) into a 64-char lowercase string.
pub fn sha256Hex(token: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

pub const SessionLookup = struct {
    user_id: []const u8,
    email: []const u8,
    name: []const u8,
    role: []const u8,
};

/// Validate a raw cookie token against `auth_sessions` + `users`.
/// Returns null when: token empty, unknown hash, expired, or user inactive.
/// Caller owns the duped slices in the returned struct (free with allocator).
pub fn lookupSession(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    raw_token: []const u8,
) ?SessionLookup {
    if (raw_token.len == 0) return null;
    var hash_hex: [64]u8 = undefined;
    sha256Hex(raw_token, &hash_hex);

    var q = db.query(allocator,
        \\SELECT s.user_id, u.email, COALESCE(u.name, ''), u.role
        \\FROM auth_sessions s JOIN users u ON u.id = s.user_id
        \\WHERE s.token_hash = ? AND s.expires_at > datetime('now') AND u.is_active = 1
    , &[_][]const u8{hash_hex[0..]}) catch return null;
    defer q.deinit();
    const row = q.next() catch return null;
    const r = row orelse return null;
    defer r.deinit(allocator);
    if (r.values.len < 4) return null;
    return SessionLookup{
        .user_id = allocator.dupe(u8, r.values[0]) catch return null,
        .email = allocator.dupe(u8, r.values[1]) catch return null,
        .name = allocator.dupe(u8, r.values[2]) catch return null,
        .role = allocator.dupe(u8, r.values[3]) catch return null,
    };
}

pub fn freeSessionLookup(allocator: std.mem.Allocator, s: SessionLookup) void {
    allocator.free(s.user_id);
    allocator.free(s.email);
    allocator.free(s.name);
    allocator.free(s.role);
}

// =====================================================================
// Per-request owner resolution — the input to per-user row isolation.
// =====================================================================

/// Sentinel owner id: Migration 077's backfill target for every row that
/// predates `--auth`, and the answer `resolveRequestUserId` gives whenever
/// identity cannot be established. Because legacy rows carry this same
/// value, such rows stay visible and scoping is a no-op in auth-off mode.
pub const system_user_id = "user_system";

/// SQL predicate for "rows that `alias` may see": the shared legacy bucket
/// (NULL / empty / the system sentinel) plus rows owned by the viewer,
/// whose id the caller binds as the next `?` parameter.
///
/// Compile-time formatted, so it concatenates into a constant SQL string
/// at no runtime cost:
///   `"SELECT ... WHERE " ++ ownerVisibilityClause("w") ++ " AND ..."`
///
/// Sharing the legacy bucket is deliberate (user decision 2026-09-25):
/// turning `--auth` on must not hide the machine owner's existing data.
/// Rows written after isolation lands always carry a real owner, so the
/// shared bucket only ever shrinks.
pub fn ownerVisibilityClause(comptime alias: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "({s}.user_id IS NULL OR {s}.user_id = '' OR {s}.user_id = '{s}' OR {s}.user_id = ?)",
        .{ alias, alias, alias, system_user_id, alias },
    );
}

/// True when `user_id` is the shared/legacy bucket rather than a real
/// owner. Callers use this to detect (and log) writes that fell back to
/// the sentinel while `--auth` was on — a mis-scoping signal.
pub fn isSharedOwner(user_id: []const u8) bool {
    return user_id.len == 0 or std.mem.eql(u8, user_id, system_user_id);
}

/// True when `workspace_id` exists AND the given owner may see it.
///
/// This is the predicate behind the middleware choke point for every route
/// whose path carries a `:workspace_id` (`/api/workspaces/:workspace_id/items…`
/// and its kanban/design/agent/routine children). Centralising it means a
/// newly added child route cannot forget the check.
pub fn canSeeWorkspace(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    workspace_id: []const u8,
    owner: []const u8,
) bool {
    if (workspace_id.len == 0) return false;
    var q = db.query(
        allocator,
        "SELECT 1 FROM workspaces WHERE id = ? AND " ++ comptime ownerVisibilityClause("workspaces"),
        &[_][]const u8{ workspace_id, owner },
    ) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    if (row) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

/// Resolve the owner id for the current request, server-side.
///
/// The ONLY accepted source is the `nalar_session` cookie — never a body
/// field, query param, or header, all of which the client controls.
///
/// - auth disabled                            -> `system_user_id`
/// - cookie missing / invalid / expired / inactive user -> `system_user_id`
/// - valid session                            -> that user's `users.id`
///
/// Note the deliberate fallback for the middle case: an unauthenticated
/// request in auth-on mode keeps seeing the shared legacy bucket, exactly
/// what it saw before isolation existed. It never becomes a real user.
///
/// Returns an owned slice — free it with `allocator.free`.
pub fn resolveRequestUserId(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    auth_enabled: bool,
    headers: anytype,
) ![]const u8 {
    if (!auth_enabled) return allocator.dupe(u8, system_user_id);
    const token = parseSessionToken(headers) orelse return allocator.dupe(u8, system_user_id);
    const sess = lookupSession(allocator, db, token) orelse return allocator.dupe(u8, system_user_id);
    // Keep only the owner id; the rest of the identity is not needed here.
    allocator.free(sess.email);
    allocator.free(sess.name);
    allocator.free(sess.role);
    return sess.user_id;
}

/// Verify a password against a stored `users.password_hash`.
/// Sentinel `!disabled` (user_system) always fails. Supports bcrypt
/// hashes; any other format fails closed.
pub fn verifyPassword(stored_hash: []const u8, password: []const u8) bool {
    if (stored_hash.len == 0 or password.len == 0) return false;
    if (std.mem.eql(u8, stored_hash, "!disabled")) return false;
    std.crypto.pwhash.bcrypt.strVerify(stored_hash, password, .{ .silently_truncate_password = true }) catch return false;
    return true;
}

/// Hash a password with bcrypt for storage in `users.password_hash`.
/// Returns an owned slice.
pub fn hashPassword(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]u8 {
    var out_buf: [256]u8 = undefined;
    const hash_slice = try std.crypto.pwhash.bcrypt.strHash(password, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &out_buf, io);
    return allocator.dupe(u8, hash_slice);
}

/// Build a `Set-Cookie` value for the session cookie.
pub fn setCookieValue(allocator: std.mem.Allocator, raw_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}", .{ cookie_name, raw_token, session_max_age_secs });
}

pub fn clearCookieValue(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0", .{cookie_name});
}

// =====================================================================
// Tests (in-memory SQLite via useCase-adjacent helpers is covered in
// auth_login_test; here we test pure helpers with no DB).
// =====================================================================

test "isAuthExempt allows login/logout/health only" {
    try std.testing.expect(isAuthExempt("/api/auth/login"));
    try std.testing.expect(isAuthExempt("/api/auth/logout"));
    try std.testing.expect(isAuthExempt("/health"));
    try std.testing.expect(isAuthExempt("/api/health"));
    try std.testing.expect(!isAuthExempt("/api/workspaces"));
    try std.testing.expect(!isAuthExempt("/api/auth/me"));
    try std.testing.expect(!isAuthExempt("/api/auth/loginX"));
}

test "parseSessionToken handles empty as absent" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(parseSessionToken(m) == null);
    try m.put("Cookie", "");
    try std.testing.expect(parseSessionToken(m) == null);
    try m.put("Cookie", "nalar_session=");
    try std.testing.expect(parseSessionToken(m) == null);
    try m.put("Cookie", "other=1; nalar_session=abc123; x=2");
    const v = parseSessionToken(m) orelse return error.Missing;
    try std.testing.expectEqualStrings("abc123", v);
}

test "sha256Hex is stable and lowercase hex" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    sha256Hex("hello", &a);
    sha256Hex("hello", &b);
    try std.testing.expectEqualSlices(u8, &a, &b);
    for (a) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
}

test "verifyPassword rejects sentinel and empty" {
    try std.testing.expect(!verifyPassword("!disabled", "anything"));
    try std.testing.expect(!verifyPassword("", "x"));
    try std.testing.expect(!verifyPassword("$2b$10$xxx", ""));
}

test "ownerVisibilityClause embeds the shared bucket and a bound viewer" {
    const sql = ownerVisibilityClause("w");
    try std.testing.expect(std.mem.indexOf(u8, sql, "(w.user_id IS NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "w.user_id = ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "w.user_id = 'user_system'") != null);
    // The viewer's id is always the trailing bind parameter.
    try std.testing.expect(std.mem.endsWith(u8, sql, "w.user_id = ?)"));
    // And the alias is honoured (callers use real table aliases).
    const h = ownerVisibilityClause("h");
    try std.testing.expect(std.mem.indexOf(u8, h, "h.user_id IS NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "w.") == null);
}

test "isSharedOwner flags the empty and sentinel ids only" {
    try std.testing.expect(isSharedOwner(""));
    try std.testing.expect(isSharedOwner(system_user_id));
    try std.testing.expect(!isSharedOwner("user_1786000000000"));
}

test "resolveRequestUserId falls back to the sentinel without identity" {
    // Both the auth-off path and the auth-on-with-no-cookie path return
    // before the DB is touched, so an undefined db is safe here.
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();

    const off = try resolveRequestUserId(std.testing.allocator, undefined, false, headers);
    defer std.testing.allocator.free(off);
    try std.testing.expectEqualStrings(system_user_id, off);

    const on = try resolveRequestUserId(std.testing.allocator, undefined, true, headers);
    defer std.testing.allocator.free(on);
    try std.testing.expectEqualStrings(system_user_id, on);
}

test "resolveRequestUserId maps a valid cookie to the owning user" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: nalarcore.sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY,
        \\  email TEXT NOT NULL,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  password_hash TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'user',
        \\  is_active INTEGER NOT NULL DEFAULT 1
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE auth_sessions (
        \\  token_hash TEXT PRIMARY KEY,
        \\  user_id TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  expires_at DATETIME NOT NULL,
        \\  last_seen_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO users (id, email, password_hash) VALUES ('user_a', 'a@example.com', 'x')", &.{});

    const token = "deadbeef";
    var hash: [64]u8 = undefined;
    sha256Hex(token, &hash);
    try db.exec(alloc, "INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?, 'user_a', datetime('now', '+1 day'))", &[_][]const u8{hash[0..]});

    var headers = std.StringHashMap([]const u8).init(alloc);
    defer headers.deinit();
    try headers.put("Cookie", "nalar_session=deadbeef");
    const owner = try resolveRequestUserId(alloc, &db, true, headers);
    defer alloc.free(owner);
    try std.testing.expectEqualStrings("user_a", owner);

    // An unknown token is not an error — it resolves to the shared bucket.
    var anon = std.StringHashMap([]const u8).init(alloc);
    defer anon.deinit();
    try anon.put("Cookie", "nalar_session=unknown");
    const stranger = try resolveRequestUserId(alloc, &db, true, anon);
    defer alloc.free(stranger);
    try std.testing.expectEqualStrings(system_user_id, stranger);
}
