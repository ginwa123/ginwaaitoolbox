// Functional tests for per-user terminal isolation (plan 2026-09-25, W2.5).
//
// Zig port of `tests/functional/terminal_isolation_test.py` (same test
// names, same order).
//
// Boots a REAL pabrik binary via the harness (never a live dev server,
// never port 8081). Two authenticated admins share ONE server process,
// so this is the wire-level proof that user A cannot attach to, read,
// type into, resize, or kill user B's PTY session.
//
// Why a wire test and not only a unit test: the terminal registry is
// in-memory and process-global (`terminal_session.zig`), and the owner
// is resolved from the request cookie at the handler. Only a real
// two-cookie round-trip exercises cookie -> auth_sessions -> users.id ->
// registry owner -> attach rejection. A unit test that passes an owner
// straight into the registry cannot catch a handler that forgets to
// resolve one.
//
// Covers:
//   * ATTACH-ISOLATION — B's input/output/resize/delete against A's
//                       terminal id are all 404 (not 403, so B cannot
//                       probe for the existence of A's ids).
//   * OWN-ACCESS       — A can still drive its own terminal (guards
//                       against an "everyone gets 404" false pass).
//   * AUTH-OFF-REGRESS — without `--auth` the same create + output
//                       round-trip still works.
//
// Both users are created with `create-admin`, so the isolation
// assertions here are also the admin-vs-admin assertions: `admin`
// grants NO cross-user visibility (user decision 2026-09-25).
//
// Python's module-level `_raw` became `rawHttp` below: the harness's
// `Harness.http` asserts on `expect` by default, but here the STATUS IS
// the thing under test ("B must get 404, not 403"), so every call goes
// out with `.assert_status = false` and the caller decides. Same reason
// `auth_test.zig` grew the same helper — no suite needs a private HTTP
// client.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The session cookie's name, as `Set-Cookie` spells it.
const COOKIE_NAME = "pabrik_session=";

/// Every user in this suite shares one password, exactly as in the
/// Python original — the variable under test is the IDENTITY, not the
/// secret.
const PASSWORD = "supersecret123";

/// Issue a request WITHOUT a status assertion — the caller asserts.
///
/// `cookie` is the raw `Cookie:` header value (`pabrik_session=<tok>`),
/// or null for no cookie at all. Python's `_raw` omitted the header
/// entirely when it was None; this passes an empty `extra_headers`
// slice rather than an empty-string header, which is the same request
/// line.
fn rawHttp(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: ?[]const u8,
) !harness.Response {
    var extra: [1]harness.Header = undefined;
    const n: usize = if (cookie) |c| blk: {
        if (c.len == 0) break :blk 0;
        extra[0] = .{ .name = "Cookie", .value = c };
        break :blk 1;
    } else 0;
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = extra[0..n],
        .assert_status = false,
    });
}

/// Boot a harness with `--auth` (the gate is opt-in).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME.
///
/// `runPabrikCommand` prepends the resolved binary itself, so `argv`
/// starts at the SUBCOMMAND. Passing the binary here as well produced
/// `[bin, bin, "create-admin", ...]`, which made the dispatcher miss
/// (it matches argv[1]) and fall through to booting a SERVER — which
/// then tried to bind the default port 8081 and failed with a confusing
/// "cannot bind" error about a port that was never the problem.
fn createAdmin(home: []const u8, email: []const u8, force: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "create-admin", "--email", email, "--password", PASSWORD });
    if (force) try argv.append(gpa, "--force");

    var r = try harness.runPabrikCommand(io, gpa, home, argv.items, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin {s} failed (rc={?}): {s}\n", .{ email, r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// `POST /api/auth/login` → the raw session token (not the cookie).
fn login(h: *Harness, email: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, PASSWORD },
    );
    defer gpa.free(body);

    var r = try rawHttp(h, .POST, "/api/auth/login", body, null);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);

    const set_cookie = r.header("Set-Cookie") orelse {
        std.debug.print("login for {s} returned no Set-Cookie; body={s}\n", .{ email, r.body });
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, set_cookie, COOKIE_NAME) == null) {
        std.debug.print("Set-Cookie does not carry {s}: {s}\n", .{ COOKIE_NAME, set_cookie });
        return error.TestUnexpectedResult;
    }

    // The token is the SEGMENT between `pabrik_session=` and the next
    // `;` — Python's `set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()`.
    // `afterFirst` on the WHOLE header would return the text after the
    // first `;`, i.e. `Path=/`.
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(
        u8,
        harness.afterFirst(first_attr, COOKIE_NAME) orelse return error.TestUnexpectedResult,
        " \t\r\n",
    );
    return gpa.dupe(u8, token);
}

