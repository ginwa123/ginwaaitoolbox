// src/apps/desktop_app/port.zig
//
// Free-port allocator. Binds to 127.0.0.1:0, lets the kernel pick an ephemeral
// port, reads it back, and returns the port. The probe socket is closed
// before returning, which creates a small race window — callers that need a
// held reservation should wrap this in their own protocol (e.g. spawn nalar
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
