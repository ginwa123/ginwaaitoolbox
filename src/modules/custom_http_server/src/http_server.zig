const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

pub const http_parser = @import("http_parser.zig");
const router = @import("router.zig");
pub const sse_manager = @import("sse_manager.zig");
pub const HttpRequest = http_parser.HttpRequest;
pub const HttpResponse = http_parser.HttpResponse;
pub const HttpContext = http_parser.HttpContext;
pub const response = http_parser;
pub const SseManager = sse_manager.SseManager;

/// Platform abstraction for socket operations
/// On Linux: uses std.posix.system (low-level Linux socket API)
/// On macOS/BSD: uses Darwin socket API via std.posix.system
/// On Windows: uses Windows socket API via std.posix.system (with adaptations)
const socket = posix.system;
const c = std.c;

/// Address family constants
const AF_INET = if (builtin.os.tag == .windows) @as(u32, 2) else posix.AF.INET;
const AF_UNIX = if (builtin.os.tag == .windows) @as(u32, 1) else posix.AF.UNIX;

/// Socket type constants
const SOCK_STREAM = if (builtin.os.tag == .windows) @as(u32, 1) else posix.SOCK.STREAM;
const IPPROTO_TCP = if (builtin.os.tag == .windows) @as(u32, 6) else posix.IPPROTO.TCP;

/// SOL_SOCKET
const SOL_SOCKET = if (builtin.os.tag == .windows) @as(i32, 0xffff) else @as(i32, 1);
/// SO_REUSEADDR
const SO_REUSEADDR = if (builtin.os.tag == .windows) @as(u32, 4) else @as(u32, 2);

pub const Address = struct {
    sock_fd: i32,
    port: u16,

    pub fn init(port: u16) !Address {
        const socket_fd = try createSocket();
        errdefer _ = socket.close(socket_fd);

        try setReuseAddr(socket_fd);
        try bind(port, socket_fd);

        return .{
            .sock_fd = socket_fd,
            .port = port,
        };
    }

    fn createSocket() !i32 {
        const fd = socket.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) return error.SocketCreationFailed;
        return @as(i32, @intCast(fd));
    }

    fn setReuseAddr(sock_fd: i32) !void {
        const opt: i32 = 1;
        // SOL_SOCKET = 1, SO_REUSEADDR = 2
        try posix.setsockopt(sock_fd, 1, 2, std.mem.asBytes(&opt));
    }

    fn bind(port: u16, sock_fd: i32) !void {
        // Create sockaddr_in structure manually for portability
        // port must be in network byte order (big-endian)
        var sockaddr: socket.sockaddr.in = .{
            .family = 2, // AF_INET
            .port = @byteSwap(port), // Convert to network byte order
            .addr = @bitCast(@as(u32, 0x0100007f)), // 127.0.0.1 in little-endian
            .zero = undefined,
        };

        const rc = socket.bind(sock_fd, @ptrCast(&sockaddr), @sizeOf(socket.sockaddr.in));
        if (rc < 0) return error.BindFailed;
    }
};

