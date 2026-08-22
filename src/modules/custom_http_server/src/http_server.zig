const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

pub const http_parser = @import("http_parser.zig");
pub const router = @import("router.zig");
pub const security = @import("security.zig");
pub const sse_manager = @import("sse_manager.zig");
pub const ws_manager = @import("websocket_manager.zig");
pub const ws_frames = @import("websocket_frames.zig");
pub const ws_handshake = @import("websocket_handshake.zig");
pub const cronjob_manager = @import("cronjob_manager.zig");
pub const Template = @import("template.zig");
pub const readHtml = @import("read_html.zig").readHtml;
pub const context = @import("context.zig");
const gserverz_context = context;
pub const HttpRequest = http_parser.HttpRequest;
pub const HttpResponse = http_parser.HttpResponse;
pub const HttpContext = http_parser.HttpContext;
pub const Session = http_parser.Session;
pub const Context = context.Context;
pub const ContextStore = context.ContextStore;
pub const contextFromRequest = context.contextFromRequest;
pub const response = http_parser;
pub const SseManager = sse_manager.SseManager;
pub const WsManager = ws_manager.WsManager;
pub const CronjobManager = cronjob_manager.CronjobManager;
pub const WsOpcode = ws_frames.Opcode;
pub const WsConnection = ws_manager.WsClient;
// Router re-exports — let module users (and other modules referencing
// `gserverz.MiddlewareFn` / `gserverz.MiddlewareChain`) wire up groups
// and middlewares without reaching into the file-private Router module.
pub const Router = router.Router;
pub const Group = router.Group;
pub const HandlerFn = router.HandlerFn;
pub const MiddlewareFn = router.MiddlewareFn;
pub const MiddlewareChain = router.MiddlewareChain;

/// Platform abstraction for socket operations
/// On POSIX: uses std.posix.system (low-level socket API)
/// On Windows: uses ws2_32 Winsock API directly
const socket = posix.system;

/// Winsock extern declarations for Windows
const winsock = if (builtin.os.tag == .windows) struct {
    extern "ws2_32" fn WSAStartup(wVersionRequested: c_ushort, wsaData: *WSADATA) callconv(.c) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.c) c_int;
    extern "ws2_32" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) callconv(.c) c_int;
    extern "ws2_32" fn closesocket(sockfd: c_int) callconv(.c) c_int;
    extern "ws2_32" fn shutdown(sockfd: c_int, how: c_int) callconv(.c) c_int;
    extern "ws2_32" fn bind(sockfd: c_int, addr: ?*const anyopaque, addrlen: c_int) callconv(.c) c_int;
    extern "ws2_32" fn listen(sockfd: c_int, backlog: c_int) callconv(.c) c_int;
    extern "ws2_32" fn accept(sockfd: c_int, addr: ?*anyopaque, addrlen: ?*c_int) callconv(.c) c_int;
    extern "ws2_32" fn recv(sockfd: c_int, buf: ?*anyopaque, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn send(sockfd: c_int, buf: ?*const anyopaque, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_int) callconv(.c) c_int;
    extern "ws2_32" fn getpeername(sockfd: c_int, addr: ?*anyopaque, addrlen: ?*c_int) callconv(.c) c_int;

    /// WSADATA struct passed to WSAStartup. 400 bytes is the canonical
    /// size per Winsock 2 docs; the contents are intentionally ignored
    /// (we just need the call to succeed so the winsock runtime is
    /// available for subsequent socket() calls).
    const WSADATA = [400]u8;
} else struct {};

/// Winsock must be initialised with WSAStartup() before any other
/// winsock function call. Without this call, `socket()` returns
/// `INVALID_SOCKET` (WSAEINPROGRESS / WSANOTINITIALISED) on every
/// invocation. The runtime keeps an internal ref count, so calling
/// WSAStartup multiple times is safe as long as each call is paired
/// with a matching WSACleanup(). The ref-counted behaviour makes the
/// lazy-init pattern safe — every `createSocket()` calls it, but
/// the winsock DLL is only loaded once.
///
/// This block is a no-op on non-Windows targets.
var wsa_init_lock: std.atomic.Mutex = .unlocked;
var wsa_initialized: bool = false;

fn ensureWinsockInitialized() void {
    if (wsa_initialized) return;
    while (!wsa_init_lock.tryLock()) std.atomic.spinLoopHint();
    defer wsa_init_lock.unlock();
    if (wsa_initialized) return;
    var wsa_data: winsock.WSADATA = undefined;
    // MAKEWORD(2, 2) = 0x0202 — request Winsock 2.2 (the highest version
    // every Windows version since Windows 98 supports). Winsock 2 is the
    // API surface this file relies on (WSASocket/setsockopt with the
    // SOL_SOCKET/SO_REUSEADDR constants).
    const version: c_ushort = (2 << 8) | 2;
    const rc = winsock.WSAStartup(version, &wsa_data);
    if (rc != 0) {
        std.log.err("WSAStartup failed with rc={d}", .{rc});
        return;
    }
    wsa_initialized = true;
}

fn closeFd(fd: SocketFd) void {
    if (builtin.os.tag == .windows) {
        _ = winsock.closesocket(fd);
    } else {
        _ = socket.close(fd);
    }
}

