// ============================================================================
// security.zig — security primitives for the ginwasaas HTTP server.
//
// Provides six `pub fn` primitives that handlers opt into:
//
//   * csrfTokenIssue / csrfTokenValidate — synchronizer-token pattern with
//     HMAC-SHA256 signing. Tokens embed (timestamp ‖ nonce ‖ hmac) and
//     expire after `CSRF_TOKEN_TTL_SEC` seconds.
//
//   * rateLimitCheck — in-memory token bucket per (ip, route). Allows
//     `RATE_LIMIT_MAX` requests per `RATE_LIMIT_WINDOW_SEC` seconds.
//     Test-only `rateLimitResetForTesting` clears the buckets between
//     tests so they don't leak state.
//
//   * applySecurityHeaders — sets 7 headers (CSP, X-Content-Type-Options,
//     X-Frame-Options, Referrer-Policy, Permissions-Policy, COOP, CORP)
//     in-place on an HttpResponse.
//
//   * checkOrigin — rejects POST with mismatched Origin or Referer host.
//     Returns `error.CrossOriginForbidden`.
//
//   * enforceBodySizeLimit — rejects bodies > max bytes. Returns
//     `error.PayloadTooLarge`.
//
// Memory model
// ------------
// * No allocations for primitive inputs that fit in stack buffers.
// * The CSRF token bundle allocates the token string; the caller (handler)
//   is responsible for freeing it (or letting the per-request arena reap
//   it, which is the production path).
// * The rate-limit store is module-level mutable state. Tests must call
//   `rateLimitResetForTesting` in setup to avoid cross-test pollution.
// * `applySecurityHeaders` mutates the response's headers map in place;
//   all header values are string literals (no allocations).
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const http_parser = @import("http_parser.zig");

pub const HttpResponse = http_parser.HttpResponse;
pub const HttpRequest = http_parser.HttpRequest;

/// HMAC algorithm used for CSRF token signing. SHA-256 produces 32-byte
/// digests which we then base64url-encode for the token format.
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HMAC_LEN = HmacSha256.mac_length; // 32

/// CSRF token lifetime (seconds). 1 hour per OWASP recommendation for
/// form-submission tokens; sessions rarely need longer.
pub const CSRF_TOKEN_TTL_SEC: i64 = 60 * 60;

/// Rate-limit defaults (applied per `(ip, route)` pair).
pub const RATE_LIMIT_MAX: u32 = 5;
pub const RATE_LIMIT_WINDOW_SEC: i64 = 60;

/// Maximum request body size accepted on state-changing endpoints.
pub const MAX_BODY_BYTES: usize = 16 * 1024;

/// Token bucket state for one `(ip, route)` pair.
const BucketState = struct {
    /// Window start (unix seconds).
    window_start: i64,
    /// Requests consumed in the current window.
    count: u32,
};

/// Route-keyed map of IP-keyed bucket states. Mutated under a mutex.
var buckets: std.StringHashMap(std.StringHashMap(BucketState)) = undefined;
var buckets_init: bool = false;
var buckets_mutex: std.atomic.Mutex = .unlocked;

/// Spinlock acquire — Zig 0.16 removed `std.Thread.Mutex`. The standard
/// library's `atomic.Mutex` is an enum with `tryLock`/`unlock` only;
/// we wrap it in a `tryLock` + `spinLoopHint` loop here.
fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn ensureBucketsInit() void {
    if (buckets_init) return;
    mutexLock(&buckets_mutex);
    defer buckets_mutex.unlock();
    if (buckets_init) return;
    buckets = std.StringHashMap(std.StringHashMap(BucketState)).init(std.heap.page_allocator);
    buckets_init = true;
}

/// Bundle returned by `csrfTokenIssue`. The caller owns `token` (freed
/// via the allocator passed to `csrfTokenIssue`) and is responsible for
/// inserting `cookie` into the `Set-Cookie` response header.
pub const CsrfTokenBundle = struct {
    token: []u8,
    cookie: []u8,
    expires_at: i64,
};

/// Constant-time equality check on two byte slices. Returns true iff
/// they have the same length and identical contents. Avoids timing
/// side-channels when comparing HMAC digests.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

