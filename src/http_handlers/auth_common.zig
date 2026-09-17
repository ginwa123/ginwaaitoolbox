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
