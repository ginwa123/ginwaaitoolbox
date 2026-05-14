const std = @import("std");
const linux = std.posix.system;
const http_parser = @import("http_parser.zig");
const router_mod = @import("router.zig");

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

                        var req = http_parser.parseRequest(raw_data, allocator, gs.io) catch {
                            std.debug.print("Failed to parse HTTP request\n", .{});
                            _ = linux.close(fd);
                            return;
                        };
                        defer req.headers.deinit();

                        // Handle route and get response
                        var res = gs.router.handleRoute(req.method, req.path, &req);

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

const custom = struct {
    id: u64,
};

// Handlers - receive request, context, return response
fn indexHandler(req: *http_parser.HttpRequest, data: *anyopaque) http_parser.HttpResponse {
    const allocator = req.allocator;
    const ctx: *const custom = @ptrCast(@alignCast(data));

    const text = std.fmt.allocPrint(allocator, "ID: {d}", .{ctx.id}) catch {
        return http_parser.internalError("Failed to format", allocator);
    };
    return http_parser.ok(text, allocator);
}

fn healthHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    _ = req;
    return http_parser.ok("OK", std.heap.page_allocator);
}

fn helloHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    _ = req;
    return http_parser.ok("Hello, HTTP!", std.heap.page_allocator);
}

fn helloNameHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    const allocator = req.allocator;

    const name = req.params.get("name") orelse "unknown";
    const greeting = req.query.get("greeting") orelse "hello";
    const mood = req.query.get("mood") orelse "neutral";

    const text = std.fmt.allocPrint(allocator, "Hello, {s}! (greeting: {s}, mood: {s})", .{ name, greeting, mood }) catch {
        return http_parser.internalError("Failed to format", allocator);
    };
    return http_parser.ok(text, allocator);
}

const User = struct {
    username: []const u8 = "",
    email: []const u8 = "",
};

fn createUserHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    const allocator = req.allocator;

    // Parse JSON body directly into a struct
    const user = std.json.parseFromSliceLeaky(User, allocator, req.body, .{}) catch {
        return http_parser.badRequest("Invalid user JSON", allocator);
    };

    const text = std.fmt.allocPrint(allocator, "Created user: {s} ({s})", .{ user.username, user.email }) catch {
        return http_parser.internalError("Failed to format", allocator);
    };
    return http_parser.created(text, allocator);
}

pub fn run(init: std.process.Init) !void {
    const arena_allocator = init.arena;
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    const io = init.io;

    const address = try Address.init(29584);
    const gs = try GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    std.debug.print("HTTP Server listening on 127.0.0.1:29584...\n", .{});
    std.debug.print("Test with: curl http://127.0.0.1:29584/\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    const custom_ctx = custom{ .id = 100 };

    try gs.router.get("/hello", helloHandler, custom_ctx);
    try gs.router.get("/health", healthHandler, .{});
    try gs.router.get("/hello/:name", helloNameHandler, .{});
    try gs.router.post("/users", createUserHandler, .{});
    try gs.router.get("/", indexHandler, custom_ctx);

    try gs.listen();
}

// curl http://127.0.0.1:29584/       # → "Welcome to GinwaServer!"
// curl http://127.0.0.1:29584/health # → "OK"
// curl http://127.0.0.1:29584/hello   # → "Hello, HTTP!"
