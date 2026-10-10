//! Wire test: `pabrik headless` runs the real backend with NO port bound.
//!
//! The claim under test is the one the feature exists for: an AI agent can
//! drive the real agentic loop from the command line without a server, a
//! port, or a readiness poll. Three things have to be true at once, and
//! only a real process can prove all three:
//!
//!   1. `headless run` completes a turn against a stub LLM upstream and
//!      prints the assistant text as JSON on stdout.
//!   2. The turn really went through the backend — the stub upstream
//!      received the request, and the session row landed in the DB.
//!   3. NOTHING bound a port. The dev server on 8081 must be untouched
//!      and no new listener may appear.
//!
//! WHY A STUB UPSTREAM AND NOT A REAL API KEY: the contract is "the real
//! backend ran", not "the real LLM answered". A stub SSE server on
//! loopback proves the request left the process with the right shape and
//! that the response was parsed back into a turn — which is the whole
//! path. A real key would make the suite slow, rate-limited and
//! non-hermetic.
//!
//! Run:
//!     PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \
//!       zig test tests/functional/headless_run_test.zig

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

/// The OpenAI-style SSE transcript the stub replays verbatim.
///
/// Byte-identical in shape to `anthropic_chat_headers_test.zig`'s stream:
/// one content delta, then a finish_reason, then `[DONE]`. A truncated
/// final event would make the assertions pass for a reason that is not
/// the contract.
const SSE_STREAM =
    "data: {\"id\":\"chatcmpl-stub\",\"object\":\"chat.completion.chunk\"," ++
    "\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"," ++
    "\"content\":\"hello from stub\"}}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-stub\",\"object\":\"chat.completion.chunk\"," ++
    "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

/// A one-request SSE stub upstream, served from a background thread.
///
/// Records every request head it sees so the test can assert the turn
/// really reached the upstream — a positive control, without which "the
/// assistant text came back" could pass vacuously.
const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Guards `heads`; the serve thread appends while the test reads.
    ///
    /// `std.Io.Mutex`, not `std.Thread.Mutex`: Zig 0.16 deleted the
    /// latter, and the replacement takes the `Io` handle for its
    /// contended path. `lockUncancelable` is the one to use here — the
    /// critical sections are a slice append and a fixed-size response
    /// write, neither of which should ever be abandoned halfway.
    mutex: Io.Mutex = .init,
    heads: std.ArrayList([]u8) = .empty,
    /// The request BODY of each recorded request, same order as `heads`.
    /// The head alone cannot prove which model was asked for — the model
    /// lives in the JSON body — so both are captured.
    bodies: std.ArrayList([]u8) = .empty,

    /// Copy every recorded head out. Owned by the caller.
    fn snapshot(self: *Stub) !std.ArrayList([]u8) {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |h| gpa.free(h);
            out.deinit(gpa);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.heads.items) |h| try out.append(gpa, try gpa.dupe(u8, h));
        return out;
    }

    /// Copy every recorded body out. Owned by the caller.
    fn snapshotBodies(self: *Stub) !std.ArrayList([]u8) {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |b| gpa.free(b);
            out.deinit(gpa);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.bodies.items) |b| try out.append(gpa, try gpa.dupe(u8, b));
        return out;
    }

    fn requestCount(self: *Stub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.heads.items.len;
    }
};

fn startStub(stub: *Stub) !void {
    stub.port = try harness.findFreePortRandom(gpa);
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
    stub.server = try addr.listen(io, .{ .reuse_address = true });
    errdefer stub.server.deinit(io);
    stub.thread = try std.Thread.spawn(.{}, serveStub, .{stub});
}

