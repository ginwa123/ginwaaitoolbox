const std = @import("std");
const nalarcore = @import("nalarcore");
const process = nalarcore.helpers.process;

/// Hex digits for ID generation
pub const hex_digits = "0123456789abcdef";

pub fn generateSessionId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const timestamp: i64 = ts.toSeconds();
    // `process.getCurrentProcessId()` returns `i32` on all platforms
    // (POSIX and Windows). It used to return `std.c.pid_t` which is
    // `*anyopaque` on Windows — comparing that to an `i32` parsed from a
    // shell command would fail to compile cross-platform.
    const pid = process.getCurrentProcessId();
    // Use timestamp + PID + pointer for pseudo-random entropy
    const entropy: u64 = (@as(u64, @intCast(pid)) << 32) ^ @as(u64, @intCast(timestamp));
    var random_bytes: [8]u8 = undefined;
    @as(*u64, @ptrCast(@alignCast(&random_bytes))).* = entropy;

    // Convert random bytes to hex string
    var hex_chars: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_chars[i * 2] = hex_digits[b >> 4];
        hex_chars[i * 2 + 1] = hex_digits[b & 0xF];
    }

    return std.fmt.allocPrint(allocator, "sess_{d}_{s}", .{ timestamp, hex_chars });
}