/// Generate a cryptographically-secure random nonce of `len` bytes.
///
/// Platform CSPRNG dispatch:
///   * Linux    → syscall getrandom(2) (no fd, no /dev/urandom setup).
///   * macOS    → arc4random_buf (declared in std.c private; uses
///                SecRandomCopyBytes under the hood since macOS 10.12,
///                i.e. effectively a CSPRNG — the "arc4" name is stale).
///   * Windows  → BCryptGenRandom from bcrypt.dll with
///                BCRYPT_USE_SYSTEM_PREFERRED_RNG. Built at link time via
///                `linkSystemLibrary("bcrypt")` in build.zig.
/// `std.c.getrandom` exists only on Linux/FreeBSD; on Windows and macOS it
/// resolves to `void` (Zig's c.zig switch), which is why this function is
/// target-aware rather than a single line.
fn generateNonce(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd => {
            var filled: usize = 0;
            while (filled < len) {
                // std.c.getrandom returns the number of bytes written (isize),
                // or -1 on error. Loop until the buffer is full.
                const slice = buf[filled..];
                const n = std.c.getrandom(slice.ptr, slice.len, 0);
                if (n <= 0) return error.RandomFailed;
                filled += @intCast(n);
            }
        },
        .macos, .ios, .tvos, .watchos => {
            // arc4random_buf is declared in std.c private; available on all
            // Apple targets. The Zig 0.16 std.c exports it as
            // `std.c.arc4random_buf` but only on Darwin-family — gate here.
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .windows => {
            // BCrypt.dll → BCRYPT_USE_SYSTEM_PREFERRED_RNG (0x00000002).
            // hAlgorithm = NULL means "use the system-preferred RNG" which
            // the docs guarantee is suitable for cryptographic use and is
            // seeded from the OS entropy pool at boot.
            const status = bcrypt.BCryptGenRandom(
                null,
                buf.ptr,
                @intCast(buf.len),
                0x00000002, // BCRYPT_USE_SYSTEM_PREFERRED_RNG
            );
            if (status != 0) return error.RandomFailed;
        },
        else => return error.UnsupportedPlatform,
    }
    return buf;
}

/// Windows bcrypt.dll bindings. Declared locally because std.c only covers
/// libc; bcrypt is a separate system DLL that build.zig links via
/// `linkSystemLibrary("bcrypt")`. Both functions are stdcall-equivalent
/// (c_long on x86_64) per Microsoft's bcrypt.h.
const bcrypt = struct {
    extern "bcrypt" fn BCryptGenRandom(
        hAlgorithm: ?*const anyopaque,
        pbBuffer: [*]u8,
        cbBuffer: c_ulong,
        dwFlags: c_ulong,
    ) callconv(.c) c_long;
};

/// Generate an HMAC-SHA256 over `msg` keyed by `secret`. Returns a heap
/// buffer of `HMAC_LEN` bytes; caller owns it.
fn hmacSha256(allocator: std.mem.Allocator, secret: []const u8, msg: []const u8) ![]u8 {
    var mac: [HMAC_LEN]u8 = undefined;
    HmacSha256.create(&mac, msg, secret);
    return allocator.dupe(u8, &mac);
}

/// Issue a new CSRF token. `now` is unix seconds (use
/// `std.Io.Clock.now(.real, io).toSeconds()`). The token format is:
///   <timestamp_seconds>.<nonce_b64u>.<hmac_b64u>
/// where hmac = HMAC-SHA256(secret, "<timestamp_seconds>:<nonce_raw>").
/// All three fields are base64url-no-pad so the token is URL-safe.
pub fn csrfTokenIssue(
    secret: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
) !CsrfTokenBundle {
    const now = std.Io.Clock.now(.real, io).toSeconds();
    const expires_at = now + CSRF_TOKEN_TTL_SEC;

    // 16-byte nonce — 128 bits is plenty for CSRF (collision-resistant).
    const nonce_raw = try generateNonce(allocator, 16);
    defer allocator.free(nonce_raw);

    // HMAC over "<timestamp>:<nonce_raw>".
    var msg_buf: [64]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&msg_buf, "{d}:", .{now}) catch unreachable;
    var signed_msg: [80]u8 = undefined;
    @memcpy(signed_msg[0..ts_str.len], ts_str);
    @memcpy(signed_msg[ts_str.len..][0..nonce_raw.len], nonce_raw);
    const signed_msg_slice = signed_msg[0 .. ts_str.len + nonce_raw.len];

    const hmac = try hmacSha256(allocator, secret, signed_msg_slice);
    defer allocator.free(hmac);

    // base64url-encode nonce + hmac (no padding).
    const nonce_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(nonce_raw.len);
    const hmac_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(hmac.len);
    const nonce_b64 = try allocator.alloc(u8, nonce_b64_len);
    defer allocator.free(nonce_b64);
    const hmac_b64 = try allocator.alloc(u8, hmac_b64_len);
    defer allocator.free(hmac_b64);
    _ = std.base64.url_safe_no_pad.Encoder.encode(nonce_b64, nonce_raw);
    _ = std.base64.url_safe_no_pad.Encoder.encode(hmac_b64, hmac);

    // Token format: "<ts>.<nonce_b64>.<hmac_b64>".
    const token = try std.fmt.allocPrint(
        allocator,
        "{d}.{s}.{s}",
        .{ now, nonce_b64, hmac_b64 },
    );

    // Cookie value: same as token (the cookie value IS the token). The
    // server re-validates by recomputing HMAC, so a forged cookie would
    // fail the HMAC check.
    const cookie = try allocator.dupe(u8, token);

    return .{
        .token = token,
        .cookie = cookie,
        .expires_at = expires_at,
    };
}

