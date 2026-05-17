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

                        // Use RequestBuffer for auto-growing request reading
                        var rb = RequestBuffer.init(allocator);
                        defer rb.deinit();

                        const request_data = rb.readFullRequest(fd) catch |err| {
                            std.debug.print("HTTP_SERVER: readFullRequest failed: {s}\n", .{@errorName(err)});
                            _ = linux.close(fd);
                            return;
                        };
                        defer allocator.free(request_data);

                        var req = http_parser.parseRequest(request_data, allocator, gs.io, fd) catch |err| {
                            std.debug.print("HTTP_SERVER: parseRequest failed: {s}\n", .{@errorName(err)});
                            _ = linux.close(fd);
                            return;
                        };
                        defer req.headers.deinit();

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
                                },
                                .sse => |sse| {
                                    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
                                    _ = gs.sendToClient(fd, headers) catch {
                                        _ = linux.close(fd);
                                        return;
                                    };
                                    const client_id = gs.sse_manager.registerClient(fd) catch {
                                        _ = linux.close(fd);
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
            const n = linux.read(fd, @ptrCast(&self.tmp), self.tmp.len);
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
            const n = linux.read(fd, @ptrCast(&self.tmp), to_read);
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
