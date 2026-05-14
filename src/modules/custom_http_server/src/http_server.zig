const std = @import("std");
const linux = std.posix.system;
const http_parser = @import("http_parser.zig");
const router_mod = @import("router.zig");

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
    router: router_mod.Router,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, address: Address) !*GinwaServer {
        const gs = try allocator.create(GinwaServer);
        gs.* = .{
            .allocator = allocator,
            .io = io,
            .address = address,
            .router = router_mod.Router.init(allocator),
        };
        return gs;
    }

    pub fn deinit(self: *GinwaServer) void {
        _ = self; // Router doesn't need deinit currently
    }

    pub fn listen(self: *GinwaServer) !void {
        const rc = linux.listen(self.address.sock_fd, 128);
        if (rc < 0) return error.ListenFailed;

        while (true) {
            const client_fd = try self.acceptClient();

            _ = self.io.async(
                struct {
                    fn run(gs: *GinwaServer, fd: i32) void {
                        var arena_allocator = std.heap.ArenaAllocator.init(gs.allocator);
                        defer arena_allocator.deinit();
                        const allocator = arena_allocator.allocator();

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

                        const raw_data = buffer[0..bytes_read];
                        std.debug.print("Received {d} bytes: {s}\n", .{ bytes_read, raw_data });

                        var req = http_parser.parseRequest(raw_data, allocator, gs.io, fd) catch {
                            std.debug.print("Failed to parse HTTP request\n", .{});
                            _ = linux.close(fd);
                            return;
                        };
                        defer req.headers.deinit();

                        // Try to match route (check for SSE first)
                        if (gs.router.matchRoute(req.method, req.path, &req)) |result| {
                            switch (result) {
                                .response => |res| {
                                    const res_bytes = res.toBytes() catch {
                                        std.debug.print("Failed to build response\n", .{});
                                        _ = linux.close(fd);
                                        return;
                                    };
                                    defer res.allocator.free(res_bytes);

                                    _ = gs.sendToClient(fd, res_bytes) catch {
                                        std.debug.print("Failed to send response\n", .{});
                                    };
                                    std.debug.print("Response sent: {d} bytes\n", .{res_bytes.len});
                                },
                                .sse => |sse| {
                                    // Send SSE headers
                                    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
                                    _ = gs.sendToClient(fd, headers) catch {
                                        std.debug.print("Failed to send SSE headers\n", .{});
                                        _ = linux.close(fd);
                                        return;
                                    };
                                    // Call SSE handler for streaming
                                    sse.handler(&req, sse.context);
                                    _ = linux.close(fd);
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
                .{ self, client_fd },
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

    fn recvFromClient(_: *GinwaServer, fd: i32, buf: []u8) !usize {
        const rc = linux.read(fd, @ptrCast(buf.ptr), buf.len);
        if (rc < 0) return error.RecvFailed;
        return @as(usize, @intCast(rc));
    }

    fn sendToClient(_: *GinwaServer, fd: i32, data: []const u8) !usize {
        const rc = linux.write(fd, @ptrCast(data.ptr), data.len);
        if (rc < 0) return error.SendFailed;
        return @as(usize, @intCast(rc));
    }

    fn getClientPort(_: *GinwaServer, fd: i32) u16 {
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
};
