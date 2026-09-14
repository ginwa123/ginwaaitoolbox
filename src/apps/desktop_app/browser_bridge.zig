// src/apps/desktop_app/browser_bridge.zig
//
// The SPA ↔ shell bridge behind the in-app browser tab.
//
// The APP window (the one rendering our own SPA) gets exactly three bound JS
// functions via `webview_bind`:
//
//     window.nalarBrowserOpen(tabId, url)   → { ok, alive, error? }
//     window.nalarBrowserStatus(tabId)      → { alive }
//     window.nalarBrowserClose(tabId)       → { ok }
//
// FLAT names, on purpose. The vendored glue
// (`vendor/webview/webview.h`, `Webview_.prototype.onBind`) does
// `window[name] = …` with the name VERBATIM — there is no namespace walking —
// so binding "nalarBrowser.open" creates the property `window["nalarBrowser.open"]`
// and leaves `window.nalarBrowser` undefined, i.e. a bridge the SPA can never
// reach. (Found live: the button did nothing because the frontend correctly saw
// "no bridge".) `helpers/browserBridge.ts` composes the object-shaped API from
// these three globals and `tests/.../webviewBindGlue.spec.ts` locks the rule by
// executing the real glue.
//
// The callback runs INSIDE this process — no HTTP route, no port, no token,
// nothing another local process can reach (plan §3.2). That is also why the
// shell can do what a server-side route could not: it knows its own binary
// (`path_resolve.selfExePath`) and can hold the `std.process.Child` handle it
// spawned. Owning the handle is what makes liveness exact — we never look a pid
// up, we wait on the child we own, so PID reuse cannot masquerade as "alive".
//
// INVARIANT — bindings go on the APP window only. The browser window (which
// renders third-party content) gets none: `webview_lib.runBrowserWindow`
// deliberately never calls `installBindings`, and the chrome bar it injects
// navigates with `location.href` and needs no binding. Any future feature that
// wants a binding inside the browser window has to justify breaking this.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const path_resolve = @import("path_resolve.zig");
const webview_lib = @import("webview_lib.zig");

const Webview = webview_lib.Webview;

/// Windows tracked at once. A tab holds at most one auto-managed window and the
/// frontend caps itself at 50 tabs; a fixed array keeps this allocation-free.
pub const MAX_WINDOWS = 64;
/// Tab ids are `tab_<hex>` from `helpers/tabTarget.ts` (plus the synthetic
/// `external` id used when tab mode is off).
pub const MAX_TAB_ID = 64;
/// Stack buffer for the parsed request (`{"id","method","params"}` → params).
const PARAMS_BUF = 4096;
/// Stack buffer for a reply. Every reply this module builds is a small object.
const REPLY_BUF = 512;

/// Injectable spawn, so a unit test can drive `open` without launching a real
/// window. Production uses `defaultSpawn`.
pub const SpawnFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) anyerror!std.process.Child;

pub const Window = struct {
    tab_id: [MAX_TAB_ID]u8 = [_]u8{0} ** MAX_TAB_ID,
    tab_len: usize = 0,
    child: std.process.Child = undefined,
    used: bool = false,

    pub fn tabId(self: *const Window) []const u8 {
        return self.tab_id[0..self.tab_len];
    }

    fn matches(self: *const Window, id: []const u8) bool {
        return self.used and std.mem.eql(u8, self.tabId(), id);
    }
};