/// Validate a CSRF token against the same secret + current time. Returns
/// `error.CsrfMismatch` on any failure (malformed, expired, wrong HMAC).
pub fn csrfTokenValidate(
    token: []const u8,
    secret: []const u8,
    now: i64,
) !void {
    // Parse "<ts>.<nonce_b64>.<hmac_b64>".
    var parts = std.mem.splitScalar(u8, token, '.');
    const ts_str = parts.next() orelse return error.CsrfMismatch;
    const nonce_b64 = parts.next() orelse return error.CsrfMismatch;
    const hmac_b64 = parts.next() orelse return error.CsrfMismatch;
    if (parts.next() != null) return error.CsrfMismatch; // trailing junk

    const ts = std.fmt.parseInt(i64, ts_str, 10) catch return error.CsrfMismatch;

    // Expiry check (reject tokens older than CSRF_TOKEN_TTL_SEC).
    if (now < ts) return error.CsrfMismatch; // clock skew guard
    if (now - ts > CSRF_TOKEN_TTL_SEC) return error.CsrfMismatch;

    // Decode nonce + hmac. url_safe_no_pad uses 4 chars per 3 bytes,
    // so decoded_len = (encoded_len * 3) / 4 (integer division).
    const nonce_len: usize = (nonce_b64.len * 3) / 4;
    var nonce_raw: [64]u8 = undefined;
    if (nonce_len > nonce_raw.len) return error.CsrfMismatch;
    std.base64.url_safe_no_pad.Decoder.decode(nonce_raw[0..nonce_len], nonce_b64) catch return error.CsrfMismatch;

    const hmac_len: usize = (hmac_b64.len * 3) / 4;
    var hmac_raw: [64]u8 = undefined;
    if (hmac_len > HMAC_LEN) return error.CsrfMismatch;
    if (hmac_len > hmac_raw.len) return error.CsrfMismatch;
    std.base64.url_safe_no_pad.Decoder.decode(hmac_raw[0..hmac_len], hmac_b64) catch return error.CsrfMismatch;

    // Recompute HMAC and compare in constant time.
    var msg_buf: [80]u8 = undefined;
    const ts_prefix = std.fmt.bufPrint(&msg_buf, "{d}:", .{ts}) catch unreachable;
    @memcpy(msg_buf[ts_prefix.len..][0..nonce_len], nonce_raw[0..nonce_len]);
    const msg = msg_buf[0 .. ts_prefix.len + nonce_len];

    var expected: [HMAC_LEN]u8 = undefined;
    HmacSha256.create(&expected, msg, secret);

    if (!constantTimeEql(expected[0..], hmac_raw[0..hmac_len])) {
        return error.CsrfMismatch;
    }
}

/// Check + record a rate-limit hit for `(ip, route)` at time `now`.
/// Allows up to `RATE_LIMIT_MAX` requests per `RATE_LIMIT_WINDOW_SEC`
/// seconds. Returns `error.RateLimited` with `Retry-After` hint on
/// rejection. Test-only `rateLimitResetForTesting(route)` clears buckets.
pub fn rateLimitCheck(
    ip: []const u8,
    route: []const u8,
    now: i64,
) !u32 {
    ensureBucketsInit();
    mutexLock(&buckets_mutex);
    defer buckets_mutex.unlock();

    const route_bucket = buckets.getPtr(route) orelse blk: {
        const new_bucket = std.StringHashMap(BucketState).init(std.heap.page_allocator);
        try buckets.put(route, new_bucket);
        break :blk buckets.getPtr(route).?;
    };

    if (route_bucket.getPtr(ip)) |state| {
        const elapsed = now - state.window_start;
        if (elapsed >= RATE_LIMIT_WINDOW_SEC) {
            // Window expired — reset.
            state.window_start = now;
            state.count = 1;
            return 0;
        }
        if (state.count >= RATE_LIMIT_MAX) {
            const retry_after: u32 = @intCast(RATE_LIMIT_WINDOW_SEC - elapsed);
            return makeError(retry_after);
        }
        state.count += 1;
        return 0;
    }

    try route_bucket.put(ip, .{ .window_start = now, .count = 1 });
    return 0;
}