/// Wake up a pending accept() call on the listener socket without closing
/// the fd. `shutdown(sock, SHUT_RDWR)` makes accept() return immediately
/// with an error on both Linux and Windows — this is the portable way to
/// unblock a listening socket.
///
/// Closing the fd from another thread does NOT reliably wake up a
/// blocked accept() on Linux (the kernel doesn't re-poll pending
/// accepts when the fd table entry is freed), and on Windows there is
/// no signal mechanism at all (Git Bash's `kill -TERM` calls
/// TerminateProcess, which is forceful — it doesn't unblock accept).
/// `shutdown(SHUT_RDWR)` works on both.
fn shutdownListenerFd(fd: SocketFd) void {
    // SHUT_RDWR = 2 on Linux, SD_BOTH = 2 on Windows. Both platforms
    // define the constant as 2 (POSIX / Win32). The literal is safe
    // because the platform-independent std.posix.SO enum is not
    // available in this project's low-level socket path (it uses
    // `std.posix.system` directly).
    const SHUT_RDWR: c_int = 2;
    if (builtin.os.tag == .windows) {
        _ = winsock.shutdown(fd, SHUT_RDWR);
    } else {
        _ = socket.shutdown(fd, SHUT_RDWR);
    }
}

const c = std.c;

/// Address family constants
const AF_INET = if (builtin.os.tag == .windows) @as(u32, 2) else posix.AF.INET;
const AF_UNIX = if (builtin.os.tag == .windows) @as(u32, 1) else posix.AF.UNIX;

/// Socket type constants
const SOCK_STREAM = if (builtin.os.tag == .windows) @as(u32, 1) else posix.SOCK.STREAM;
const IPPROTO_TCP = if (builtin.os.tag == .windows) @as(u32, 6) else posix.IPPROTO.TCP;

pub const SocketFd = i32;

pub const Address = struct {
    sock_fd: SocketFd,
    port: u16,

    pub fn init(port: u16) !Address {
        const socket_fd = try createSocket();
        errdefer closeFd(socket_fd);

        try setReuseAddr(socket_fd);
        try bindPort(port, socket_fd);

        return .{
            .sock_fd = socket_fd,
            .port = port,
        };
    }

    fn createSocket() !SocketFd {
        if (builtin.os.tag == .windows) {
            ensureWinsockInitialized();
            const fd = winsock.socket(@intCast(AF_INET), @intCast(SOCK_STREAM), @intCast(IPPROTO_TCP));
            if (fd < 0) return error.SocketCreationFailed;
            return fd;
        } else {
            const fd = socket.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (fd < 0) return error.SocketCreationFailed;
            return @as(i32, @intCast(fd));
        }
    }

    fn setReuseAddr(sock_fd: SocketFd) !void {
        if (builtin.os.tag == .windows) {
            const opt: c_int = 1;
            const rc = winsock.setsockopt(sock_fd, 0xffff, 4, &opt, @sizeOf(c_int));
            if (rc != 0) return error.SetSockOptFailed;
        } else {
            // Use the OS-correct SOL_SOCKET / SO_REUSEADDR constants from
            // std.posix (which routes to std.os.<platform>.SO). The previous
            // hardcoded `1, 2` happened to be `SOL_SOCKET, SO_DEBUG` on
            // Linux (silently succeeded — DEBUG is a benign no-op-ish
            // option) but was `SOL_SOCKET, SO_TYPE` on macOS, which is an
            // invalid direction on a listen socket and triggers an
            // `INVAL` in `posix.setsockopt`'s switch — the `unreachable`
            // arm crashes the process during GinwaServer.init().
            //
            // sys/socket.h SOL_SOCKET = 1 on Linux and 0xffff on macOS;
            // SO_REUSEADDR = 0x0004 on both. Using the standard library's
            // os-tagged aliases keeps both platforms correct.
            const opt: i32 = 1;
            try posix.setsockopt(
                sock_fd,
                @intCast(posix.SOL.SOCKET),
                @intCast(posix.SO.REUSEADDR),
                std.mem.asBytes(&opt),
            );
        }
    }

    fn bindPort(port: u16, sock_fd: SocketFd) !void {
        // Create sockaddr_in structure manually for portability
        // port must be in network byte order (big-endian)
        var sockaddr: socket.sockaddr.in = .{
            .family = 2, // AF_INET
            .port = @byteSwap(port), // Convert to network byte order
            .addr = @bitCast(@as(u32, 0x0100007f)), // 127.0.0.1 in little-endian
            .zero = undefined,
        };

        if (builtin.os.tag == .windows) {
            const rc = winsock.bind(sock_fd, @ptrCast(&sockaddr), @sizeOf(socket.sockaddr.in));
            if (rc != 0) return error.BindFailed;
        } else {
            const rc = socket.bind(sock_fd, @ptrCast(&sockaddr), @sizeOf(socket.sockaddr.in));
            if (rc < 0) return error.BindFailed;
        }
    }
};

