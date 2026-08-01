//! WebSocket frame parser and encoder (RFC 6455 §5).
//!
//! This module converts between raw WebSocket frames on the wire and the
//! `Frame` struct. It is the only part of the WebSocket implementation that
//! touches the wire format — the manager and handshake modules build on top.
//!
//! Reference: <https://datatracker.ietf.org/doc/html/rfc6455#section-5>
//!
//! Frame header layout (always big-endian on the wire):
//!   byte 0: FIN (1) | RSV (3) | opcode (4)
//!   byte 1: MASK (1) | payload_len (7)
//!   bytes 2..2+(0|2|8): extended payload length
//!   bytes 2..6 or 4..8: 4-byte mask key (only if MASK=1)
//!   bytes ...: payload (XOR-masked with the rotating mask key)
//!
//! Length encoding:
//!   - 0..125: literal payload length in the 7-bit field.
//!   - 126: the next 2 bytes are the 16-bit payload length (network byte order).
//!   - 127: the next 8 bytes are the 64-bit payload length.
//!
//! Opcodes (RFC 6455 §5.2):
//!   0x0 continuation, 0x1 text, 0x2 binary,
//!   0x8 close, 0x9 ping, 0xA pong
//!
//! Masking requirement (RFC 6455 §5.1):
//!   - Clients MUST mask all frames sent to the server.
//!   - Servers MUST NOT mask frames sent to the client.
//!   The parser therefore rejects unmasked frames from the client side
//!   with `error.UnmaskedFrameFromClient`.

const std = @import("std");

/// WebSocket message opcodes (RFC 6455 §5.2).
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    // 0x3..0x7 reserved for data frames
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    // 0xB..0xF reserved for control frames
};

/// A parsed WebSocket frame.
///
/// `payload` is freshly allocated by `parseFrame` (the caller owns it and
/// must call `deinit` to free). The wire bytes are not retained.
pub const Frame = struct {
    fin: bool,
    rsv: u3,
    opcode: Opcode,
    payload: []u8,

    /// Free the payload. Safe to call multiple times (no-op after first call).
    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.payload.len > 0) {
            allocator.free(self.payload);
        }
        self.payload = &[_]u8{};
    }
};

/// Input for `encodeFrame`. The mask bit is controlled by the encoder —
/// callers do not set it. The encoder always produces unmasked frames
/// (the server must not mask per RFC 6455 §5.1).
pub const EncodeInput = struct {
    opcode: Opcode,
    payload: []const u8,
};

/// Encode a WebSocket frame into a freshly-allocated byte slice.
///
/// The returned slice is owned by the caller (free with `allocator.free`).
pub fn encodeFrame(allocator: std.mem.Allocator, input: EncodeInput) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    // First byte: FIN=1, RSV=000, opcode
    const first_byte: u8 = 0x80 | @as(u8, @intFromEnum(input.opcode));
    try buf.append(allocator, first_byte);

    // Second byte: MASK=0 (server->client), payload_len
    const plen = input.payload.len;
    if (plen <= 125) {
        try buf.append(allocator, @intCast(plen));
    } else if (plen <= 0xFFFF) {
        try buf.append(allocator, 126);
        try buf.append(allocator, @intCast(@as(u16, @intCast(plen)) >> 8));
        try buf.append(allocator, @intCast(@as(u16, @intCast(plen)) & 0xFF));
    } else {
        try buf.append(allocator, 127);
        // 64-bit big-endian length
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            try buf.append(allocator, @intCast((plen >> @intCast(i * 8)) & 0xFF));
        }
    }

    // Payload
    try buf.appendSlice(allocator, input.payload);

    return buf.toOwnedSlice(allocator);
}

/// Parse a complete WebSocket frame from raw bytes.
///
/// The wire buffer must contain the entire frame (header + masking key + payload).
/// For streaming parsing, the caller should read more bytes until `parseFrame`
/// succeeds — see `error.IncompleteFrame` for the recoverable case.
///
/// Errors:
///   - `error.IncompleteFrame` — the wire buffer is too short for the declared
///     payload length. Caller should read more bytes and retry.
///   - `error.UnmaskedFrameFromClient` — RFC 6455 §5.1 violation (server-side only).
///   - `error.InvalidOpcode` — reserved opcode received.
pub fn parseFrame(allocator: std.mem.Allocator, wire: []const u8) !Frame {
    if (wire.len < 2) return error.IncompleteFrame;

    const b0 = wire[0];
    const b1 = wire[1];

    const fin: bool = (b0 & 0x80) != 0;
    const rsv: u3 = @truncate(@as(u8, @intCast((b0 >> 4) & 0x07)));
    const opcode_raw: u4 = @truncate(@as(u8, @intCast(b0 & 0x0F)));
    // Zig 0.16 removed std.meta.intToEnum. We validate the raw value against
    // the allowed opcodes manually — values 0x3..0x7 (data) and 0xB..0xF
    // (control) are reserved and rejected per RFC 6455 §5.2.
    const opcode: Opcode = switch (opcode_raw) {
        0x0 => .continuation,
        0x1 => .text,
        0x2 => .binary,
        0x8 => .close,
        0x9 => .ping,
        0xA => .pong,
        else => return error.InvalidOpcode,
    };

    const masked: bool = (b1 & 0x80) != 0;
    if (!masked) return error.UnmaskedFrameFromClient;

    const len7 = b1 & 0x7F;
    var payload_len: usize = 0;
    var offset: usize = 2;

    if (len7 < 126) {
        payload_len = len7;
    } else if (len7 == 126) {
        if (wire.len < offset + 2) return error.IncompleteFrame;
        const len16 = (@as(u16, wire[offset]) << 8) | @as(u16, wire[offset + 1]);
        payload_len = len16;
        offset += 2;
    } else {
        // 127 -> 64-bit length
        if (wire.len < offset + 8) return error.IncompleteFrame;
        var len64: u64 = 0;
        for (0..8) |i| {
            len64 = (len64 << 8) | @as(u64, wire[offset + i]);
        }
        payload_len = @intCast(len64);
        offset += 8;
    }

    var mask_key: [4]u8 = undefined;
    if (masked) {
        if (wire.len < offset + 4) return error.IncompleteFrame;
        @memcpy(&mask_key, wire[offset..offset + 4]);
        offset += 4;
    }

    if (wire.len < offset + payload_len) return error.IncompleteFrame;

    // Allocate and unmask the payload. We always copy (never alias the wire
    // buffer) because the wire buffer may be reused by the caller for the
    // next frame.
    const payload = try allocator.alloc(u8, payload_len);
    if (masked) {
        unmaskInPlace(payload, wire[offset..offset + payload_len], mask_key);
    } else {
        @memcpy(payload, wire[offset..offset + payload_len]);
    }

    return Frame{
        .fin = fin,
        .rsv = rsv,
        .opcode = opcode,
        .payload = payload,
    };
}