pub const Method = enum { open, status, close };

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    spawn_ctx: ?*anyopaque = null,
    spawn_fn: SpawnFn = defaultSpawn,
    /// Monotonic count of successful spawns — asserted by the tests and logged.
    spawn_count: usize = 0,
    windows: [MAX_WINDOWS]Window = [_]Window{.{}} ** MAX_WINDOWS,
    w: ?*Webview = null,
    installed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Bridge {
        return .{ .allocator = allocator, .io = io };
    }

    /// Bind the three functions on the APP window, before `webview_run`.
    ///
    /// Idempotent on purpose: the vendored API answers `WEBVIEW_ERROR_DUPLICATE`
    /// for a name that is already bound, and a duplicate bind would leave the
    /// old callback in place rather than replace it — so a second install is a
    /// no-op instead of a silent half-install.
    pub fn installBindings(self: *Bridge, w: *Webview) void {
        if (self.installed) return;
        self.installed = true;
        self.w = w;
        const arg: ?*anyopaque = @ptrCast(self);
        // Flat names — see the file header: the vendored glue writes
        // `window[name]` verbatim, so a dotted name would be unreachable.
        _ = webview_lib.webview_bind(w, "nalarBrowserOpen", onOpen, arg);
        _ = webview_lib.webview_bind(w, "nalarBrowserStatus", onStatus, arg);
        _ = webview_lib.webview_bind(w, "nalarBrowserClose", onClose, arg);
    }

    pub fn windowCount(self: *const Bridge) usize {
        var count: usize = 0;
        for (&self.windows) |*window| {
            if (window.used) count += 1;
        }
        return count;
    }

    pub fn find(self: *Bridge, tab_id: []const u8) ?*Window {
        for (&self.windows) |*window| {
            if (window.matches(tab_id)) return window;
        }
        return null;
    }

    /// Drive one bound call. Webview-independent, so the whole contract is
    /// testable without creating a window: the reply is the NUL-terminated JSON
    /// the JS side receives (status 0 → the returned promise resolves with it).
    pub fn handleRequest(self: *Bridge, method: Method, req: []const u8, out: []u8) [:0]const u8 {
        return switch (method) {
            .open => self.handleOpen(req, out),
            .status => self.handleStatus(req, out),
            .close => self.handleClose(req, out),
        };
    }

    fn handleOpen(self: *Bridge, req: []const u8, out: []u8) [:0]const u8 {
        var arena_buf: [PARAMS_BUF]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        var params: [4][]const u8 = undefined;
        const count = parseParams(&fba, req, &params) orelse
            return reply(out, "{{\"ok\":false,\"alive\":0,\"error\":\"open expects (tabId, url)\"}}", .{});
        if (count < 2) {
            return reply(out, "{{\"ok\":false,\"alive\":0,\"error\":\"open expects (tabId, url)\"}}", .{});
        }
        const tab_id = params[0];
        const url = params[1];
        if (!isSafeTabId(tab_id)) {
            return reply(out, "{{\"ok\":false,\"alive\":0,\"error\":\"invalid tab id\"}}", .{});
        }
        // Second, independent scheme check. The frontend refuses a non-http
        // scheme before it ever calls us; this is the boundary that actually
        // must not be crossed (the URL becomes an argv element of the spawn).
        if (!cli.isHttpUrl(url)) {
            return reply(out, "{{\"ok\":false,\"alive\":0,\"error\":\"only http(s) URLs can be opened\"}}", .{});
        }
        if (self.find(tab_id)) |window| {
            // One auto-managed window per tab: a repeat open (a second click, a
            // restored tab) never spawns another. The tab body offers "Open
            // another window" as the explicit opt-in instead.
            const alive = self.probeAlive(window);
            return if (alive)
                reply(out, "{{\"ok\":true,\"alive\":1}}", .{})
            else
                // The previous window is gone: this is the user asking for it
                // again, so re-spawn rather than reporting a dead handle.
                self.spawnAndRecord(tab_id, url, out);
        }
        return self.spawnAndRecord(tab_id, url, out);
    }

    fn handleStatus(self: *Bridge, req: []const u8, out: []u8) [:0]const u8 {
        var arena_buf: [PARAMS_BUF]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        var params: [4][]const u8 = undefined;
        const count = parseParams(&fba, req, &params) orelse 0;
        // An unknown tab id is not an error: "no window" is the honest answer a
        // restored tab must get (the strip must not show a broken state).
        if (count < 1) return reply(out, "{{\"alive\":0}}", .{});
        const window = self.find(params[0]) orelse return reply(out, "{{\"alive\":0}}", .{});
        return if (self.probeAlive(window))
            reply(out, "{{\"alive\":1}}", .{})
        else
            reply(out, "{{\"alive\":0}}", .{});
    }

    fn handleClose(self: *Bridge, req: []const u8, out: []u8) [:0]const u8 {
        var arena_buf: [PARAMS_BUF]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        var params: [4][]const u8 = undefined;
        const count = parseParams(&fba, req, &params) orelse 0;
        if (count >= 1) {
            if (self.find(params[0])) |window| self.terminate(window);
        }
        // Closing a tab whose window never opened (or was closed from the OS
        // already) is a no-op, never an error — the strip must be able to close
        // anything.
        return reply(out, "{{\"ok\":true}}", .{});
    }

    fn spawnAndRecord(self: *Bridge, tab_id: []const u8, url: []const u8, out: []u8) [:0]const u8 {
        const exe = path_resolve.selfExePath(self.allocator) catch |err| {
            std.log.err("browser window: cannot resolve own exe path: {s}", .{@errorName(err)});
            return reply(out, "{{\"ok\":false,\"alive\":0,\"error\":\"cannot resolve the desktop binary\"}}", .{});
        };
        defer self.allocator.free(exe);
        // The URL is an argv element — there is no shell string anywhere, so
        // there is no shell-injection surface to begin with.
        const argv = [3][]const u8{ exe, "--browser", url };
        const child = self.spawn_fn(self.spawn_ctx, self.allocator, self.io, &argv) catch |err| {
            std.log.err("browser window spawn failed: {s}", .{@errorName(err)});
            return reply(out, "{{\"ok\":false,\"alive\":0,\"error\":\"could not open the browser window\"}}", .{});
        };
        if (self.findSlot()) |slot| {
            slot.tab_len = tab_id.len;
            @memcpy(slot.tab_id[0..tab_id.len], tab_id);
            slot.child = child;
            slot.used = true;
            self.spawn_count += 1;
            std.log.info("browser window spawned for tab {s}", .{tab_id});
            return reply(out, "{{\"ok\":true,\"alive\":1}}", .{});
        }
        // The table is full: never leak a live window we can no longer track.
        var doomed = child;
        doomed.kill(self.io);
        return reply(out, "{{\"ok\":false,\"alive\":0,\"error\":\"too many browser windows\"}}", .{});
    }

    fn findSlot(self: *Bridge) ?*Window {
        for (&self.windows) |*window| {
            if (!window.used) return window;
        }
        return null;
    }

    /// Non-blocking "is the child still running?".
    ///
    /// POSIX: `waitpid(WNOHANG)` — when it reaps, we mirror that by clearing
    /// `child.id`, so a later `Child.kill` takes its documented early-return
    /// path (it asserts `id == null` after reaping).
    /// Windows: `NtWaitForSingleObject` with a zero timeout; the signalled path
    /// closes the handle ourselves.
    fn probeAlive(self: *Bridge, window: *Window) bool {
        _ = self;
        if (window.child.id == null) return false;
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            const handle = window.child.id.?;
            var timeout: windows.LARGE_INTEGER = 0; // 0 = poll, do not block
            // `WAIT_0` is a decl on the enum (`.SUCCESS`), not a field, so it
            // must be spelled out rather than inferred from the literal.
            if (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, &timeout) ==
                windows.NTSTATUS.WAIT_0)
            {
                windows.CloseHandle(handle);
                window.child.id = null;
                return false;
            }
            return true;
        }
        const pid = window.child.id.?;
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            window.child.id = null;
            return false;
        }
        return true;
    }

    fn terminate(self: *Bridge, window: *Window) void {
        if (window.child.id == null) return;
        // SIGTERM → wait → SIGKILL, plus handle cleanup on Windows, is exactly
        // what the vendored handle type already does.
        window.child.kill(self.io);
    }
};