pub const GinwaServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    address: Address,
    router: router.Router,
    sse_manager: SseManager,
    ws_manager: *WsManager,
    /// In-process scheduler for cron-syntax callbacks. Started by
    /// `listen()` and stopped by `deinit()`. See `cronjob_manager.zig`.
    cronjob_manager: CronjobManager,
    ctx: ?*anyopaque = null,
    environment: ?*const std.process.Environ.Map = null,
    is_running: bool = false,

    /// Server-side ContextStore passed to handlers via `HttpContext`.
    /// Always non-null after a successful `init()` — the server heap-
    /// allocates the store on init and deinits it on `deinit()` so
    /// callers don't have to manage its lifetime. Handlers that don't
    /// use cross-redirect state can simply ignore it. The pointer is
    /// typed as optional to preserve the existing `Session.set`
    /// `error.NoContextStore` contract (defensive — the listen loop
    /// always populates `Session.context_store` from this field).
    context_store: ?*gserverz_context.ContextStore = null,

    /// HMAC secret used by `security.csrfTokenIssue` / `csrfTokenValidate`.
    /// Defaults to a dev-only constant; production deployments should
    /// override via `server.csrf_secret = "..."` after `GinwaServer.init`.
    csrf_secret: []const u8 = "dev-only-csrf-secret-change-in-prod",

    /// Server-wide CORS configuration. Defaults to "CORS off" (same-origin
    /// only) so existing routes are unchanged. Configure after init:
    ///   server.cors = .{ .enabled = true, .allowed_origins = &.{"..."} };
    /// See `CORSConfig` for the full surface.
    cors: CORSConfig = .{},

    /// Optional fallback handler invoked when no route matches. It is
    /// expected to write a complete HTTP response directly to `fd` (status
    /// line, headers, body) — the listen loop will NOT call toBytes() /
    /// sendToClient afterwards. Used by `--static-dir` to serve files for
    /// any path that isn't claimed by an API route.
    ///
    /// The first argument is an opaque user pointer — typically a pointer
    /// to whatever config struct the handler needs (e.g. a static-files
    /// config). The handler is responsible for casting it back to the
    /// concrete type. This keeps the HTTP server free of any specific
    /// feature's types.
    ///
    /// The per-request `allocator` is passed in so the response buffer
    /// can be arena-freed when the request finishes.
    static_dir_handler: ?*const fn (
        cfg: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        request_path: []const u8,
        range_header: ?[]const u8,
        fd: SocketFd,
    ) anyerror!void = null,
    /// Opaque cfg pointer forwarded to `static_dir_handler`. Set together
    /// with the handler via `setStaticDirHandler`.
    static_dir_cfg: ?*const anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, address: Address) !*GinwaServer {
        const gs = try allocator.create(GinwaServer);
        errdefer allocator.destroy(gs);

        // Heap-allocate the cross-redirect ContextStore eagerly so
        // handlers can use `Session.set` / `redirectWithContext` without
        // any per-server wiring. The pointer is stored on `gs` and
        // freed by `deinit()` — callers (e.g. main.zig) never have to
        // touch it. Tests that don't need a store still get one (it's
        // just an empty StringHashMap); the cost is one allocation.
        const store = try gserverz_context.ContextStore.create(allocator);
        errdefer store.deinit();

        gs.* = .{
            .allocator = allocator,
            .io = io,
            .address = address,
            .router = router.Router.init(allocator),
            .sse_manager = try SseManager.init(allocator, allocator, io),
            .ws_manager = try WsManager.init(allocator, allocator, io),
            .cronjob_manager = CronjobManager.init(allocator, io),
            .ctx = null,
            .environment = null,
            .context_store = store,
        };
        return gs;
    }

    /// Wire a static-files fallback handler. Pass `null` for the handler
    /// to clear both `static_dir_handler` and `static_dir_cfg`.
    /// See the `static_dir_handler` field doc for the handler contract.
    pub fn setStaticDirHandler(
        self: *GinwaServer,
        handler: ?*const fn (
            cfg: *const anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            request_path: []const u8,
            range_header: ?[]const u8,
            fd: SocketFd,
        ) anyerror!void,
        cfg: ?*const anyopaque,
    ) void {
        self.static_dir_handler = handler;
        self.static_dir_cfg = cfg;
    }

    pub fn deinit(self: *GinwaServer) void {
        // Order matters: stop the cronjob thread BEFORE freeing its
        // registry (the tick thread holds a pointer to `self`).
        self.cronjob_manager.stop();
        self.cronjob_manager.deinit();
        self.sse_manager.gracefulShutdown();
        self.sse_manager.deinit();
        self.ws_manager.destroy();
        self.router.deinit();
        // Drop the auto-allocated ContextStore last — it owns no threads
        // and only references the server's allocator, so it can free
        // safely after every other subsystem has shut down.
        if (self.context_store) |store| store.deinit();
    }

    /// Free the GinwaServer struct itself. Callers that allocated the
    /// server with `init(...)` (which calls `allocator.create(GinwaServer)`)
    /// MUST call this to release the struct memory — `deinit()` only cleans
    /// up the server's internal state. This method calls `deinit()` first
    /// so that `destroy(allocator)` is a complete release (sse_manager +
    /// router + struct memory).
    pub fn destroy(self: *GinwaServer, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    pub fn listen(self: *GinwaServer) !void {
        if (builtin.os.tag == .windows) {
            const rc = winsock.listen(self.address.sock_fd, 128);
            if (rc != 0) return error.ListenFailed;
        } else {
            const rc = socket.listen(self.address.sock_fd, 128);
            if (rc < 0) return error.ListenFailed;
        }

        // Start the cronjob tick thread BEFORE accepting connections so
        // scheduled jobs can begin firing immediately. A start failure
        // is logged but does not abort listening — the manager is
        // best-effort (callers can still drive jobs manually via `tick`).
        if (self.cronjob_manager.start()) |_| {
            std.debug.print("Cronjob manager running (1s tick)\n", .{});
        } else |err| {
            std.debug.print("HTTP_SERVER: cronjob manager start failed: {s}\n", .{@errorName(err)});
        }

        var group: std.Io.Group = .init;
        errdefer group.cancel(self.io);

        self.is_running = true;
        while (self.is_running) {
            const client_fd = self.acceptClient() catch break;

            const arena = self.allocator.create(std.heap.ArenaAllocator) catch {
                _ = closeFd(client_fd);
                continue;
            };
            arena.* = std.heap.ArenaAllocator.init(self.allocator);

            group.concurrent(
                self.io,
                struct {
                    fn handle(server: *GinwaServer, arena_allocator: *std.heap.ArenaAllocator, fd: SocketFd) void {
                        defer {
                            arena_allocator.deinit();
                            server.allocator.destroy(arena_allocator);
                        }

                        const allocator = arena_allocator.allocator();

                        var rb = RequestBuffer.init(allocator);
                        defer rb.deinit();

                        const request_data = rb.readFullRequest(fd) catch |err| {
                            std.debug.print("HTTP_SERVER: readFullRequest failed: {s}\n", .{@errorName(err)});
                            _ = closeFd(fd);
                            return;
                        };
                        defer allocator.free(request_data);

                        var req = http_parser.parseRequest(request_data, allocator, server.io, fd) catch |err| {
                            std.debug.print("HTTP_SERVER: parseRequest failed: {s}\n", .{@errorName(err)});
                            _ = closeFd(fd);
                            return;
                        };
                        defer req.headers.deinit();

                        const http_ctx = http_parser.HttpContext{
                            .allocator = allocator,
                            .io = server.io,
                        };
                        // Build the Session right after parsing. `incoming`
                        // is populated from the Cookie header via
                        // `contextFromRequest` so handlers can `session.getString`
                        // without knowing about cookies, ContextStore, or
                        // contextFromRequest. When the server has no
                        // `context_store` wired, Session.context_store is
                        // `null` and `session.set` returns
                        // `error.NoContextStore` (handlers that need set
                        // don't register against a no-store server).
                        const lookup: context.LookupResult = if (server.context_store) |store|
                            context.contextFromRequest(req, store)
                        else
                            .{ .context = null, .id = null };
                        var session = http_parser.Session.init(
                            server.context_store,
                            lookup.context,
                            lookup.id,
                        );
                        defer session.deinit();
                        // Wire the session into the request so handlers can
                        // call `req.session.set / getString` directly. The
                        // pointer outlives the listen loop's handle scope.
                        req.session = &session;

                        // CORS preflight: when CORS is enabled and the
                        // request is OPTIONS, reply with the configured
                        // `Access-Control-*` headers and short-circuit
                        // before the router sees the request. Preflight
                        // is browser-driven and doesn't carry a route
                        // match, so handling it globally keeps route
                        // registration simple.
                        if (server.cors.enabled and std.mem.eql(u8, req.method, "OPTIONS")) {
                            const preflight = server.buildCORSPreflight(&req, allocator) catch |err| {
                                std.debug.print("HTTP_SERVER: buildCORSPreflight failed: {s}\n", .{@errorName(err)});
                                _ = closeFd(fd);
                                return;
                            };
                            const preflight_bytes = preflight.toBytes() catch {
                                std.debug.print("HTTP_SERVER: preflight toBytes failed\n", .{});
                                _ = closeFd(fd);
                                return;
                            };
                            defer preflight.allocator.free(preflight_bytes);
                            _ = server.sendToClient(fd, preflight_bytes) catch {
                                std.debug.print("HTTP_SERVER: preflight send failed\n", .{});
                            };
                            return;
                        }

                        if (server.router.matchRoute(req.method, req.path, &req, http_ctx)) |result| {
                            switch (result) {
                                .handler => |h| {
                                    // Run the per-request middleware chain. When the
                                    // route has no middleware the chain dispatches
                                    // straight to the final handler — same behavior
                                    // as before groups/middleware were added. When
                                    // middlewares exist they run in registration
                                    // order (outermost group first, innermost last);
                                    // a middleware that returns without calling
                                    // `chain.next(...)` short-circuits the chain.
                                    var final_res = h.chain.run(h.ctx, h.req, h.res) catch http_parser.internalError("Handler error", allocator);

                                    // CORS response headers — only when CORS is
                                    // enabled and the request carried an Origin
                                    // that matches `cors.allowed_origins`.
                                    server.applyCORSResponse(&h.req, &final_res) catch @panic("OOM");

                                    const res_bytes = final_res.toBytes() catch {
                                        std.debug.print("Failed to build response\n", .{});
                                        _ = closeFd(fd);
                                        return;
                                    };
                                    defer final_res.allocator.free(res_bytes);
                                    _ = server.sendToClient(fd, res_bytes) catch {
                                        std.debug.print("Failed to send response\n", .{});
                                    };
                                },
                                .websocket => |ws| {
                                    // WebSocket upgrade path. We must:
                                    //   1. Validate the request is a valid upgrade (RFC 6455 §4.1).
                                    //   2. Send the 101 response with the computed Accept.
                                    //   3. Register the client with the WsManager (so broadcasts
                                    //      and targeted sends work).
                                    //   4. Run the handler in the current per-connection worker.
                                    //   5. Send a close frame and remove from registry on return.
                                    if (!ws_handshake.isWebSocketRequest(&req)) {
                                        const bad = http_parser.badRequest("WebSocket upgrade required", allocator);
                                        const bytes = bad.toBytes() catch {
                                            _ = closeFd(fd);
                                            return;
                                        };
                                        defer bad.allocator.free(bytes);
                                        _ = server.sendToClient(fd, bytes) catch {};
                                        _ = closeFd(fd);
                                        return;
                                    }

                                    const key = ws_handshake.extractWebSocketKey(&req) catch {
                                        _ = closeFd(fd);
                                        return;
                                    };
                                    const accept_resp = ws_handshake.buildAcceptResponse(allocator, key) catch {
                                        _ = closeFd(fd);
                                        return;
                                    };
                                    defer allocator.free(accept_resp);

                                    _ = server.sendToClient(fd, accept_resp) catch {
                                        _ = closeFd(fd);
                                        return;
                                    };

                                    // Register the client with the WsManager. The write callback bridges
                                    // the manager's `fn(ctx, fd, data)` API to the server's
                                    // `sendToClient` method via the ctx pointer.
                                    const WriteAdapter = struct {
                                        fn w(ctx: ?*anyopaque, target_fd: i32, data: []const u8) anyerror!usize {
                                            const server_ptr: *GinwaServer = @ptrCast(@alignCast(ctx.?));
                                            return server_ptr.sendToClient(target_fd, data);
                                        }
                                    }.w;
                                    var client_id = server.ws_manager.registerClient(fd, WriteAdapter, @ptrCast(server)) catch {
                                        _ = closeFd(fd);
                                        return;
                                    };

                                    // Run the user handler.
                                    ws.handler(ws.ctx, ws.req, @ptrCast(server), fd, &client_id) catch |err| {
                                        std.debug.print("WebSocket handler error: {s}\n", .{@errorName(err)});
                                    };

                                    // Send a close frame and remove from registry. The client
                                    // arena is freed by removeClient.
                                    const close_payload = "\x03\xe8"; // status 1000 normal closure
                                    const close_frame = ws_frames.encodeFrame(allocator, .{
                                        .opcode = .close,
                                        .payload = close_payload,
                                    }) catch null;
                                    if (close_frame) |cf| {
                                        defer allocator.free(cf);
                                        _ = server.sendToClient(fd, cf) catch {};
                                    }
                                    server.ws_manager.removeClient(&client_id, .explicit);
                                    return;
                                },
                                .sse => |sse| {
                                    const headers = "HTTP/1.1 200 OK\r\n" ++
                                        "Content-Type: text/event-stream\r\n" ++
                                        "Cache-Control: no-cache\r\n" ++
                                        // Connection: close (NOT keep-alive). SSE is a single-use,
                                        // long-lived stream — the connection is never reused for a
                                        // follow-up request, so advertising keep-alive confuses
                                        // intermediaries. Vite (Node.js) in dev mode stamps
                                        // `Keep-Alive: timeout=5` on keep-alive responses, and some
                                        // browser/webview engines (Chromium, WebKitGTK, WKWebView)
                                        // enforce that timeout aggressively — closing the upstream
                                        // socket ~5s after the last heartbeat. Empirically this
                                        // matches the user's reported pattern of heartbeats
                                        // stopping after ~30s in the browser DevTools. Telling
                                        // intermediaries this connection will close on EOF keeps
                                        // the stream open for as long as the backend keeps
                                        // sending chunked frames.
                                        "Connection: close\r\n" ++
                                        // Required by HTTP/1.1: a response with neither Content-Length
                                        // nor Transfer-Encoding is implicitly framed by connection-close.
                                        // For SSE we never close the connection voluntarily, so we MUST
                                        // declare chunked encoding. Otherwise Vite / proxies / browsers
                                        // will misinterpret the response and surface
                                        // ERR_INCOMPLETE_CHUNKED_ENCODING on disconnect.
                                        "Transfer-Encoding: chunked\r\n" ++
                                        // Tell intermediaries (Vite, nginx, Cloudflare, ALB) not to
                                        // buffer. X-Accel-Buffering is the de-facto convention.
                                        "X-Accel-Buffering: no\r\n" ++
                                        "Access-Control-Allow-Origin: *\r\n" ++
                                        "\r\n";
                                    _ = server.sendToClient(fd, headers) catch {
                                        _ = closeFd(fd);
                                        return;
                                    };
                                    const client_id = server.sse_manager.registerClient(fd) catch {
                                        _ = closeFd(fd);
                                        return;
                                    };
                                    var sse_ctx = sse.ctx;
                                    sse_ctx.client_id = client_id;
                                    const res = http_parser.HttpResponse.init(200, "OK", allocator);
                                    _ = sse.handler(sse_ctx, sse.req, res) catch |err| {
                                        if (err != error.WouldBlock) {
                                            std.debug.print("SSE handler error: {s}\n", .{@errorName(err)});
                                        }
                                    };
                                    return;
                                },
                            }
                        } else {
                            // No API route matched. If a static-dir fallback
                            // handler is configured, hand the request off to
                            // it. The handler is responsible for writing a
                            // complete HTTP response directly to `fd` (it
                            // owns the wire format from status line through
                            // body) and for sending it. We only fall through
                            // to the generic 404 if the handler is absent,
                            // missing its cfg, or reports an error.
                            var static_served = false;
                            if (server.static_dir_handler) |handler| {
                                if (server.static_dir_cfg) |cfg| {
                                    // HTTP header names are case-insensitive
                                    // per RFC 9110 §5.1, but the gserverz
                                    // preserves the case the client sent.
                                    // Walk the headers map and match
                                    // case-insensitively so the static-file
                                    // handler gets a `Range:` value
                                    // regardless of whether the client sent
                                    // "Range", "range", or "RANGE".
                                    var range_hdr: ?[]const u8 = null;
                                    var h_it = req.headers.iterator();
                                    while (h_it.next()) |entry| {
                                        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "range")) {
                                            range_hdr = entry.value_ptr.*;
                                            break;
                                        }
                                    }
                                    handler(cfg, allocator, server.io, req.path, range_hdr, fd) catch {
                                        static_served = false;
                                    };
                                    // If the handler returned without error,
                                    // trust it to have sent a response
                                    // (matching the SSE branch's contract).
                                    static_served = true;
                                }
                            }
                            if (!static_served) {
                                var not_found = http_parser.notFound(allocator);
                                // Attach CORS headers to the 404 so cross-origin
                                // callers see the rejection (with CORS headers
                                // echoed) instead of an opaque browser-blocked
                                // response.
                                server.applyCORSResponse(&req, &not_found) catch @panic("OOM");
                                const res_bytes = not_found.toBytes() catch {
                                    _ = closeFd(fd);
                                    return;
                                };
                                defer not_found.allocator.free(res_bytes);
                                _ = server.sendToClient(fd, res_bytes) catch {};
                            }
                        }

                        _ = closeFd(fd);
                    }
                }.handle,
                .{ self, arena, client_fd },
            ) catch |err| {
                std.debug.print("Failed to spawn handler: {s}\n", .{@errorName(err)});
                arena.deinit();
                self.allocator.destroy(arena);
                _ = closeFd(client_fd);
                continue;
            };
        }

        try group.await(self.io);
    }

    pub fn getContentLength(data: []const u8) ?usize {
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        const headers = data[0..header_end];
        const cl_header = "Content-Length: ";
        const cl_pos = std.mem.indexOf(u8, headers, cl_header) orelse return null;
        const cl_start = cl_pos + cl_header.len;
        // Look for \r\n after the value, or use end of headers if that's the line ending
        const after_value = headers[cl_start..];
        const cl_end = std.mem.indexOf(u8, after_value, "\r\n") orelse after_value.len;
        const cl_str = headers[cl_start .. cl_start + cl_end];
        return std.fmt.parseInt(usize, cl_str, 10) catch null;
    }

    fn isHttpRequestComplete(data: []const u8) bool {
        // Find end of headers
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
        const headers = data[0..header_end];

        // No Content-Length means no body (GET, OPTIONS, etc.)
        const cl_header = "Content-Length: ";
        const cl_pos = std.mem.indexOf(u8, headers, cl_header) orelse return true;
        const cl_start = cl_pos + cl_header.len;
        const cl_end = std.mem.indexOf(u8, headers[cl_start..], "\r\n") orelse return false;
        const cl_str = headers[cl_start .. cl_start + cl_end];
        const content_length = std.fmt.parseInt(usize, cl_str, 10) catch return false;

        // Check body bytes received
        const body_start = header_end + 4;
        return data.len >= body_start + content_length;
    }

    fn acceptClient(self: *GinwaServer) !SocketFd {
        const fd: SocketFd = blk: {
            if (builtin.os.tag == .windows) {
                var client_addr: socket.sockaddr.in = undefined;
                var addr_len: c_int = @sizeOf(socket.sockaddr.in);
                const rc = winsock.accept(self.address.sock_fd, @ptrCast(&client_addr), &addr_len);
                if (rc < 0) return error.AcceptFailed;
                break :blk rc;
            } else {
                var client_addr: posix.sockaddr.in = undefined;
                var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
                const rc = socket.accept(self.address.sock_fd, @ptrCast(&client_addr), &addr_len);
                if (rc < 0) return error.AcceptFailed;
                break :blk @intCast(rc);
            }
        };

        // Enable TCP keepalive on the accepted client socket so a
        // silently-dropped connection (Wi-Fi loss, NAT table expiry,
        // half-open TCP after a peer crash) is detected by the kernel
        // within ~25s instead of relying solely on the application-
        // level heartbeat (every 5s in `SseManager.sendHeartbeat`).
        //
        // Without keepalive, the server keeps heartbeating into a dead
        // socket until the next write fails with EPIPE / ECONNRESET,
        // which can be hours later (Linux default `tcp_keepalive_time`
        // is 7200s). On a long-idle page that hits a silent network
        // drop, the eventual disconnect surfaces in the browser as
        // `net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` because the
        // chunked terminator is only flushed by `removeClient` once
        // the kernel finally tells us the peer is gone.
        //
        // Settings mirror `Agent.apply_tcp_keepalive`
        // (`src/modules/agent/Agent.zig:793`) so outbound LLM conns
        // and inbound browser conns fail at the same rate:
        //   keepidle  = 10s  (first probe after 10s of idle)
        //   keepintvl = 5s   (probe interval)
        //   keepcnt   = 3    (give up after 3 failed probes)
        //   → dead-conn detection in ~10 + 5*3 = 25s.
        //
        // `setsockopt` failures are best-effort: the application-
        // level heartbeat (5s) still works without OS keepalive, it
        // just won't catch silent drops as quickly.
        const on: c_int = 1;
        const keepidle: c_int = 10;
        const keepintvl: c_int = 5;
        const keepcnt: c_int = 3;
        if (builtin.os.tag == .windows) {
            _ = winsock.setsockopt(fd, 0xffff, 8, &on, @sizeOf(c_int));
            _ = winsock.setsockopt(fd, 6, 3, &keepidle, @sizeOf(c_int));
            _ = winsock.setsockopt(fd, 6, 17, &keepintvl, @sizeOf(c_int));
            _ = winsock.setsockopt(fd, 6, 16, &keepcnt, @sizeOf(c_int));
        } else {
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&on)) catch {};
            // TCP keepalive tuning. KEEPIDLE / KEEPINTVL / KEEPCNT are
            // Linux-only — macOS doesn't have them (it uses
            // SO_KEEPALIVE's default 2h idle, which works fine in
            // practice). Zig 0.16's cross-target module compile
            // (mod=x86_64-linux-gnu inside exe=aarch64-macos) checks
            // the struct membership against the ROOT target, so even
            // an unreachable reference is a compile error on macOS.
            // The `if (comptime builtin.os.tag == .linux)` block
            // scopes the std.os.linux.TCP_* references inside it; the
            // else branch (macOS / BSD) skips them entirely.
            if (comptime builtin.os.tag == .linux) {
                posix.setsockopt(fd, posix.IPPROTO.TCP, @as(i32, @intCast(std.os.linux.TCP.KEEPIDLE)), std.mem.asBytes(&keepidle)) catch {};
                posix.setsockopt(fd, posix.IPPROTO.TCP, @as(i32, @intCast(std.os.linux.TCP.KEEPINTVL)), std.mem.asBytes(&keepintvl)) catch {};
                posix.setsockopt(fd, posix.IPPROTO.TCP, @as(i32, @intCast(std.os.linux.TCP.KEEPCNT)), std.mem.asBytes(&keepcnt)) catch {};
            }
        }

        return fd;
    }

    pub fn recvFromClient(_: *GinwaServer, fd: SocketFd, buf: []u8) !usize {
        if (builtin.os.tag == .windows) {
            const rc = winsock.recv(fd, buf.ptr, @intCast(buf.len), 0);
            if (rc < 0) return error.RecvFailed;
            return @as(usize, @intCast(rc));
        } else {
            const rc = socket.read(fd, buf.ptr, buf.len);
            if (rc < 0) return error.RecvFailed;
            return @as(usize, @intCast(rc));
        }
    }

    pub fn sendToClient(_: *GinwaServer, fd: SocketFd, data: []const u8) !usize {
        if (builtin.os.tag == .windows) {
            const rc = winsock.send(fd, data.ptr, @intCast(data.len), 0);
            if (rc < 0) return error.SendFailed;
            return @as(usize, @intCast(rc));
        } else {
            const rc = socket.write(fd, data.ptr, data.len);
            if (rc < 0) return error.SendFailed;
            return @as(usize, @intCast(rc));
        }
    }

    pub fn getClientPort(_: *GinwaServer, fd: SocketFd) u16 {
        if (builtin.os.tag == .windows) {
            var addr: socket.sockaddr.in = undefined;
            var addr_len: c_int = @sizeOf(socket.sockaddr.in);
            const rc = winsock.getpeername(fd, @ptrCast(&addr), &addr_len);
            if (rc != 0) return 0;
            return @byteSwap(addr.port);
        } else {
            // Zig 0.16's `posix.getpeername` panics on `.BADF` (it marks
            // that error branch as `unreachable` per the `// always a race
            // condition` comment at `std/posix.zig:530`). Guard the call
            // with an explicit fd validity check so callers passing -1
            // (or any other negative fd) get the historical "0 means
            // unknown port" return value rather than crashing the process.
            if (fd < 0) return 0;

            // For valid fds, Zig 0.16's `posix.getpeername` returns an
            // error union. Catch any of FileDescriptorNotASocket /
            // NetworkDown / SocketNotBound / SocketUnconnected /
            // SystemResources / Unexpected and return 0 — matches the
            // original contract for non-connected sockets.
            var addr: posix.sockaddr.in = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const rc = posix.getpeername(fd, @ptrCast(&addr), &addr_len) catch return 0;
            _ = rc;
            return @byteSwap(addr.port);
        }
    }

    pub fn shutdown(self: *GinwaServer) void {
        self.is_running = false;
        // Unblock the listen loop's blocking accept() call so the
        // loop notices the is_running flag flip and breaks out.
        //
        // Just `close(sock_fd)` is NOT enough: closing the fd in one
        // thread does not reliably wake a `accept()` that another
        // thread is blocked on (Linux's kernel doesn't re-poll
        // pending accepts when the fd table entry is freed — the
        // blocked accept stays parked). On Windows, `close()` is
        // `closesocket()`, but Windows has no signal mechanism to
        // break the accept either.
        //
        // The portable fix is `shutdown(sock, SHUT_RDWR)` — this
        // actively closes the connection state on both Linux and
        // Winsock, which makes any pending `accept()` return
        // immediately with an error. We then `closeFd` to free the
        // kernel resource.
        //
        // Idempotent: safe to call multiple times — a second call
        // sees sock_fd == -1 and is a no-op.
        if (self.address.sock_fd != -1) {
            shutdownListenerFd(self.address.sock_fd);
            closeFd(self.address.sock_fd);
            self.address.sock_fd = -1;
        }
    }

    /// Apply CORS response headers to a response built elsewhere (a
    /// handler return, a 404 fallback). Thin shim that forwards to
    /// `security.applyCORSResponse`.
    fn applyCORSResponse(self: *GinwaServer, request: *const HttpRequest, resp: *HttpResponse) !void {
        return security.applyCORSResponse(resp, request, self.cors);
    }

    /// Build a `204 No Content` CORS preflight response. Thin shim
    /// that forwards to `security.buildPreflightResponse`.
    fn buildCORSPreflight(self: *GinwaServer, request: *const HttpRequest, allocator: std.mem.Allocator) !HttpResponse {
        return security.buildPreflightResponse(allocator, request, self.cors);
    }
};