/// `POST /api/terminal/sessions` → the new terminal's id.
///
/// `cwd` is derived from `h.temp_dir` rather than a literal `/tmp`: it is
/// absolute on every platform, and it is a directory that certainly
/// exists (the harness is running with it as HOME).
fn createTerminal(h: *Harness, cookie: ?[]const u8) ![]u8 {
    const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
    defer gpa.free(cwd);
    const body = try std.fmt.allocPrint(gpa, "{{\"cwd\":\"{s}\"}}", .{cwd});
    defer gpa.free(body);

    var r = try rawHttp(h, .POST, "/api/terminal/sessions", body, cookie);
    defer r.deinit();
    if (r.status != 201) {
        std.debug.print("terminal create returned {d}: {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("terminal create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// The two tokens for the two admins, as raw `Cookie:` header values.
const TwoTokens = struct {
    a: []u8,
    b: []u8,

    fn deinit(self: *TwoTokens) void {
        gpa.free(self.a);
        gpa.free(self.b);
        self.* = undefined;
    }
};

/// Boot auth mode with two admins in the SAME server process and log
/// both in.
///
/// The `harness` is a caller-owned parameter rather than a return value
/// so the two admin accounts, the two logins and the token cleanup all
/// live inside the caller's `defer` chain — a returned harness would
/// need its own owner to run `deinit` on.
fn twoUsers(h: *Harness) !TwoTokens {
    try createAdmin(h.temp_dir, "a@example.com", false);
    try createAdmin(h.temp_dir, "b@example.com", true);

    const a = try login(h, "a@example.com");
    errdefer gpa.free(a);
    const b = try login(h, "b@example.com");
    errdefer gpa.free(b);
    return .{ .a = a, .b = b };
}

// B must not be able to drive A's PTY by guessing its id.
//
// Every terminal route is keyed by a raw in-memory session id, so
// before the owner check B could read A's shell output, type into it,
// resize it, or kill it. All four are 404 for a foreign id.
test "foreign_terminal_attach_is_refused" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var toks = try twoUsers(&h);
    defer toks.deinit();

    const cookie_a = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.a });
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.b });
    defer gpa.free(cookie_b);

    const term_a = try createTerminal(&h, cookie_a);
    defer gpa.free(term_a);

    // A can drive its own terminal — proves the gate is not a blanket 404.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{term_a});
        defer gpa.free(url);
        var r = try rawHttp(&h, .GET, url, null, cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }

    // B cannot read A's output.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{term_a});
        defer gpa.free(url);
        var r = try rawHttp(&h, .GET, url, null, cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("expected 404 reading a foreign terminal, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // B cannot type into A's shell.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/input", .{term_a});
        defer gpa.free(url);
        var r = try rawHttp(&h, .POST, url, "{\"data\":\"echo pwned\\n\"}", cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("expected 404 writing to a foreign terminal, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // B cannot resize A's PTY.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/resize", .{term_a});
        defer gpa.free(url);
        var r = try rawHttp(&h, .POST, url, "{\"cols\":100,\"rows\":40}", cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("expected 404 resizing a foreign terminal, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // B cannot kill A's shell.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{term_a});
        defer gpa.free(url);
        var r = try rawHttp(&h, .DELETE, url, null, cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("expected 404 deleting a foreign terminal, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // A's terminal survived every attempt and is still usable.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{term_a});
        defer gpa.free(url);
        var r = try rawHttp(&h, .GET, url, null, cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
}

// Both users can drive their OWN terminals — no over-filtering.
test "own_terminal_still_works_for_each_user" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var toks = try twoUsers(&h);
    defer toks.deinit();

    const cookie_a = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.a });
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.b });
    defer gpa.free(cookie_b);

    const term_a = try createTerminal(&h, cookie_a);
    defer gpa.free(term_a);
    const term_b = try createTerminal(&h, cookie_b);
    defer gpa.free(term_b);

    const pair = [_]struct { who: []const u8, cookie: []const u8, term: []const u8 }{
        .{ .who = "A", .cookie = cookie_a, .term = term_a },
        .{ .who = "B", .cookie = cookie_b, .term = term_b },
    };

    for (pair) |p| {
        // Output: each user must read its own terminal.
        {
            const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{p.term});
            defer gpa.free(url);
            var r = try rawHttp(&h, .GET, url, null, p.cookie);
            defer r.deinit();
            if (r.status != 200) {
                std.debug.print("{s} must read its own terminal: got {d}: {s}\n", .{ p.who, r.status, r.body });
                return error.TestUnexpectedResult;
            }
        }
        // Input: each user must write to its own terminal.
        {
            const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/input", .{p.term});
            defer gpa.free(url);
            var r = try rawHttp(&h, .POST, url, "{\"data\":\"echo ok\\n\"}", p.cookie);
            defer r.deinit();
            if (r.status != 200) {
                std.debug.print("{s} must write to its own terminal: got {d}: {s}\n", .{ p.who, r.status, r.body });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// Regression: without `--auth` the create + output round-trip still works.
test "terminal_auth_off_is_unchanged" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Python passed `cookie=""` on create, which `_raw` turned into an
    // empty-string `Cookie:` header. Passing null here sends no header
    // at all, which is what an auth-off frontend does.
    const term = try createTerminal(&h, null);
    defer gpa.free(term);

    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/output", .{term});
        defer gpa.free(url);
        var r = try rawHttp(&h, .GET, url, null, null);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
    {
        const url = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}/input", .{term});
        defer gpa.free(url);
        var r = try rawHttp(&h, .POST, url, "{\"data\":\"echo hi\\n\"}", null);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
}