/// Cross-compile hook (see `cross_compile_check.zig`): forces the per-OS
/// liveness probe, the binding install and the request/reply path to be
/// analysed for a FOREIGN target too, so a Windows- or macOS-only type error
/// fails on every runner instead of only on that OS's CI job. Never executed.
pub fn crossCompileCheckChildHandle(child: *std.process.Child) bool {
    var bridge = Bridge.init(std.heap.page_allocator, undefined);
    bridge.installBindings(undefined);
    var window = Window{ .used = true };
    window.child = child.*;
    var out: [REPLY_BUF]u8 = undefined;
    _ = bridge.handleRequest(.status, "[\"tab_x\"]", &out);
    return bridge.probeAlive(&window);
}

fn defaultSpawn(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) anyerror!std.process.Child {
    _ = ctx;
    _ = allocator;
    // Detached on purpose: a browser window is an independent window, and the
    // user's windows survive the app quitting. No stdin/stdout/stderr; nothing
    // reads them.
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Tab ids are only ever used as a lookup key, but keep them to the shape the
/// frontend mints (`tab_…`) so a malformed request cannot store arbitrary bytes.
fn isSafeTabId(tab_id: []const u8) bool {
    if (tab_id.len == 0 or tab_id.len > MAX_TAB_ID - 1) return false;
    for (tab_id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':';
        if (!ok) return false;
    }
    return true;
}

/// Parse the bound call's `params` array (webview.h hands the callback the JSON
/// of `{"id","method","params"}`'s `params` value).
///
/// The tree is parsed into a STACK buffer and deliberately not freed: the
/// returned slices point into that buffer, which lives until this call returns.
fn parseParams(fba: *std.heap.FixedBufferAllocator, req: []const u8, out: *[4][]const u8) ?usize {
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), req, .{}) catch return null;
    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return null,
    };
    if (items.len > out.len) return null;
    for (items, 0..) |item, index| {
        out[index] = switch (item) {
            .string => |text| text,
            else => return null,
        };
    }
    return items.len;
}