pub const GinwaServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    address: Address,
    router: router.Router,
    sse_manager: SseManager,
    ctx: ?*anyopaque = null,
    environment: ?*const std.process.Environ.Map = null,
    is_running: bool = false,

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
        fd: i32,
    ) anyerror!void = null,
    /// Opaque cfg pointer forwarded to `static_dir_handler`. Set together
    /// with the handler via `setStaticDirHandler`.
    static_dir_cfg: ?*const anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, address: Address) !*GinwaServer {
        const gs = try allocator.create(GinwaServer);
        gs.* = .{
            .allocator = allocator,
            .io = io,
            .address = address,
            .router = router.Router.init(allocator),
            .sse_manager = try SseManager.init(allocator, allocator, io),
            .ctx = null,
            .environment = null,
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
            fd: i32,
        ) anyerror!void,
        cfg: ?*const anyopaque,
    ) void {
        self.static_dir_handler = handler;
        self.static_dir_cfg = cfg;
    }

    pub fn deinit(self: *GinwaServer) void {
        self.sse_manager.gracefulShutdown();
        self.sse_manager.deinit();
        self.router.deinit();
    }

    pub fn listen(self: *GinwaServer) !void {
        const rc = socket.listen(self.address.sock_fd, 128);
        if (rc < 0) return error.ListenFailed;

        var group: std.Io.Group = .init;
        errdefer group.cancel(self.io);

        self.is_running = true;
        while (self.is_running) {
            const client_fd = self.acceptClient() catch break;

            const arena = self.allocator.create(std.heap.ArenaAllocator) catch {
                _ = socket.close(client_fd);
                continue;
            };
            arena.* = std.heap.ArenaAllocator.init(self.allocator);

            group.concurrent(
                self.io,
                struct {
                    fn handle(server: *GinwaServer, arena_allocator: *std.heap.ArenaAllocator, fd: i32) void {
                        defer {
                            arena_allocator.deinit();
                            server.allocator.destroy(arena_allocator);
                        }

                        const allocator = arena_allocator.allocator();

                        var rb = RequestBuffer.init(allocator);
                        defer rb.deinit();

                        const request_data = rb.readFullRequest(fd) catch |err| {
                            std.debug.print("HTTP_SERVER: readFullRequest failed: {s}\n", .{@errorName(err)});
                            _ = socket.close(fd);
                            return;
                        };
                        defer allocator.free(request_data);

                        var req = http_parser.parseRequest(request_data, allocator, server.io, fd) catch |err| {
                            std.debug.print("HTTP_SERVER: parseRequest failed: {s}\n", .{@errorName(err)});
                            _ = socket.close(fd);
                            return;
                        };
                        defer req.headers.deinit();

                        const http_ctx = http_parser.HttpContext{ .allocator = allocator, .io = server.io };
                        if (server.router.matchRoute(req.method, req.path, &req, http_ctx)) |result| {
                            switch (result) {
                                .handler => |h| {
                                    const final_res = h.handler(h.ctx, req, h.res) catch http_parser.internalError("Handler error", allocator);
                                    const res_bytes = final_res.toBytes() catch {
                                        std.debug.print("Failed to build response\n", .{});
                                        _ = socket.close(fd);
                                        return;
                                    };
                                    defer final_res.allocator.free(res_bytes);
                                    _ = server.sendToClient(fd, res_bytes) catch {
                                        std.debug.print("Failed to send response\n", .{});
                                    };
                                },
                                .sse => |sse| {
                                    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
                                    _ = server.sendToClient(fd, headers) catch {
                                        _ = socket.close(fd);
                                        return;
                                    };
                                    const client_id = server.sse_manager.registerClient(fd) catch {
                                        _ = socket.close(fd);
                                        return;
                                    };
                                    var sse_ctx = sse.ctx;
                                    sse_ctx.client_id = client_id;
                                    const res = http_parser.HttpResponse.init(200, "OK", allocator);
                                    _ = sse.handler(sse_ctx, req, res) catch |err| {
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
                                const not_found = http_parser.notFound(allocator);
                                const res_bytes = not_found.toBytes() catch {
                                    _ = socket.close(fd);
                                    return;
                                };
                                defer not_found.allocator.free(res_bytes);
                                _ = server.sendToClient(fd, res_bytes) catch {};
                            }
                        }

                        _ = socket.close(fd);
                    }
                }.handle,
                .{ self, arena, client_fd },
            ) catch |err| {
                std.debug.print("Failed to spawn handler: {s}\n", .{@errorName(err)});
                arena.deinit();
                self.allocator.destroy(arena);
                _ = socket.close(client_fd);
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

    fn acceptClient(self: *GinwaServer) !i32 {
        var client_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const rc = socket.accept(self.address.sock_fd, @ptrCast(&client_addr), &addr_len);
        if (rc < 0) return error.AcceptFailed;
        return @as(i32, @intCast(rc));
    }

    pub fn recvFromClient(_: *GinwaServer, fd: i32, buf: []u8) !usize {
        const rc = socket.read(fd, buf.ptr, buf.len);
        if (rc < 0) return error.RecvFailed;
        return @as(usize, @intCast(rc));
    }

    pub fn sendToClient(_: *GinwaServer, fd: i32, data: []const u8) !usize {
        const rc = socket.write(fd, data.ptr, data.len);
        if (rc < 0) return error.SendFailed;
        return @as(usize, @intCast(rc));
    }

    pub fn getClientPort(_: *GinwaServer, fd: i32) u16 {
        var addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const rc = posix.getpeername(fd, @ptrCast(&addr), &addr_len);
        if (rc < 0) return 0;
        return @byteSwap(addr.port);
    }

    pub fn shutdown(self: *GinwaServer) void {
        self.is_running = false;
    }
};

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

        // Try different search patterns
        const cl_pattern1 = "Content-Length:";

        const cl_pos = std.mem.indexOf(u8, headers, cl_pattern1);
        if (cl_pos == null) {
            return null;
        }

        const cl_start = cl_pos.? + cl_pattern1.len;

        // Skip whitespace
        var actual_start = cl_start;
        while (actual_start < headers.len and headers[actual_start] == ' ') {
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
    pub fn readFullRequest(self: *RequestBuffer, fd: i32) ![]u8 {
        // Phase 1: read until we have complete headers
        while (std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") == null) {
            const n = socket.read(fd, &self.tmp, self.tmp.len);
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
            const n = socket.read(fd, &self.tmp, to_read);
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
