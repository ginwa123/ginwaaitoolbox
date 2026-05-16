const std = @import("std");
const linux = std.posix.system;
pub const http_parser = @import("http_parser.zig");
const router = @import("router.zig");
pub const sse_manager = @import("sse_manager.zig");
pub const HttpRequest = http_parser.HttpRequest;
pub const HttpResponse = http_parser.HttpResponse;
pub const HttpContext = http_parser.HttpContext;
pub const response = http_parser;
pub const SseManager = sse_manager.SseManager;

pub const Address = struct {
    sock_fd: i32,
    port: u16,

    pub fn init(port: u16) !Address {
        const socket = try Address.callSocket();
        const sock_fd = Address.createSockFd(socket);
        _ = try setReuseAddr(sock_fd);
        _ = try bind(port, sock_fd);

        return .{
            .sock_fd = sock_fd,
            .port = port,
        };
    }

    fn createSockFd(socket: i32) i32 {
        return @as(i32, @intCast(socket));
    }

    fn callSocket() !i32 {
        const rc = linux.socket(2, 1, 0); // AF_INET, SOCK_STREAM
        if (rc < 0) return error.SocketCreationFailed;
        return @as(i32, @intCast(rc));
    }

    fn setReuseAddr(sock_fd: i32) !void {
        const opt: u32 = 1;
        const rc = linux.setsockopt(
            sock_fd,
            1, // SOL_SOCKET
            2, // SO_REUSEADDR
            @ptrFromInt(@intFromPtr(&opt)),
            @sizeOf(u32),
        );
        if (rc < 0) return error.SetSockOptFailed;
    }

    fn bind(port: u16, sock_fd: i32) !void {
        var addr: [16]u8 = undefined;
        @memset(&addr, 0);
        addr[0] = 2; // AF_INET
        addr[2] = @as(u8, @truncate(port >> 8));
        addr[3] = @as(u8, @truncate(port));
        addr[4] = 127;
        addr[5] = 0;
        addr[6] = 0;
        addr[7] = 1; // 127.0.0.1

        const rc = linux.bind(
            sock_fd,
            @ptrCast(@alignCast(&addr)),
            16,
        );
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, address: Address) !*GinwaServer {
        const gs = try allocator.create(GinwaServer);
        gs.* = .{
            .allocator = allocator,
            .io = io,
            .address = address,
            .router = router.Router.init(allocator),
            .sse_manager = try SseManager.init(allocator, allocator),
            .ctx = null,
            .environment = null,
        };
        return gs;
    }

    pub fn deinit(self: *GinwaServer) void {
        self.sse_manager.gracefulShutdown();
        self.sse_manager.deinit();
        self.router.deinit();
    }

    pub fn listen(self: *GinwaServer) !void {
        const rc = linux.listen(self.address.sock_fd, 128);
        if (rc < 0) return error.ListenFailed;

        var group: std.Io.Group = .init;
        defer group.cancel(self.io);

        self.is_running = true;
        while (self.is_running) {
            const client_fd = try self.acceptClient();

            const arena = try self.allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(self.allocator);
            try group.concurrent(
                self.io,
                struct {
                    fn run(gs: *GinwaServer, arena_allocator: *std.heap.ArenaAllocator, fd: i32) void {
                        defer {
                            arena_allocator.deinit();
                            gs.allocator.destroy(arena_allocator);
                        }

                        const allocator = arena_allocator.allocator();
                        var buf: std.ArrayList(u8) = .empty;
                        defer buf.deinit(allocator);

                        var buffer: [4096]u8 = undefined;
                        const bytes_read = gs.recvFromClient(fd, &buffer) catch |err| {
                            std.debug.print("Recv error: {s}\n", .{@errorName(err)});
                            _ = linux.close(fd);
                            return;
                        };

                        if (bytes_read == 0) {
                            _ = linux.close(fd);
                            return;
                        }

                        buf.appendSlice(allocator, buffer[0..bytes_read]) catch unreachable;

                        // std.debug.print("Received {d} bytes: {s}\n", .{ bytes_read, buf.items });

                        var req = http_parser.parseRequest(buf.items, allocator, gs.io, fd) catch {
                            std.debug.print("Failed to parse HTTP request\n", .{});
                            _ = linux.close(fd);
                            return;
                        };
                        defer req.headers.deinit();

                        // Try to match route (check for SSE first)
                        const http_ctx = http_parser.HttpContext{ .allocator = allocator, .io = gs.io };
                        if (gs.router.matchRoute(req.method, req.path, &req, http_ctx)) |result| {
                            switch (result) {
                                .handler => |h| {
                                    const final_res = h.handler(h.ctx, req, h.res) catch http_parser.internalError("Handler error", allocator);
                                    const res_bytes = final_res.toBytes() catch {
                                        std.debug.print("Failed to build response\n", .{});
                                        _ = linux.close(fd);
                                        return;
                                    };
                                    defer final_res.allocator.free(res_bytes);

                                    _ = gs.sendToClient(fd, res_bytes) catch {
                                        std.debug.print("Failed to send response\n", .{});
                                    };
                                    // std.debug.print("Response sent: {d} bytes\n", .{res_bytes.len});
                                },
                                .sse => |sse| {
                                    // Send SSE headers (keep-alive)
                                    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
                                    _ = gs.sendToClient(fd, headers) catch {
                                        _ = linux.close(fd);
                                        return;
                                    };

                                    // Register client with SSE manager (ownership transfers)
                                    const client_id = gs.sse_manager.registerClient(fd) catch {
                                        _ = linux.close(fd);
                                        return;
                                    };

                                    // Set client_id in context so handler can access it
                                    var sse_ctx = sse.ctx;

                                    sse_ctx.client_id = client_id;
                                    std.debug.print("HTTP_SERVER: client_id {s}\n", .{client_id});

                                    // Call SSE handler - it returns immediately (error.WouldBlock expected)
                                    // The SSE manager event loop handles ongoing streaming
                                    const res = http_parser.HttpResponse.init(200, "OK", allocator);
                                    _ = sse.handler(sse_ctx, req, res) catch |err| {
                                        if (err != error.WouldBlock) {
                                            std.debug.print("SSE handler error: {s}\n", .{@errorName(err)});
                                        }
                                        // Don't remove client on WouldBlock - it's expected
                                        // Client stays connected until disconnect
                                    };

                                    // DON'T close fd - SSE manager owns it now
                                    // SSE manager will close on disconnect or graceful shutdown
                                    return;
                                },
                            }
                        } else {
                            // No route matched - send 404
                            const not_found = http_parser.notFound(allocator);
                            const res_bytes = not_found.toBytes() catch {
                                _ = linux.close(fd);
                                return;
                            };
                            defer not_found.allocator.free(res_bytes);
                            _ = gs.sendToClient(fd, res_bytes) catch {};
                        }

                        _ = linux.close(fd);
                    }
                }.run,
                .{ self, arena, client_fd },
            );
        }
    }

    fn acceptClient(self: *GinwaServer) !i32 {
        var client_addr: [16]u8 = undefined;
        @memset(&client_addr, 0);
        var addr_len: i32 = 16;

        const rc = linux.accept(
            self.address.sock_fd,
            @ptrCast(@alignCast(&client_addr)),
            @ptrCast(@alignCast(&addr_len)),
        );
        if (rc < 0) return error.AcceptFailed;
        return @as(i32, @intCast(rc));
    }

    pub fn recvFromClient(_: *GinwaServer, fd: i32, buf: []u8) !usize {
        const rc = linux.read(fd, @ptrCast(buf.ptr), buf.len);
        if (rc < 0) return error.RecvFailed;
        return @as(usize, @intCast(rc));
    }

    pub fn sendToClient(_: *GinwaServer, fd: i32, data: []const u8) !usize {
        const rc = linux.write(fd, @ptrCast(data.ptr), data.len);
        if (rc < 0) return error.SendFailed;
        return @as(usize, @intCast(rc));
    }

    pub fn getClientPort(_: *GinwaServer, fd: i32) u16 {
        var addr: [16]u8 = undefined;
        @memset(&addr, 0);
        var addr_len: i32 = 16;

        const rc = linux.getpeername(
            fd,
            @ptrCast(@alignCast(&addr)),
            @ptrCast(@alignCast(&addr_len)),
        );
        if (rc < 0) return 0;
        return (@as(u16, addr[2]) << 8) | @as(u16, addr[3]);
    }

    pub fn shutdown(self: *GinwaServer) void {
        self.is_running = false;
    }
};

/// Global server instance for access from handlers
pub var global_server: ?*GinwaServer = null;

/// SSE Event structure
pub const SseEvent = struct {
    data: []const u8,
    event_type: ?[]const u8 = null,
};

/// Get global SSE manager
pub fn getGlobalSseManager() ?*SseManager {
    if (global_server) |server| {
        return &server.sse_manager;
    }
    return null;
}

/// Broadcast a panic event to all connected SSE clients
pub fn broadcastPanic(panic_info: []const u8) void {
    if (getGlobalSseManager()) |sse_mgr| {
        sse_mgr.broadcast(panic_info) catch {};
    }
}