fn reply(out: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintZ(out, fmt, args) catch out[0..0 :0];
}

// ---------------------------------------------------------------------------
// Callbacks. `arg` carries the `*Bridge` from `installBindings`.
// ---------------------------------------------------------------------------

fn dispatch(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque, method: Method) void {
    const self: *Bridge = @ptrCast(@alignCast(arg orelse return));
    var out: [REPLY_BUF]u8 = undefined;
    const result = self.handleRequest(method, std.mem.span(req), &out);
    if (self.w) |w| {
        // status 0 → the JS promise resolves with JSON.parse(result).
        _ = webview_lib.webview_return(w, id, 0, result.ptr);
    }
}

fn onOpen(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .open);
}

fn onStatus(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .status);
}

fn onClose(id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    dispatch(id, req, arg, .close);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A pid that is not a child of this process: `waitpid` on it answers ECHILD,
/// which reads as "still running" — exactly the state a freshly spawned window
/// is in. (waitpid can only reap the caller's own children, so this can never
/// touch a real process.)
const FAKE_PID: std.posix.pid_t = 999_999;

const Recorder = struct {
    calls: usize = 0,
    argv_len: usize = 0,
    saw_browser_flag: bool = false,
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,

    fn url(self: *const Recorder) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

fn recordingSpawn(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) anyerror!std.process.Child {
    _ = allocator;
    _ = io;
    const rec: *Recorder = @ptrCast(@alignCast(ctx.?));
    rec.calls += 1;
    rec.argv_len = argv.len;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--browser")) rec.saw_browser_flag = true;
    }
    if (argv.len >= 3 and argv[2].len <= rec.url_buf.len) {
        @memcpy(rec.url_buf[0..argv[2].len], argv[2]);
        rec.url_len = argv[2].len;
    }
    var child: std.process.Child = undefined;
    child.id = FAKE_PID;
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    return child;
}

fn testBridge(rec: *Recorder) Bridge {
    var bridge = Bridge.init(testing.allocator, testing.io);
    bridge.spawn_ctx = rec;
    bridge.spawn_fn = recordingSpawn;
    return bridge;
}

fn readOwnSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/apps/desktop_app/browser_bridge.zig",
        allocator,
        .limited(128 * 1024),
    );
}

