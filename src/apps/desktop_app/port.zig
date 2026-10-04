// src/apps/desktop_app/port.zig
//
// Free-port allocator. Binds to 127.0.0.1:0, lets the kernel pick an ephemeral
// port, reads it back, and returns the port. The probe socket is closed
// before returning, which creates a small race window — callers that need a
// held reservation should wrap this in their own protocol (e.g. spawn pabrik
// immediately after this returns).
//
// Zig 0.16 API notes (see test file for the same list):
//   * `std.Io.net.IpAddress.parseIp4(text, port)` replaces `std.net.Address.parseIp`.
//   * `IpAddress.listen(io, .{})` replaces `std.net.tcpListenToAddress` —
//     `listen` is a method on `IpAddress` in Zig 0.16.
//   * `Server.socket.address` holds the resolved ephemeral port.
//   * `Server.deinit(&server, io)` takes an Io handle.

const std = @import("std");

pub const FreePort = struct {
    port: u16,
    /// For debugging only; the OS may recycle the port after we close our probe
    /// socket. Currently always null — reserved for future use (e.g. logging
    /// the full path to a probe socket or a Unix-domain-socket path).
    path: ?[]u8 = null,
};

/// Find a free TCP port on the loopback interface. Returns the port number
/// the OS assigned. The probe socket is closed before this function returns;
/// treat the returned port as a *suggestion* to try, not a held reservation.
///
/// `allocator` is reserved for future use (e.g. if we need to allocate the
/// `path` field). Currently unused but accepted to keep the signature stable
/// for Chunk 8's main.zig caller.
pub fn findFree(allocator: std.mem.Allocator, io: std.Io) !FreePort {
    _ = allocator;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    // The listen() call resolved the ephemeral port into server.socket.address.
    const port = server.socket.address.getPort();
    return .{ .port = port, .path = null };
}

/// Best-effort "nothing is listening on 127.0.0.1:`port`" check.
///
/// The probe socket is closed before returning, so this is a *hint* — a
/// TOCTOU race with another process is possible. Callers use it to decide
/// whether a spawned child can actually bind the port, which matters when
/// the well-known desktop port is already held by a foreign (or broken)
/// server: binding would fail, but that foreign server's `/health` would
/// still answer our readiness probe, so the failure has to be predicted
/// BEFORE spawning rather than diagnosed afterwards.
pub fn isFree(allocator: std.mem.Allocator, io: std.Io, port: u16) bool {
    _ = allocator;
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    var server = address.listen(io, .{}) catch return false;
    server.deinit(io);
    return true;
}

// ===== Tests merged from port_test.zig (2026-09-29 flatten) =====
// src/apps/desktop_app/port_test.zig
//
// Tests for the free-port allocator. The allocator binds to 127.0.0.1:0, lets
// the kernel pick an ephemeral port, reads it back, and returns it. There's a
// small race window between closing our probe socket and the caller binding —
// this is acceptable for v1 (the race window is microseconds; pabrik binds
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

const testing = std.testing;

test "findFree returns a port we can bind to" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p = try findFree(allocator, io);
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

    const p1 = try findFree(allocator, io);
    const p2 = try findFree(allocator, io);
    defer if (p1.path) |path| allocator.free(path);
    defer if (p2.path) |path| allocator.free(path);

    // Ephemeral port reuse: on a busy system, the OS may give the same port
    // back twice in a row. This is a heuristic test, not a strict guarantee.
    try testing.expect(p1.port != p2.port);
}
