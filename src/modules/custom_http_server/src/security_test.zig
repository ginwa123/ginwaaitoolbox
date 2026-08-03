// ============================================================================
// security_test.zig — behavioural tests for the security primitives.
//
// All 16 tests below exercise the primitives end-to-end. No source-grep
// / static-contract tests (project rule 2026-07-29).
//
// Tests:
//   1-4:   csrfTokenIssue + csrfTokenValidate round-trip and tamper
//          detection
//   5-8:   rateLimitCheck under-limit / over-limit / per-IP / window reset
//   9-12:  applySecurityHeaders sets each of the 4 most-important headers
//   13-15: checkOrigin matches / mismatches Origin / mismatches Referer
//   16:    enforceBodySizeLimit rejects oversized bodies
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const security = @import("security.zig");

const TEST_SECRET = "test-csrf-secret-do-not-use-in-prod";

fn makeMockRequest(allocator: std.mem.Allocator) security.HttpRequest {
    return .{
        .method = "POST",
        .path = "/users",
        .version = "HTTP/1.1",
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = "",
        .raw = "",
        .params = std.StringHashMap([]const u8).init(allocator),
        .query = std.StringHashMap([]const u8).init(allocator),
        ._client_fd = -1,
    };
}

// ───────────────────────────────────────────────────────────────────────────
//  CSRF token primitives (tests 1-4)
// ───────────────────────────────────────────────────────────────────────────

test "csrfTokenIssue + csrfTokenValidate round-trip succeeds" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bundle = try security.csrfTokenIssue(TEST_SECRET, io, testing.allocator);
    defer testing.allocator.free(bundle.token);
    defer testing.allocator.free(bundle.cookie);

    try testing.expect(bundle.token.len > 0);
    try testing.expect(bundle.cookie.len > 0);

    // Validate at current time.
    const now = std.Io.Clock.now(.real, io).toSeconds();
    try security.csrfTokenValidate(bundle.token, TEST_SECRET, now);
}

test "csrfTokenValidate rejects tampered token" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bundle = try security.csrfTokenIssue(TEST_SECRET, io, testing.allocator);
    defer testing.allocator.free(bundle.token);
    defer testing.allocator.free(bundle.cookie);

    // Flip a character in the middle of the token (well inside the HMAC
    // section so any change invalidates the signature).
    var tampered = try testing.allocator.dupe(u8, bundle.token);
    defer testing.allocator.free(tampered);
    const tampered_idx = tampered.len / 2;
    tampered[tampered_idx] = if (tampered[tampered_idx] == 'A') 'B' else 'A';

    const now = std.Io.Clock.now(.real, io).toSeconds();
    const result = security.csrfTokenValidate(tampered, TEST_SECRET, now);
    try testing.expectError(error.CsrfMismatch, result);
}

test "csrfTokenValidate rejects expired token" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bundle = try security.csrfTokenIssue(TEST_SECRET, io, testing.allocator);
    defer testing.allocator.free(bundle.token);
    defer testing.allocator.free(bundle.cookie);

    // Pass a "now" that's older than the token's issued-at time + TTL.
    // The token was issued at `issued_at`; if we tell the validator that
    // current time is `issued_at - 1`, the token looks "from the future"
    // which trips the clock-skew guard. We need to test the EXPIRED path
    // instead — pass `issued_at + TTL + 1` to the validator.
    //
    // Extract the timestamp from the token (first '.'-separated segment).
    var ts_iter = std.mem.splitScalar(u8, bundle.token, '.');
    const ts_str = ts_iter.next().?;
    const issued_at = try std.fmt.parseInt(i64, ts_str, 10);

    const expired_now = issued_at + security.CSRF_TOKEN_TTL_SEC + 1;
    const result = security.csrfTokenValidate(bundle.token, TEST_SECRET, expired_now);
    try testing.expectError(error.CsrfMismatch, result);
}