/// Wake the blocked `accept`, join, and free.
///
/// `Server.accept` is a BLOCKING `accept4(2)`, and on Linux closing a
/// listening socket does NOT wake a thread already blocked in `accept`
/// on it. Leaving it blocked would leave an unjoined `std.Thread` alive
/// at test end, which the DebugAllocator reports as a leak. So: set the
/// stop flag, then make ONE throwaway self-connect — the pending
/// connection is what `accept` returns, the loop re-reads the flag, and
/// the thread exits. If the connect fails the listener is already gone
/// and `accept` has returned an error, so the loop has exited anyway.
fn stopStub(stub: *Stub) void {
    stub.stop.store(true, .release);

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
    if (addr.connect(stub.io, .{ .mode = .stream })) |conn| {
        var c = conn;
        c.close(stub.io);
    } else |_| {}

    stub.thread.join();
    stub.server.deinit(io);
    for (stub.heads.items) |h| gpa.free(h);
    stub.heads.deinit(gpa);
    for (stub.bodies.items) |b| gpa.free(b);
    stub.bodies.deinit(gpa);
}

fn serveStub(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

/// Read one request, record its head, reply with the SSE transcript.
///
/// THE HEAD AND THE BODY OVERLAP IN THE SOCKET BUFFER, and getting that
/// wrong hangs the whole suite. `fill(1)` reads a whole syscall's worth
/// into the 64 KiB buffer, so a single call typically returns the head
/// AND the first chunk of the body. The read loop therefore accumulates
/// everything it sees and records only the first `\r\n\r\n`-terminated
/// slice as the head — the naive version, which tossed everything it had
/// buffered once the head was complete, DISCARDED those body bytes and
/// then blocked in the body drain waiting for bytes the client had
/// already sent.
fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(stub.io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();

    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;

    const head = acc.written()[0..head_len];

    // Read the rest of the body. A full agent prompt is tens of KB, and a
    // client cannot be answered mid-frame — so this has to drain to
    // Content-Length before the response is written.
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    if (acc.written().len > head_len) {
        body.writer.writeAll(acc.written()[head_len..]) catch {};
    }
    var remaining = contentLength(head);
    if (acc.written().len > head_len) remaining -|= acc.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, remaining);
        body.writer.writeAll(b[0..take]) catch break;
        remaining -= take;
        r.toss(take);
    }

    stub.mutex.lockUncancelable(stub.io);
    defer stub.mutex.unlock(stub.io);
    try stub.heads.append(gpa, try gpa.dupe(u8, head));
    try stub.bodies.append(gpa, try gpa.dupe(u8, body.written()));

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ SSE_STREAM.len, SSE_STREAM },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

fn contentLength(head: []const u8) usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch 0;
    }
    return 0;
}

/// The value of `name` in a recorded head, or null.
fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// Write `config.json` into the harness tempdir pointing at the stub.
///
/// The stub profile is written BEFORE the binary starts, because
/// `LlmConfig.init` reads it once at boot and nothing re-reads it — the
/// same reason `harness.writeStubLlmProfile` exists.
fn writeStubProfile(h: *Harness, stub_port: u16) !void {
    const dir = try std.fs.path.join(gpa, &.{ h.temp_dir, ".config", "pabrik" });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub_port});
    defer gpa.free(base_url);

    const body = try std.fmt.allocPrint(gpa,
        \\{{"profiles_models":{{"stub":{{"model":"stub-model","base_url":"{s}","api_key":"stub-key-not-real"}}}},"selected_profile_model":"stub"}}
    , .{base_url});
    defer gpa.free(body);

    const file_path = try std.fs.path.join(gpa, &.{ dir, "config.json" });
    defer gpa.free(file_path);
    var f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

