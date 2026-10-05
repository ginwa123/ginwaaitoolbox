// New Chat "Session not found" regression.
//
// Zig port of `tests/functional/new_chat_session_not_found_test.py`
// (same test names, same order).
//
// Python docstring, preserved verbatim:
//
//   """New Chat "Session not found" regression.
//
//   Replays the EXACT wire the frontend sends when opening a brand-new chat:
//   the task row exists (sidebar navigates with task_xxx in the URL) but no
//   session row exists yet. The sidebar fires:
//
//     POST /api/llm/session/:session_id/touched  body {}
//
//   and the profile dropdown may fire:
//
//     PUT /api/llm/session/:session_id  body {selected_profile_model, name, ...}
//
//   Before the fix, the auth_middleware choke point 404'd with
//   {"error": "Session not found"} for the missing row BEFORE the handler's
//   ensureSessionExists could run — every New Chat open toasted twice.
//
//   Covers:
//     * TOUCHED-LAZY-CREATE — POST touched on a never-seen id is 200 in auth-on
//       mode (handler ensure-creates), not 404.
//     * UPDATE-LAZY-CREATE — PUT update on a never-seen id is 200, not 404.
//     * ISOLATION-PRESERVED — B touching A's EXISTING session is still 404
//       (missing rows pass through, foreign rows do not).
//   """
//
// All three run against an `--auth` server, so the auth case is the one the
// regression lived in: the choke point is what used to 404 before the
// handler's `ensureSessionExists` could run.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Issue a request WITHOUT a status assertion — the caller asserts.
///
/// Python's `_raw` returned `(status, headers, body)` and caught
/// `HTTPError` so a 401/404 could be inspected. `Harness.http` asserts on
/// `expect` by default, which is the wrong tool when the STATUS ITSELF is the
/// assertion under test; its `{ .assert_status = false }` flag is exactly
/// this shape, so no suite needs a private HTTP client.
fn raw(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: ?[]const u8,
) !harness.Response {
    var extra: [1]harness.Header = undefined;
    const n: usize = if (cookie) |c| blk: {
        extra[0] = .{ .name = "Cookie", .value = c };
        break :blk 1;
    } else 0;
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = extra[0..n],
        .assert_status = false,
    });
}

/// Boot with the auth gate on — the regression is unreachable without it.
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME.
///
/// `runPabrikCommand` prepends the resolved binary itself, so `argv` starts
/// at the SUBCOMMAND. `force` maps to `--force`, which the third test needs to
/// add a SECOND admin.
fn createAdmin(home: []const u8, email: []const u8, password: []const u8, force: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "create-admin", "--email", email, "--password", password });
    if (force) try argv.append(gpa, "--force");

    var r = try harness.runPabrikCommand(io, gpa, home, argv.items, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print(
            "create-admin failed (rc={?}): {s}\n",
            .{ r.exit_code, if (r.stderr.len > 2000) r.stderr[r.stderr.len - 2000 ..] else r.stderr },
        );
        return error.TestUnexpectedResult;
    }
}

/// `POST /api/auth/login` and return the RAW session token.
///
/// Python returned the token and the caller wrapped it in
/// `pabrik_session=<tok>`; same split here so a test can hold one token per
/// user. Caller frees the returned slice.
///
/// The token is the segment between `pabrik_session=` and the next `;`.
/// `harness.afterFirst(cookie, ";")` on the WHOLE header would return the
/// attribute list (`Path=/; HttpOnly`) — the split has to happen on the value
/// part first. And on that value part the token is the BEFORE half of the
/// `;` split, which is `splitSequence(...).next()`, not `afterFirst`: that
/// helper returns the text AFTER the delimiter, so it hands back `Path=/` —
/// a token that authenticates nobody and comes back 401.
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .email = email, .password = password }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/auth/login", .{
        .json_body = body,
        .assert_status = false,
    });
    defer r.deinit();

    if (r.status != 200) {
        std.debug.print(
            "login failed with {d}: {s}\n",
            .{ r.status, if (r.body.len > 500) r.body[0..500] else r.body },
        );
        return error.TestUnexpectedResult;
    }
    const set_cookie = r.header("Set-Cookie") orelse "";
    const value_part = harness.afterFirst(set_cookie, "pabrik_session=") orelse {
        std.debug.print("login Set-Cookie carries no fabrique token: {s}\n", .{set_cookie});
        return error.TestUnexpectedResult;
    };
    var attrs = std.mem.splitSequence(u8, value_part, ";");
    const token = std.mem.trim(u8, attrs.next() orelse value_part, " \t\r\n");
    return try gpa.dupe(u8, token);
}

