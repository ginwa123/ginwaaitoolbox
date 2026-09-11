//! Peekable connection reader.
//!
//! The HTTP/1.1 request reader (`RequestBuffer.readFullRequest`) stops at the
//! FIRST `\r\n\r\n` in the stream. The HTTP/2 connection preface
//! (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) contains one at byte 14, so a server that
//! parses h1 first would consume the preface plus whatever frames arrived in the
//! same TCP segment, and hand them to `parseRequest` as a bogus request body —
//! losing the first SETTINGS/HEADERS frames forever.
//!
//! This type exists to close that hole: read ONE chunk, look at it, and only then
//! decide which codec owns the socket. The buffered bytes are never discarded —
//! either the h2 driver receives them (`buffered`), or the h1 path seeds its
//! `RequestBuffer` with them (`takeBuffered`).

const std = @import("std");

/// The h2 preface lives in the protocol constants module; importing it here keeps
/// the sniff and the connection driver reading the same 24 bytes.
const constants = @import("http2/constants.zig");

pub const Error = error{ RecvFailed, OutOfMemory };

pub const ConnectionReader = struct {
    alloc: std.mem.Allocator,
    fd: i32,
    buf: std.ArrayList(u8) = .empty,
    scratch: [4096]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, fd: i32) ConnectionReader {
        return .{ .alloc = alloc, .fd = fd };
    }

    pub fn deinit(self: *ConnectionReader) void {
        self.buf.deinit(self.alloc);
    }

    /// Bytes read so far and not yet handed off.
    pub fn buffered(self: *const ConnectionReader) []const u8 {
        return self.buf.items;
    }

    /// Read once (up to 4 KiB) and return everything buffered so far. Returns an
    /// empty slice at EOF, so callers can tell "closed" from "more to come" via
    /// `buffered().len` on the previous call.
    pub fn fillOnce(self: *ConnectionReader) Error![]const u8 {
        const n = recvFromSock(self.fd, &self.scratch, self.scratch.len);
        if (n < 0) return error.RecvFailed;
        if (n == 0) return self.buf.items;
        try self.buf.appendSlice(self.alloc, self.scratch[0..@intCast(n)]);
        return self.buf.items;
    }

    /// Read until at least `want` bytes are buffered, or EOF / `max_rounds` is
    /// reached. Used to complete the 24-byte preface before committing to h2.
    pub fn fillAtLeast(self: *ConnectionReader, want: usize, max_rounds: usize) Error!void {
        var rounds: usize = 0;
        while (self.buf.items.len < want and rounds < max_rounds) : (rounds += 1) {
            const before = self.buf.items.len;
            _ = try self.fillOnce();
            if (self.buf.items.len == before) return; // EOF
        }
    }

    /// Hand the buffered bytes to the caller and reset the buffer. Ownership
    /// transfers to the caller (arena-allocated memory is reclaimed wholesale).
    pub fn takeBuffered(self: *ConnectionReader) ![]u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }
};

fn recvFromSock(fd: i32, buf: []u8, len: usize) isize {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const winsock = struct {
            extern "ws2_32" fn recv(s: usize, buf_ptr: [*]u8, len: c_int, flags: c_int) c_int;
        };
        return winsock.recv(@intCast(fd), buf.ptr, @intCast(len), 0);
    }
    const posix_socket = struct {
        extern "c" fn read(fd: c_int, buf_ptr: [*]u8, nbyte: usize) isize;
    };
    return posix_socket.read(fd, buf.ptr, len);
}

/// What the first bytes of a connection look like.
pub const Kind = enum {
    /// The complete 24-byte HTTP/2 preface is present — hand the socket to h2.
    h2,
    /// A proper prefix of the preface; more bytes are needed to decide.
    maybe_h2,
    /// Definitely not HTTP/2 — keep the HTTP/1.1 path.
    h1,
};

/// Classify the first bytes of a connection.
///
/// The caller passes whatever a single `recv` returned, which is usually MORE
/// than 24 bytes: a client that uses prior knowledge sends the preface and its
/// SETTINGS frame back-to-back, and curl does exactly that. So the "is this a
/// full preface" test must look at the first 24 bytes, not require the buffer to
/// BE 24 bytes — getting this wrong silently downgrades every real h2 client to
/// HTTP/1.1 (regression: caught by the socket-level functional probe, not by the
/// driver unit tests).
pub fn sniff(bytes: []const u8) Kind {
    if (bytes.len >= constants.preface_len) {
        return if (constants.isPreface(bytes)) .h2 else .h1;
    }
    if (bytes.len == 0) return .h1; // EOF before any byte: nothing to wait for
    return if (constants.isPrefacePrefix(bytes)) .maybe_h2 else .h1;
}

test {
    _ = @import("connection_reader_test.zig");
}