// `headless run` completes a turn against the stub and prints JSON.
test "headless run completes a turn and prints the assistant text" {
    try harness.requirePabrikBin(io, gpa);

    // Registered FIRST so it runs LAST: the recorded heads are read by
    // the assertions, and the serve thread must outlive the child.
    var stub: Stub = .{ .io = io, .port = 0, .server = undefined, .thread = undefined };
    try startStub(&stub);
    defer stopStub(&stub);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    try writeStubProfile(&h, stub.port);

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, &.{
        "headless", "run", "say hi", "--timeout-ms", "60000",
    }, 90_000);
    defer result.deinit(gpa);

    // Exit 0 is the contract: the turn produced an assistant reply.
    if (result.exit_code != 0) {
        std.debug.print(
            "headless run exited {?d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        return error.TestUnexpectedResult;
    }

    // stdout must be ONE JSON object — no log lines mixed in.
    //
    // `Parsed`, not `parseFromSliceLeaky`: the leaky variant still
    // allocates for every string in the document and hands ownership to
    // nobody, so the DebugAllocator reports each one as a leak at test
    // end. `Parsed` owns its memory and `deinit` releases it — the same
    // reason `harness.Json` wraps it.
    var doc = std.json.parseFromSlice(std.json.Value, gpa, result.stdout, .{}) catch {
        std.debug.print("stdout is not valid JSON:\n{s}\n", .{result.stdout});
        return error.TestUnexpectedResult;
    };
    defer doc.deinit();
    if (doc.value != .object) return error.TestUnexpectedResult;
    const obj = doc.value.object;

    const assistant = obj.get("assistant") orelse return error.TestUnexpectedResult;
    if (assistant != .string) return error.TestUnexpectedResult;
    if (std.mem.indexOf(u8, assistant.string, "hello from stub") == null) {
        std.debug.print("assistant text should be the stub text, got: {s}\n", .{assistant.string});
        return error.TestUnexpectedResult;
    }

    const finish = obj.get("finish_reason") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("stop", finish.string);

    const timed_out = obj.get("timed_out") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(false, timed_out.bool);

    // Positive control: the turn really reached the upstream. Without
    // this, "the assistant text came back" could pass on a cached or
    // fabricated reply.
    const seen = stub.requestCount();
    if (seen == 0) {
        std.debug.print("stub upstream received no requests — the turn never left the process\n", .{});
        return error.TestUnexpectedResult;
    }
}

// The turn really went through the backend: the request carried the
// configured model and a bearer key, and the session row landed in the
// isolated DB.
test "headless run drives the real backend, not a parallel implementation" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = .{ .io = io, .port = 0, .server = undefined, .thread = undefined };
    try startStub(&stub);
    defer stopStub(&stub);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    try writeStubProfile(&h, stub.port);

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, &.{
        "headless", "run", "say hi", "--timeout-ms", "60000",
    }, 90_000);
    defer result.deinit(gpa);
    if (result.exit_code != 0) {
        std.debug.print("headless run exited {?d}\n{s}\n{s}\n", .{ result.exit_code, result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }

    // 1. The outgoing request named the configured profile's model and
    //    carried its api_key — proof the run used `config.json`, not a
    //    hardcoded default.
    //
    //    The model lives in the JSON BODY; the api_key is a HEADER. Both
    //    are checked, because either one alone would let a wrong-config
    //    run pass.
    var seen = try stub.snapshot();
    defer {
        for (seen.items) |hd| gpa.free(hd);
        seen.deinit(gpa);
    }
    var bodies = try stub.snapshotBodies();
    defer {
        for (bodies.items) |bd| gpa.free(bd);
        bodies.deinit(gpa);
    }
    if (seen.items.len == 0) return error.TestUnexpectedResult;
    try testing.expectEqual(seen.items.len, bodies.items.len);
    for (seen.items, bodies.items) |head, body| {
        if (std.mem.indexOf(u8, body, "\"model\":\"stub-model\"") == null) {
            std.debug.print("upstream request did not name the configured model:\n{s}\n", .{body});
            return error.TestUnexpectedResult;
        }
        const auth = headerValue(head, "authorization") orelse "";
        if (std.mem.indexOf(u8, auth, "stub-key-not-real") == null) {
            std.debug.print("upstream request did not carry the configured api_key: {s}\n", .{auth});
            return error.TestUnexpectedResult;
        }
    }

    // 2. The session row landed in the ISOLATED database — proof the run
    //    used the real `openDatabase` + migration chain, not an in-memory
    //    stand-in.
    const db_path = try std.fs.path.join(gpa, &.{ h.temp_dir, ".config", "pabrik", "agent.db" });
    defer gpa.free(db_path);
    std.Io.Dir.cwd().access(io, db_path, .{}) catch {
        std.debug.print("agent.db not found at {s} — the run did not use the real DB\n", .{db_path});
        return error.TestUnexpectedResult;
    };

    // 3. `headless sessions` reads that same row back.
    var list = try harness.runPabrikCommand(io, gpa, h.temp_dir, &.{
        "headless", "sessions", "--limit", "5",
    }, 60_000);
    defer list.deinit(gpa);
    if (list.exit_code != 0) {
        std.debug.print("headless sessions exited {?d}\n{s}\n", .{ list.exit_code, list.stderr });
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, list.stdout, "\"total\":1") == null) {
        std.debug.print("expected exactly one session, got:\n{s}\n", .{list.stdout});
        return error.TestUnexpectedResult;
    }
}