/// Poll `GET /api/llm/session/:id` until it stops 404.
///
/// `POST /api/llm/session` returns 201 before the row exists — the insert is
/// handed to a concurrent worker. The third test only makes sense once A's
/// session is a REAL row, so the poll is part of the setup, not the
/// assertion. Same 10s deadline / 0.2s interval as the Python original.
fn waitForSessionRow(h: *Harness, cookie: []const u8, session_id: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 10_000;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        var probe = try raw(h, .GET, path, null, cookie);
        const status = probe.status;
        probe.deinit();
        if (status == 200) return;
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
    std.debug.print("session {s} never landed within 10s\n", .{session_id});
    return error.TestUnexpectedResult;
}

// POST touched on a brand-new chat id must 200, not 404 Session not found.
test "touched_lazy_creates_missing_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "a@example.com", "supersecret123", false);
    const tok = try login(&h, "a@example.com", "supersecret123");
    defer gpa.free(tok);
    const cookie = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{tok});
    defer gpa.free(cookie);

    // Frontend's New Chat id: task row exists, session row does not.
    const new_id = "task_1790361260259_4_newchat";
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/touched", .{new_id});
    defer gpa.free(path);

    var r = try raw(&h, .POST, path, "{}", cookie);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print(
            "expected 200 lazy-create, got {d}: {s}\n",
            .{ r.status, if (r.body.len > 500) r.body[0..500] else r.body },
        );
        return error.TestUnexpectedResult;
    }

    var doc = try r.json();
    defer doc.deinit();
    if (doc.boolean("success") != true) {
        std.debug.print("touched did not report success: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const echoed = doc.str("session_id") orelse {
        std.debug.print("touched response has no session_id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(new_id, echoed);
}

// PUT update on a brand-new chat id must 200, not 404 session not found.
test "update_lazy_creates_missing_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "a@example.com", "supersecret123", false);
    const tok = try login(&h, "a@example.com", "supersecret123");
    defer gpa.free(tok);
    const cookie = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{tok});
    defer gpa.free(cookie);

    const new_id = "task_1790361260259_4_profile";
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{new_id});
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .selected_profile_model = "",
        .name = "New Chat",
    }, .{});
    defer gpa.free(body);

    var r = try raw(&h, .PUT, path, body, cookie);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print(
            "expected 200 lazy-create, got {d}: {s}\n",
            .{ r.status, if (r.body.len > 500) r.body[0..500] else r.body },
        );
        return error.TestUnexpectedResult;
    }
}

// Isolation preserved: B touching A's existing session is still 404.
test "foreign_existing_session_still_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "a@example.com", "supersecret123", false);
    try createAdmin(h.temp_dir, "b@example.com", "supersecret123", true);
    const tok_a = try login(&h, "a@example.com", "supersecret123");
    defer gpa.free(tok_a);
    const tok_b = try login(&h, "b@example.com", "supersecret123");
    defer gpa.free(tok_b);
    const cookie_a = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{tok_a});
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{tok_b});
    defer gpa.free(cookie_b);

    const sid = "sess_owned_by_a";
    {
        const create_body = try std.json.Stringify.valueAlloc(gpa, .{
            .session_id = sid,
            .queue_message = "hello from A",
        }, .{});
        defer gpa.free(create_body);

        var created = try raw(&h, .POST, "/api/llm/session", create_body, cookie_a);
        defer created.deinit();
        if (created.status != 201) {
            std.debug.print(
                "session create failed with {d}: {s}\n",
                .{ created.status, if (created.body.len > 500) created.body[0..500] else created.body },
            );
            return error.TestUnexpectedResult;
        }
    }

    // Wait for the async insert_worker to commit (create is async).
    try waitForSessionRow(&h, cookie_a, sid);

    const touched = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/touched", .{sid});
    defer gpa.free(touched);
    var r = try raw(&h, .POST, touched, "{}", cookie_b);
    defer r.deinit();

    if (r.status != 404) {
        std.debug.print(
            "expected 404 for foreign session, got {d}: {s}\n",
            .{ r.status, if (r.body.len > 300) r.body[0..300] else r.body },
        );
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, r.body, "Session not found") == null) {
        std.debug.print("404 body should name the missing session: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}
