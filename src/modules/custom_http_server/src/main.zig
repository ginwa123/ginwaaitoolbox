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

        return .{
            .sock_fd = sock_fd,
            .port = port,
        };
    }

    fn createSockFd(socket: i32) i32 {
        return @as(i32, @intCast(socket));
    }

    fn callSocket() !i32 {
        const rc = linux.socket(2, 1, 0);
        if (rc < 0) return error.SocketCreationFailed;
        return @as(i32, @intCast(rc));
    }
};

pub const GinwaServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    address: Address,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, address: Address) !*GinwaServer {
        const gs = try allocator.create(GinwaServer);
        gs.* = .{
            .allocator = allocator,
            .io = io,
            .address = address,
        };

        try gs.setReuseAddr();
        try gs.bind();

        return gs;
    }

    pub fn listen(self: *GinwaServer) !void {
        const rc = linux.listen(self.address.sock_fd, 128);
        if (rc < 0) return error.ListenFailed;
    }

    fn setReuseAddr(self: *GinwaServer) !void {
        const opt: u32 = 1;
        const rc = linux.setsockopt(
            self.address.sock_fd,
            1,
            2,
            @ptrFromInt(@intFromPtr(&opt)),
            @sizeOf(u32),
        );
        if (rc < 0) return error.SetSockOptFailed;
    }

    fn bind(self: *GinwaServer) !void {
        var addr: [16]u8 = undefined;
        @memset(&addr, 0);

        addr[0] = 2; // AF_INET
        addr[2] = @as(u8, @truncate(self.address.port >> 8));
        addr[3] = @as(u8, @truncate(self.address.port));
        addr[4] = 127;
        addr[5] = 0;
        addr[6] = 0;
        addr[7] = 1;

        const rc = linux.bind(
            self.address.sock_fd,
            @ptrCast(@alignCast(&addr)),
            16,
        );
        if (rc < 0) return error.BindFailed;
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

        return @as(u16, addr[2]) << 8 | @as(u16, addr[3]);
    }

    fn formatBytes(_: *GinwaServer, bytes: usize, allocator: std.mem.Allocator) []const u8 {
        if (bytes < 1024) {
            return std.fmt.allocPrint(allocator, "{d}B", .{bytes}) catch return "0B";
        } else if (bytes < 1024 * 1024) {
            return std.fmt.allocPrint(allocator, "{d}KB", .{bytes / 1024}) catch return "0KB";
        } else if (bytes < 1024 * 1024 * 1024) {
            return std.fmt.allocPrint(allocator, "{d}MB", .{bytes / (1024 * 1024)}) catch return "0MB";
        } else {
            return std.fmt.allocPrint(allocator, "{d}GB", .{bytes / (1024 * 1024 * 1024)}) catch return "0GB";
        }
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

// Args struct passed into the async task — avoids captures
const ClientArgs = struct {
    gs: *GinwaServer,
    client_fd: i32,
    allocator: std.mem.Allocator,
};

// Called by io.async — handles one connected client
fn handleClient(args: ClientArgs) void {
    defer _ = linux.close(args.client_fd);

    const gs = args.gs;
    const fd = args.client_fd;

    std.debug.print("Client connected from port {d}!\n", .{gs.getClientPort(fd)});

    var buffer: [1024]u8 = undefined;
    const bytes_read = gs.recvFromClient(fd, &buffer) catch |err| {
        std.debug.print("Recv error: {s}\n", .{@errorName(err)});
        return;
    };

    if (bytes_read > 0) {
        const clean = gs.cleanText(buffer[0..bytes_read], args.allocator) catch {
            std.debug.print("cleanText alloc failed\n", .{});
            return;
        };
        std.debug.print("Received: {s}\n", .{clean});

        const bytes_written = gs.sendToClient(fd, buffer[0..bytes_read]) catch |err| {
            std.debug.print("Send error: {s}\n", .{@errorName(err)});
            return;
        };
        std.debug.print("Sent {d} bytes back to client\n", .{bytes_written});
    }

    std.debug.print("Client disconnected\n\n", .{});
}

pub fn run(init: std.process.Init) !void {
    const arena_allocator = init.arena;
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    const io = init.io;

    const gs = try GinwaServer.init(allocator, io, try Address.init(29584));
    try gs.listen();

    std.debug.print("TCP Echo Server listening on 127.0.0.1:29584...\n", .{});
    std.debug.print("Connect with: nc 127.0.0.1 29584\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    while (true) {
        const client_fd = try gs.acceptClient();

        // Spawn async task — no fork(), no thread creation boilerplate.
        // io.async immediately calls handleClient in blocking mode,
        // or suspends/resumes it on the event loop in evented mode.
        const future = io.async(handleClient, .{ClientArgs{
            .gs = gs,
            .client_fd = client_fd,
            .allocator = allocator,
        }});
        _ = future;
    }
}