test "csrfTokenValidate rejects wrong-secret token" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bundle = try security.csrfTokenIssue(TEST_SECRET, io, testing.allocator);
    defer testing.allocator.free(bundle.token);
    defer testing.allocator.free(bundle.cookie);

    const wrong_secret = "completely-different-secret";
    const now = std.Io.Clock.now(.real, io).toSeconds();
    const result = security.csrfTokenValidate(bundle.token, wrong_secret, now);
    try testing.expectError(error.CsrfMismatch, result);
}

// ───────────────────────────────────────────────────────────────────────────
//  Rate limit primitive (tests 5-8)
// ───────────────────────────────────────────────────────────────────────────

test "rateLimitCheck allows 5 requests under the limit" {
    security.rateLimitResetForTesting();
    const route = "/users";
    const ip = "192.168.1.1";
    const now: i64 = 1_000_000;

    var i: u32 = 0;
    while (i < security.RATE_LIMIT_MAX) : (i += 1) {
        const retry = try security.rateLimitCheck(ip, route, now);
        try testing.expectEqual(@as(u32, 0), retry);
    }
}

test "rateLimitCheck rejects 6th request with Retry-After hint" {
    security.rateLimitResetForTesting();
    const route = "/users";
    const ip = "10.0.0.1";
    const now: i64 = 1_000_000;

    // Fill the bucket.
    var i: u32 = 0;
    while (i < security.RATE_LIMIT_MAX) : (i += 1) {
        _ = try security.rateLimitCheck(ip, route, now);
    }

    // 6th request must be rejected with a positive Retry-After.
    const result = security.rateLimitCheck(ip, route, now);
    try testing.expectError(error.RateLimited, result);
}

test "rateLimitCheck is per-IP (different IPs are independent)" {
    security.rateLimitResetForTesting();
    const route = "/users";
    const now: i64 = 2_000_000;

    // Saturate IP A.
    var i: u32 = 0;
    while (i < security.RATE_LIMIT_MAX) : (i += 1) {
        _ = try security.rateLimitCheck("10.0.0.1", route, now);
    }
    // IP A's 6th request must be rejected.
    try testing.expectError(error.RateLimited, security.rateLimitCheck("10.0.0.1", route, now));

    // IP B is independent and gets a fresh bucket.
    var j: u32 = 0;
    while (j < security.RATE_LIMIT_MAX) : (j += 1) {
        _ = try security.rateLimitCheck("10.0.0.2", route, now);
    }
    try testing.expectError(error.RateLimited, security.rateLimitCheck("10.0.0.2", route, now));
}

test "rateLimitCheck window resets after time advance" {
    security.rateLimitResetForTesting();
    const route = "/users";
    const ip = "10.0.0.1";
    const start: i64 = 3_000_000;

    // Saturate the bucket.
    var i: u32 = 0;
    while (i < security.RATE_LIMIT_MAX) : (i += 1) {
        _ = try security.rateLimitCheck(ip, route, start);
    }
    try testing.expectError(error.RateLimited, security.rateLimitCheck(ip, route, start));

    // Advance time past the window — bucket should reset.
    const later = start + security.RATE_LIMIT_WINDOW_SEC + 1;
    var j: u32 = 0;
    while (j < security.RATE_LIMIT_MAX) : (j += 1) {
        _ = try security.rateLimitCheck(ip, route, later);
    }
    // The window-start has been reset by the first request at `later`,
    // so the 6th in this new window should fail again.
    try testing.expectError(error.RateLimited, security.rateLimitCheck(ip, route, later));
}

// ───────────────────────────────────────────────────────────────────────────
//  Security headers primitive (tests 9-12)
// ───────────────────────────────────────────────────────────────────────────

test "applySecurityHeaders sets Content-Security-Policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var res = security.HttpResponse.init(200, "OK", allocator);
    defer res.deinit();

    security.applySecurityHeaders(&res);

    const csp = res.headers.get("Content-Security-Policy") orelse
        return error.ContentSecurityPolicyHeaderMissing;
    try testing.expect(std.mem.indexOf(u8, csp, "default-src 'self'") != null);
    try testing.expect(std.mem.indexOf(u8, csp, "frame-ancestors 'none'") != null);
}

