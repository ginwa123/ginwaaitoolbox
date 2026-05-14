const std = @import("std");
const linux = std.posix.system;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Server error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

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
    handler: ?*const fn (ClientArgs) void,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, address: Address) !*GinwaServer {
        const gs = try allocator.create(GinwaServer);
        gs.* = .{
            .allocator = allocator,
            .io = io,
            .address = address,
            .handler = null,
        };
        return gs;
    }

    pub fn listen(self: *GinwaServer, comptime handler: anytype) !void {
        // Store the function pointer
        self.handler = @ptrCast(&handler);

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

                        defer _ = linux.close(fd);
                        var buffer: [1024]u8 = undefined;
                        const bytes_read = gs.recvFromClient(fd, &buffer) catch |err| {
                            std.debug.print("Recv error: {s}\n", .{@errorName(err)});
                            return;
                        };

                        var clean: []const u8 = "";
                        if (bytes_read > 0) {
                            clean = gs.cleanText(buffer[0..bytes_read], allocator) catch {
                                std.debug.print("cleanText alloc failed\n", .{});
                                return;
                            };
                        }

                        const req = Request{
                            .method = null,
                            .path = null,
                            .headers = null,
                            .body = clean,
                        };

                        const res = Response{
                            .status_code = null,
                        };

                        const args = ClientArgs{
                            .request = req,
                            .response = res,
                            .allocator = allocator,
                        };
                        const h = gs.handler.?;
                        h(args); // Call with struct (no error union)
                        //
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

    fn cleanText(_: *GinwaServer, data: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var filtered = try allocator.alloc(u8, data.len);
        var j: usize = 0;
        for (data) |byte| {
            if (byte >= 32 and byte <= 126) {
                filtered[j] = byte;
                j += 1;
            }
        }
        return filtered[0..j];
    }
};

const Response = struct {
    status_code: ?u16 = null,
};

const Header = struct {
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
};

const Request = struct {
    method: ?[]const u8 = null,
    path: ?[]const u8 = null,
    headers: ?[]Header = null,
    body: ?[]const u8 = null,
};

// Client arguments passed to handler
const ClientArgs = struct {
    allocator: std.mem.Allocator,
    request: Request,
    response: Response,
};

// Handler function (called from async task)
fn handleClientInner(args: ClientArgs) void {
    const req = args.request;

    if (req.body) |body| {
        std.debug.print("Received: {s}\n", .{body});
    }

    std.debug.print("Client disconnected\n\n", .{});
}

pub fn run(init: std.process.Init) !void {
    const arena_allocator = init.arena;
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    const io = init.io;

    const gs = try GinwaServer.init(allocator, io, try Address.init(29584));

    std.debug.print("TCP Echo Server listening on 127.0.0.1:29584...\n", .{});
    std.debug.print("Connect with: nc 127.0.0.1 29584\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    try gs.listen(handleClientInner);
}