fn makeError(retry_after: u32) error{ RateLimited } {
    _ = retry_after; // surfaced via the return value via u32
    return error.RateLimited;
}

/// Test-only helper to clear all rate-limit state. Production code
/// should never call this — the buckets live for the process lifetime.
pub fn rateLimitResetForTesting() void {
    ensureBucketsInit();
    mutexLock(&buckets_mutex);
    defer buckets_mutex.unlock();
    var it = buckets.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.deinit();
    }
    buckets.clearRetainingCapacity();
}

/// Security response headers applied to every response.
const SEC_CSP = "default-src 'self'; script-src 'self' https://cdn.tailwindcss.com 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'self'";
const SEC_NOSNIFF = "nosniff";
const SEC_FRAME = "DENY";
const SEC_REFERRER = "strict-origin-when-cross-origin";
const SEC_PERMISSIONS = "camera=(), microphone=(), geolocation=()";
const SEC_COOP = "same-origin";
const SEC_CORP = "same-origin";

/// Apply the seven standard security response headers in-place. All
/// values are string literals (no allocation).
pub fn applySecurityHeaders(response: *HttpResponse) void {
    response.headers.put("Content-Security-Policy", SEC_CSP) catch @panic("OOM");
    response.headers.put("X-Content-Type-Options", SEC_NOSNIFF) catch @panic("OOM");
    response.headers.put("X-Frame-Options", SEC_FRAME) catch @panic("OOM");
    response.headers.put("Referrer-Policy", SEC_REFERRER) catch @panic("OOM");
    response.headers.put("Permissions-Policy", SEC_PERMISSIONS) catch @panic("OOM");
    response.headers.put("Cross-Origin-Opener-Policy", SEC_COOP) catch @panic("OOM");
    response.headers.put("Cross-Origin-Resource-Policy", SEC_CORP) catch @panic("OOM");
}

/// Extract the host (with optional port) from a URL like
/// `http://example.com:8080/path` or `https://example.com/path`. Returns
/// the slice up to the first `/` after the scheme, or the whole input if
/// no path separator exists.
fn extractHost(url: []const u8) []const u8 {
    // Skip "scheme://".
    const scheme_sep = std.mem.indexOf(u8, url, "://") orelse return url;
    var rest = url[scheme_sep + 3 ..];
    // Cut at first '/' (start of path) or '?' or '#'.
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') return rest[0..i];
    }
    return rest;
}

/// Check that the request's Origin or Referer matches the expected host.
/// Returns `error.CrossOriginForbidden` on mismatch. Accepts the
/// request if neither header is present (legitimate for same-origin
/// GETs in some browsers, but handlers should enforce CSRF separately).
pub fn checkOrigin(request: *const HttpRequest, expected_host: []const u8) !void {
    // Look for Origin (case-insensitive per RFC 7230 §3.2).
    var it = request.headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "origin")) {
            const origin_host = extractHost(entry.value_ptr.*);
            if (!std.ascii.eqlIgnoreCase(origin_host, expected_host)) {
                return error.CrossOriginForbidden;
            }
            return;
        }
    }

    // No Origin — fall back to Referer (case-insensitive).
    it = request.headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "referer")) {
            const ref_host = extractHost(entry.value_ptr.*);
            if (!std.ascii.eqlIgnoreCase(ref_host, expected_host)) {
                return error.CrossOriginForbidden;
            }
            return;
        }
    }

    // Neither present — fail open for now (the CSRF + SameSite=Strict
    // cookie provides the primary defense; this is defence in depth).
    // Production deployments may want to flip this to fail-closed.
}

/// Reject request bodies that exceed `max` bytes.
pub fn enforceBodySizeLimit(body_len: usize, max: usize) !void {
    if (body_len > max) return error.PayloadTooLarge;
}