test "browser bridge: binds exactly the three browser functions" {
    // Static contract: the vendored API fails a duplicate bind rather than
    // replacing it, and the plan's invariant is "exactly open/status/close on
    // the app window". A fourth bind here (or a renamed one) must fail the
    // build, not silently ship a half-wired bridge.
    const allocator = testing.allocator;
    const source = try readOwnSource(allocator);
    defer allocator.free(source);

    const install_idx = std.mem.indexOf(u8, source, "pub fn installBindings(") orelse {
        std.debug.print("!! browser_bridge.zig has no installBindings !!\n", .{});
        return error.BrowserBindingsMissing;
    };
    // Scoped to the installBindings body (up to the next struct member) so the
    // count cannot pick up this test's own needle strings.
    const tail = source[install_idx..];
    const body = tail[0 .. std.mem.indexOf(u8, tail, "\n    pub fn ") orelse tail.len];

    const names = [_][]const u8{
        "nalarBrowserOpen",
        "nalarBrowserStatus",
        "nalarBrowserClose",
    };
    for (names) |name| {
        // A binding name must be a single JS identifier: the vendored glue does
        // `window[name] = …` VERBATIM (no namespace walking), so "a.b" would
        // create `window["a.b"]` and leave `window.a` undefined — a bridge the
        // SPA cannot see. That is a real bug this repo shipped once; the
        // frontend spec `webviewBindGlue.spec.ts` executes the glue itself.
        try testing.expect(std.mem.indexOfScalar(u8, name, '.') == null);
        if (std.mem.indexOf(u8, body, name) == null) {
            std.debug.print("!! browser_bridge.zig does not bind {s} !!\n", .{name});
            return error.BrowserBindingMissing;
        }
    }
    var binds: usize = 0;
    var rest = body;
    while (std.mem.indexOf(u8, rest, "webview_bind(")) |index| {
        binds += 1;
        rest = rest[index + 1 ..];
    }
    try testing.expectEqual(@as(usize, 3), binds);
}

test "browser bridge: open refuses a javascript: URL and spawns nothing" {
    var rec = Recorder{};
    var bridge = testBridge(&rec);
    var out: [REPLY_BUF]u8 = undefined;

    const result = bridge.handleRequest(.open, "[\"tab_1\",\"javascript:alert(1)\"]", &out);
    try testing.expectEqualStrings(
        "{\"ok\":false,\"alive\":0,\"error\":\"only http(s) URLs can be opened\"}",
        result,
    );
    try testing.expectEqual(@as(usize, 0), rec.calls);
    try testing.expectEqual(@as(usize, 0), bridge.windowCount());
}

test "browser bridge: open refuses a file: URL and a malformed request" {
    var rec = Recorder{};
    var bridge = testBridge(&rec);
    var out: [REPLY_BUF]u8 = undefined;

    _ = bridge.handleRequest(.open, "[\"tab_1\",\"file:///etc/passwd\"]", &out);
    _ = bridge.handleRequest(.open, "not json", &out);
    _ = bridge.handleRequest(.open, "[\"tab_1\"]", &out);
    _ = bridge.handleRequest(.open, "[\"bad id!\",\"https://example.com\"]", &out);
    try testing.expectEqual(@as(usize, 0), rec.calls);
    try testing.expectEqual(@as(usize, 0), bridge.windowCount());
}