fn recvFromSock(fd: SocketFd, buf: [*]u8, len: usize) isize {
    if (builtin.os.tag == .windows) {
        return winsock.recv(fd, buf, @intCast(len), 0);
    } else {
        return socket.read(fd, buf, len);
    }
}

/// Request buffer with auto-growing capability for reading HTTP requests
pub const RequestBuffer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    tmp: [4096]u8,

    /// Initialize a new RequestBuffer
    pub fn init(allocator: std.mem.Allocator) RequestBuffer {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .tmp = undefined,
        };
    }

    /// Free all resources
    pub fn deinit(self: *RequestBuffer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn getContentLength(data: []const u8) ?usize {
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        const headers = data[0..header_end];

        // Scan header lines for a case-insensitive "content-length" prefix.
        // Matches the case-insensitive scan in `readFullRequest` below
        // so a static call sees the same answer as the streaming call.
        var cl_pos: ?usize = null;
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            if (line.len >= 15 and std.ascii.eqlIgnoreCase(line[0..14], "content-length")) {
                cl_pos = @intCast(line.ptr - headers.ptr);
                break;
            }
        }
        if (cl_pos == null) {
            return null;
        }

        const cl_start = cl_pos.? + 14; // skip "content-length"

        // Skip the colon + OWS (optional whitespace per RFC 7230 §3.2.3)
        var actual_start = cl_start;
        while (actual_start < headers.len and
            (headers[actual_start] == ':' or
            headers[actual_start] == ' ' or
            headers[actual_start] == '\t'))
        {
            actual_start += 1;
        }

        const after_value = headers[actual_start..];

        // Find end of line
        var end_idx: usize = 0;
        while (end_idx < after_value.len and after_value[end_idx] != '\r' and after_value[end_idx] != '\n') {
            end_idx += 1;
        }

        const cl_str = after_value[0..end_idx];
        return std.fmt.parseInt(usize, cl_str, 10) catch null;
    }

    /// Read the full HTTP request (headers + body) from a socket
    /// Returns the complete request data or an error
    pub fn readFullRequest(self: *RequestBuffer, fd: SocketFd) ![]u8 {
        // Phase 1: read until we have complete headers
        while (std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") == null) {
            const n = recvFromSock(fd, &self.tmp, self.tmp.len);
            if (n < 0) return error.RecvFailed;
            if (n == 0) break;
            try self.buf.appendSlice(self.allocator, self.tmp[0..@as(usize, @intCast(n))]);
        }

        const header_end_idx = std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") orelse {
            if (self.buf.items.len == 0) return error.ConnectionClosed;
            return self.buf.toOwnedSlice(self.allocator);
        };

        // Phase 2: parse Content-Length by scanning header lines
        const content_length = blk: {
            const header_section = self.buf.items[0..header_end_idx];
            var lines = std.mem.splitSequence(u8, header_section, "\r\n");
            _ = lines.next(); // skip request line
            while (lines.next()) |line| {
                // Case-insensitive match for "content-length"
                if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..14], "content-length")) {
                    // Find the colon, skip it and any whitespace
                    const colon_pos = std.mem.indexOf(u8, line, ":") orelse continue;
                    const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
                    break :blk std.fmt.parseInt(usize, value, 10) catch {
                        return error.BadRequest;
                    };
                }
            }
            // No Content-Length header found (e.g. GET request)
            return self.buf.toOwnedSlice(self.allocator);
        };

        // Phase 3: read body
        const target_len = header_end_idx + 4 + content_length;

        while (self.buf.items.len < target_len) {
            const remaining_bytes = target_len - self.buf.items.len;
            const to_read = @min(remaining_bytes, self.tmp.len);
            const n = recvFromSock(fd, &self.tmp, to_read);
            if (n < 0) return error.RecvFailed;
            if (n == 0) break;
            try self.buf.appendSlice(self.allocator, self.tmp[0..@as(usize, @intCast(n))]);
        }

        return self.buf.toOwnedSlice(self.allocator);
    }
};

