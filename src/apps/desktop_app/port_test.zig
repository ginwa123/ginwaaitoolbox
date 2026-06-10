// src/apps/desktop_app/port_test.zig
//
// Tests for the free-port allocator. The allocator binds to 127.0.0.1:0, lets
// the kernel pick an ephemeral port, reads it back, and returns it. There's a
// small race window between closing our probe socket and the caller binding —
// this is acceptable for v1 (the race window is microseconds; nalar binds
// almost immediately).
//
// Zig 0.16 API notes:
//   * `std.Io.net.IpAddress.parseIp4(text, port)` replaces the old
//     `std.net.Address.parseIp`.
//   * `std.Io.net.listen(&addr, io, .{})` replaces the old
//     `std.net.tcpListenToAddress` and takes an explicit Io handle.
//   * `Server.deinit(&server, io)` takes an Io handle.
//   * The resolved ephemeral port lives in `Server.socket.address` —
//     `std.Io.net.getPort(server.socket.address)` extracts it.

const std = @import("std");
const port = @import("port.zig");
const testing = std.testing;

test "findFree returns a port we can bind to" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p = try port.findFree(allocator, io);
    defer if (p.path) |path| allocator.free(path);

    // Verify the port is actually bindable (we should be able to listen on it
    // a second time — well, after a small delay since we just closed the
    // probe). The exact port from findFree should be a valid, non-zero port.
    try testing.expect(p.port != 0);

    // Sanity-check that the address parses cleanly at the returned port.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", p.port);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
}

test "findFree returns different ports on consecutive calls" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p1 = try port.findFree(allocator, io);
    const p2 = try port.findFree(allocator, io);
    defer if (p1.path) |path| allocator.free(path);
    defer if (p2.path) |path| allocator.free(path);

    // Ephemeral port reuse: on a busy system, the OS may give the same port
    // back twice in a row. This is a heuristic test, not a strict guarantee.
    try testing.expect(p1.port != p2.port);
}
