//! Tests for src/client.zig (HTTP transport + JSON helpers).
//!
//! Brings up a tiny `std.Io.net.IpAddress.listen` server on a random
//! port and responds with a canned HTTP/1.1 frame. The libcurl-backed
//! client under test (`custom_http_client`) treats the loopback
//! connection exactly like any other host.
//!
//! Zig 0.16 API notes (mirrors src/apps/desktop_app/subprocess_test.zig):
//!   * `std.Io.net.IpAddress.parseIp4(text, port)` replaces the old
//!     `std.net.Address.parseIp`.
//!   * `addr.listen(io, .{})` returns a `Server { socket: Socket }`.
//!   * `server.socket.address.getPort()` extracts the ephemeral port.
//!   * `server.accept(io)` returns a `Stream` (not a Connection).
//!   * `stream.socket.close(io)` to close the accepted connection.
//!   * `server.deinit(io)` to close the listener.
//!   * `std.Io.Threaded.init(allocator, .{}).io()` is the cross-
//!     platform runtime that powers `addr.listen` / `server.accept`.

const std = @import("std");
const testing = std.testing;
const client = @import("client.zig");
const custom_http_client = @import("custom_http_client");

/// Per-spawn context. Heap-allocated by `EchoServer.start`, freed by
/// `EchoServer.stop` after the thread joins.
const ServerCtx = struct {
    /// Raw HTTP response to write verbatim (status line + headers + body).
    /// This is what lets the 404 test assert that the client surfaces
    /// the status as `Error.HttpRequestFailed`.
    raw_response: []const u8,
};

const EchoServer = struct {
    thread: ?std.Thread,
    port: u16,
    ctx_ptr: *ServerCtx,

    fn start(allocator: std.mem.Allocator, raw_response: []const u8) !EchoServer {
        // Eagerly bring up the listener on the main thread so we can
        // read back the kernel-assigned ephemeral port (port=0 in
        // `parseIp4(..., 0)` means "OS picks"; the resolved port only
        // lands in `server.socket.address` AFTER `listen()` runs).
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = address.listen(io, .{}) catch return error.AddressInUse;
        const port = server.socket.address.getPort();

        const ctx_ptr = try allocator.create(ServerCtx);
        ctx_ptr.* = .{ .raw_response = raw_response };
        // Hand the server fd over to the worker. We pass by-pointer
        // because std.Thread.spawn only copies the args tuple once.
        const srv_ptr = try allocator.create(@TypeOf(server));
        srv_ptr.* = server;

        const thread = try std.Thread.spawn(.{}, run, .{ ctx_ptr, srv_ptr, allocator });
        return .{ .thread = thread, .port = port, .ctx_ptr = ctx_ptr };
    }

    fn run(
        ctx_ptr: *ServerCtx,
        srv_ptr: *@TypeOf(@as(std.Io.net.Server, undefined)),
        parent_alloc: std.mem.Allocator,
    ) void {
        var threaded = std.Io.Threaded.init(parent_alloc, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var server = srv_ptr.*;
        defer server.deinit(io);
        // Free the heap-allocated server we got from `start`.
        parent_alloc.destroy(srv_ptr);

        const conn = server.accept(io) catch return;
        defer conn.socket.close(io);

        var buf: [4096]u8 = undefined;
        var reader = conn.reader(io, &buf);
        // Drain the request: the test sends a small body (or no body
        // at all for GETs). Any read error is fine; we just want to
        // make sure the client's request has been consumed before we
        // write the canned response.
        _ = reader.interface.discard(std.Io.Limit.limited(8 * 1024)) catch {};

        var writer = conn.writer(io, &.{});
        writer.interface.writeAll(ctx_ptr.raw_response) catch return;
        writer.interface.flush() catch {};
    }

    fn stop(self: *EchoServer, allocator: std.mem.Allocator) void {
        if (self.thread) |t| t.join();
        allocator.destroy(self.ctx_ptr);
    }
};

test "getJson: returns parsed body for a canned 200 OK" {
    const body = "{\"ok\":true,\"name\":\"smoke\"}";
    const response_msg = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer testing.allocator.free(response_msg);

    var echo = try EchoServer.start(testing.allocator, response_msg);
    defer echo.stop(testing.allocator);

    const url = try std.fmt.allocPrint(
        testing.allocator,
        "http://127.0.0.1:{d}",
        .{echo.port},
    );
    defer testing.allocator.free(url);

    var client_inst = custom_http_client.Client.init(testing.allocator);
    defer client_inst.deinit();

    const body_out = try client.getJson(testing.allocator, &client_inst, url, "/api/x");
    defer testing.allocator.free(body_out);

    try testing.expectEqualStrings(body, body_out);
}

test "getJson: returns Error.HttpRequestFailed for a 404" {
    const response_body = "404 page not found";
    const response_msg = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer testing.allocator.free(response_msg);

    var echo = try EchoServer.start(testing.allocator, response_msg);
    defer echo.stop(testing.allocator);

    const url = try std.fmt.allocPrint(
        testing.allocator,
        "http://127.0.0.1:{d}",
        .{echo.port},
    );
    defer testing.allocator.free(url);

    var client_inst = custom_http_client.Client.init(testing.allocator);
    defer client_inst.deinit();

    try testing.expectError(
        @as(anyerror, client.Error.HttpRequestFailed),
        client.getJson(testing.allocator, &client_inst, url, "/missing"),
    );
}

test "postJson: round-trips a JSON body" {
    const response_body = "{\"ok\":true}";
    const response_msg = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer testing.allocator.free(response_msg);

    var echo = try EchoServer.start(testing.allocator, response_msg);
    defer echo.stop(testing.allocator);

    const url = try std.fmt.allocPrint(
        testing.allocator,
        "http://127.0.0.1:{d}",
        .{echo.port},
    );
    defer testing.allocator.free(url);

    var client_inst = custom_http_client.Client.init(testing.allocator);
    defer client_inst.deinit();

    const out = try client.postJson(
        testing.allocator,
        &client_inst,
        url,
        "/api/x",
        "{\"hello\":\"world\"}",
    );
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(response_body, out);
}