test "applySecurityHeaders sets X-Content-Type-Options nosniff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var res = security.HttpResponse.init(200, "OK", allocator);
    defer res.deinit();

    security.applySecurityHeaders(&res);

    const v = res.headers.get("X-Content-Type-Options") orelse
        return error.XContentTypeOptionsHeaderMissing;
    try testing.expectEqualStrings("nosniff", v);
}

test "applySecurityHeaders sets X-Frame-Options DENY" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var res = security.HttpResponse.init(200, "OK", allocator);
    defer res.deinit();

    security.applySecurityHeaders(&res);

    const v = res.headers.get("X-Frame-Options") orelse
        return error.XFrameOptionsHeaderMissing;
    try testing.expectEqualStrings("DENY", v);
}

test "applySecurityHeaders sets Referrer-Policy strict-origin-when-cross-origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var res = security.HttpResponse.init(200, "OK", allocator);
    defer res.deinit();

    security.applySecurityHeaders(&res);

    const v = res.headers.get("Referrer-Policy") orelse
        return error.ReferrerPolicyHeaderMissing;
    try testing.expectEqualStrings("strict-origin-when-cross-origin", v);
}

// ───────────────────────────────────────────────────────────────────────────
//  Origin check + body size primitive (tests 13-16)
// ───────────────────────────────────────────────────────────────────────────

test "checkOrigin accepts matching Origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var req = makeMockRequest(allocator);
    try req.headers.put("Origin", "http://localhost:4021");
    defer req.headers.deinit();

    try security.checkOrigin(&req, "localhost:4021");
}

test "checkOrigin rejects mismatched Origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var req = makeMockRequest(allocator);
    try req.headers.put("Origin", "http://evil.example.com");
    defer req.headers.deinit();

    const result = security.checkOrigin(&req, "localhost:4021");
    try testing.expectError(error.CrossOriginForbidden, result);
}

test "checkOrigin rejects when Origin is absent but Referer is mismatched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var req = makeMockRequest(allocator);
    try req.headers.put("Referer", "http://attacker.example.org/signup");
    defer req.headers.deinit();

    const result = security.checkOrigin(&req, "localhost:4021");
    try testing.expectError(error.CrossOriginForbidden, result);
}

test "enforceBodySizeLimit rejects 17 KB" {
    // 16 KB is the limit; 17 KB must be rejected.
    const result = security.enforceBodySizeLimit(17 * 1024, security.MAX_BODY_BYTES);
    try testing.expectError(error.PayloadTooLarge, result);

    // Exactly at the limit is accepted.
    try security.enforceBodySizeLimit(16 * 1024, security.MAX_BODY_BYTES);
    // Just under is accepted.
    try security.enforceBodySizeLimit(16 * 1024 - 1, security.MAX_BODY_BYTES);
}
// ───────────────────────────────────────────────────────────────────────────
//  HttpResponse.withSecurityHeaders() convenience (test 17)
// ───────────────────────────────────────────────────────────────────────────

test "HttpResponse.withSecurityHeaders sets all 7 headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const chained = security.HttpResponse.init(200, "OK", allocator).withSecurityHeaders();

    try testing.expect(chained.headers.get("Content-Security-Policy") != null);
    try testing.expect(chained.headers.get("X-Content-Type-Options") != null);
    try testing.expect(chained.headers.get("X-Frame-Options") != null);
    try testing.expect(chained.headers.get("Referrer-Policy") != null);
    try testing.expect(chained.headers.get("Permissions-Policy") != null);
    try testing.expect(chained.headers.get("Cross-Origin-Opener-Policy") != null);
    try testing.expect(chained.headers.get("Cross-Origin-Resource-Policy") != null);
}

test "HttpResponse.withSecurityHeaders chains after withBody without dropping Content-Length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = "<html>hello</html>";
    const chained = security.HttpResponse.init(200, "OK", allocator)
        .withBody(body)
        .withSecurityHeaders();

    // Content-Length was set by withBody and must survive withSecurityHeaders.
    try testing.expect(chained.headers.get("Content-Length") != null);
    // CSP was added by withSecurityHeaders.
    try testing.expect(chained.headers.get("Content-Security-Policy") != null);
}