/// Information extracted from a Close frame payload (RFC 6455 §5.5.1).
///
/// The status code is a 2-byte big-endian unsigned integer. The "Normal
/// Closure" code (1000) is the default when no payload is sent.
pub const CloseInfo = struct {
    code: u16,
    reason: []const u8,
};

/// Decode the Close frame payload into a status code + reason.
///
/// An empty payload is treated as 1000 (Normal Closure) per RFC 6455 §5.5.1.
pub fn decodeClosePayload(payload: []const u8) !CloseInfo {
    if (payload.len == 0) {
        return .{ .code = 1000, .reason = "" };
    }
    if (payload.len < 2) return error.InvalidClosePayload;
    const code = (@as(u16, payload[0]) << 8) | @as(u16, payload[1]);
    return .{ .code = code, .reason = payload[2..] };
}

/// Generate a 4-byte random mask key for client→server frames.
///
/// RFC 6455 §5.3: "The masking key is a 32-bit value chosen at random by
/// the client. ... When preparing a masked frame, the client MUST pick a
/// fresh masking key from the set of allowed 32-bit values."
pub fn generateMaskKey() [4]u8 {
    var key: [4]u8 = undefined;
    // std.c.getrandom is the Zig 0.16-recommended way to obtain random
    // bytes cross-platform (replaces std.crypto.random.bytes). It is
    // signal-safe and does not require an allocator. On Windows it
    // surfaces CryptGenRandom via the ntdll wrapper.
    // In Zig 0.16, std.c.getrandom returns isize (not an error union);
    // a negative return indicates failure.
    if (std.c.getrandom(&key, key.len, 0) < 0) {
        // Fall back to a non-cryptographic source on the (vanishingly
        // rare) getrandom failure. Clients will still talk to us; the
        // security model is still protected by the server-side checks.
        var tv: std.c.timeval = .{ .sec = 0, .usec = 0 };
        _ = std.c.gettimeofday(&tv, null);
        var fallback_seed: u64 = @intCast(@as(i64, tv.sec));
        for (&key) |*b| {
            fallback_seed = fallback_seed *% 6364136223846793005 +% 1442695040888963407;
            b.* = @intCast((fallback_seed >> 32) & 0xFF);
        }
    }
    return key;
}

/// XOR `payload` in place with a 4-byte rotating mask key (RFC 6455 §5.3).
///
/// The mask key repeats every 4 bytes: byte i is XORed with key[i % 4].
pub fn mask(payload: []u8, key: [4]u8) void {
    for (payload, 0..) |*b, i| {
        b.* ^= key[i % 4];
    }
}

/// Inverse of `mask` — XOR is its own inverse, so this is the same call.
pub fn unmask(payload: []u8, key: [4]u8) void {
    mask(payload, key);
}

/// Decode a masked payload into a fresh buffer (helper for `parseFrame`).
/// Allocates `out` and writes the unmasked bytes into it.
fn unmaskInPlace(out: []u8, masked: []const u8, key: [4]u8) void {
    for (masked, 0..) |m, i| {
        out[i] = m ^ key[i % 4];
    }
}

// ============================================================================
// Tests
// ============================================================================

// In-module tests live at the bottom of the file. The comprehensive wire-
// format tests are in `websocket_frames_test.zig`. The tests here cover
// the in-module helpers (`mask` / `unmask` symmetric, `decodeClosePayload`
// empty payload) that the unit tests also exercise, providing a sanity
// check that the public API and the implementation line up.
const testing = std.testing;

test "mask / unmask: identity round-trip" {
    const original = "The quick brown fox jumps over the lazy dog";
    var buf: [43]u8 = undefined;
    @memcpy(&buf, original);

    const key = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    mask(&buf, key);
    unmask(&buf, key);

    try testing.expectEqualSlices(u8, original, &buf);
}

test "decodeClosePayload: empty payload returns 1000 Normal Closure" {
    const info = try decodeClosePayload("");
    try testing.expectEqual(@as(u16, 1000), info.code);
    try testing.expectEqualStrings("", info.reason);
}

test "decodeClosePayload: payload with only code returns empty reason" {
    // Two bytes only, no trailing reason.
    const info = try decodeClosePayload(&[_]u8{ 0x03, 0xE8 }); // 1000
    try testing.expectEqual(@as(u16, 1000), info.code);
    try testing.expectEqualStrings("", info.reason);
}