/// SSE Event structure
pub const SseEvent = struct {
    data: []const u8,
    event_type: ?[]const u8 = null,
};

// ═══════════════════════════════════════════════════════════════════════════
//  CORS configuration
// ═══════════════════════════════════════════════════════════════════════════

/// CORS (Cross-Origin Resource Sharing) configuration applied server-wide
/// when `enabled` is true. Defaults to "CORS off" — same-origin only — so
/// existing routes keep working with no behaviour change.
///
/// Configure after `GinwaServer.init`:
///   server.cors = .{
///       .enabled = true,
///       .allowed_origins = &.{ "localhost:4021", "app.example.com" },
///       .allow_credentials = true,
///   };
///
/// When `enabled`:
///   * `OPTIONS <path>` requests are auto-answered with the configured
///     methods + headers + max_age (`204 No Content`).
///   * Every response carries `Access-Control-Allow-Origin` (echoed from
///     the request Origin) when the Origin matches an `allowed_origins`
///     entry; requests with mismatched Origin are rejected with `403`.
///   * `Vary: Origin` is attached so caches don't leak across origins.
///
/// The pure helper functions live in `security.zig`
/// (`security.buildPreflightResponse`, `security.buildPreHandlerFailRedirect`,
/// `security.applyCORSResponse`) — this type is a thin field-mirror so
/// `GinwaServer.cors` can be forwarded by value into those helpers.
pub const CORSConfig = security.CORSConfig;