test "browser bridge: open with a valid URL records a handle under the tab id" {
    var rec = Recorder{};
    var bridge = testBridge(&rec);
    var out: [REPLY_BUF]u8 = undefined;

    const result = bridge.handleRequest(.open, "[\"tab_1\",\"https://example.com/x\"]", &out);
    try testing.expectEqualStrings("{\"ok\":true,\"alive\":1}", result);
    try testing.expectEqual(@as(usize, 1), rec.calls);
    try testing.expect(rec.saw_browser_flag);
    try testing.expectEqual(@as(usize, 3), rec.argv_len); // exe, --browser, url
    try testing.expectEqualStrings("https://example.com/x", rec.url());
    try testing.expectEqual(@as(usize, 1), bridge.windowCount());
    const window = bridge.find("tab_1") orelse return error.HandleNotRecorded;
    try testing.expect(window.used);

    // A second open for the same tab is the "1 window open" state, not a spawn.
    const again = bridge.handleRequest(.open, "[\"tab_1\",\"https://example.com/y\"]", &out);
    try testing.expectEqualStrings("{\"ok\":true,\"alive\":1}", again);
    try testing.expectEqual(@as(usize, 1), rec.calls);

    // A different tab is its own window (one window per tab).
    _ = bridge.handleRequest(.open, "[\"tab_2\",\"https://example.org\"]", &out);
    try testing.expectEqual(@as(usize, 2), rec.calls);
    try testing.expectEqual(@as(usize, 2), bridge.windowCount());
}

test "browser bridge: status is exact and unknown tab ids are not errors" {
    var rec = Recorder{};
    var bridge = testBridge(&rec);
    var out: [REPLY_BUF]u8 = undefined;

    try testing.expectEqualStrings("{\"alive\":0}", bridge.handleRequest(.status, "[\"nope\"]", &out));
    _ = bridge.handleRequest(.open, "[\"tab_1\",\"https://example.com\"]", &out);
    try testing.expectEqualStrings("{\"alive\":1}", bridge.handleRequest(.status, "[\"tab_1\"]", &out));
    // A reaped handle reads as gone, never as an error.
    const window = bridge.find("tab_1") orelse return error.HandleNotRecorded;
    window.child.id = null;
    try testing.expectEqualStrings("{\"alive\":0}", bridge.handleRequest(.status, "[\"tab_1\"]", &out));
}

test "browser bridge: close on an unknown or reaped tab id is a no-op" {
    var rec = Recorder{};
    var bridge = testBridge(&rec);
    var out: [REPLY_BUF]u8 = undefined;

    try testing.expectEqualStrings("{\"ok\":true}", bridge.handleRequest(.close, "[\"nope\"]", &out));
    _ = bridge.handleRequest(.open, "[\"tab_1\",\"https://example.com\"]", &out);
    const window = bridge.find("tab_1") orelse return error.HandleNotRecorded;
    window.child.id = null; // the window was closed from the OS
    try testing.expectEqualStrings("{\"ok\":true}", bridge.handleRequest(.close, "[\"tab_1\"]", &out));
    try testing.expectEqual(@as(usize, 0), rec.calls - 1);
}

test "browser bridge: installBindings is a no-op after the first install" {
    // Without the guard, a second install would hit WEBVIEW_ERROR_DUPLICATE and
    // leave the first callback in place — a silently half-installed bridge.
    var bridge = Bridge.init(testing.allocator, testing.io);
    try testing.expect(!bridge.installed);
    // Pretend the first install happened (the real one needs a window).
    bridge.installed = true;
    // An opaque pointer is never dereferenced on the early-return path; if the
    // guard regresses, this call reaches the vendored `webview_bind` with
    // garbage and fails loudly instead of silently double-binding.
    bridge.installBindings(@ptrFromInt(0x1000));
    try testing.expectEqual(@as(?*Webview, null), bridge.w);
}