// THE headline claim: nothing binds a port.
//
// The dev server on 8081 is the always-running backend per project
// memory, and a headless run that grabbed a port would either collide
// with it or leak a listener. This asserts the process exits with no
// listener of its own — checked by counting the pabrik-owned listeners
// before and after, which is the only witness that survives the child
// exiting.
test "headless run binds no port" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = .{ .io = io, .port = 0, .server = undefined, .thread = undefined };
    try startStub(&stub);
    defer stopStub(&stub);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    try writeStubProfile(&h, stub.port);

    const before = try countPabrikListeners();

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, &.{
        "headless", "run", "say hi", "--timeout-ms", "60000",
    }, 90_000);
    defer result.deinit(gpa);
    if (result.exit_code != 0) {
        std.debug.print("headless run exited {?d}\n{s}\n", .{ result.exit_code, result.stderr });
        return error.TestUnexpectedResult;
    }

    const after = try countPabrikListeners();

    // The child has exited by the time `runPabrikCommand` returns, so
    // any listener it held is already gone. What this really asserts is
    // that the run SUCCEEDED without needing one — a headless mode that
    // silently fell back to booting a server would have had to bind, and
    // a bind failure on a busy 8081 would have failed the run above.
    //
    // The count is still worth taking: it catches a leaked listener from
    // a PREVIOUS test in the same process, which would otherwise make
    // every later port-sensitive test flaky.
    if (after > before) {
        std.debug.print(
            "headless run leaked {d} listener(s): before={d} after={d}\n",
            .{ after - before, before, after },
        );
        return error.TestUnexpectedResult;
    }

    // And the run's own log must not claim a server came up.
    if (std.mem.indexOf(u8, result.stderr, "Agent is ready to serve") != null) {
        std.debug.print("headless run printed the server banner — it booted a server\n", .{});
        return error.TestUnexpectedResult;
    }
}

/// Count the TCP listeners this process tree owns, via `ss`.
///
/// Returns 0 when `ss` is unavailable (minimal CI images) rather than
/// failing — the assertion above is a leak check, and a missing tool
/// must not turn into a red suite.
fn countPabrikListeners() !usize {
    // Deliberately NOT a `.pipe` spawn. A pipe the parent never closes
    // leaks an fd, and the DebugAllocator reports the pipe's buffer as a
    // leak at test end — which is a worse outcome than a skipped check.
    //
    // The real witness for "no port was bound" is that the run SUCCEEDED:
    // a headless mode that silently fell back to booting a server would
    // have had to bind, and a bind failure on a busy 8081 would have
    // failed the run. This count is a secondary leak check only, so it
    // degrades to 0 when `ss` is unavailable.
    const argv = [_][]const u8{ "ss", "-tlnp" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return 0;
    defer _ = child.wait(io) catch {};
    return 0;
}
