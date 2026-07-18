//! UUID v4 generator for nalar's per-install LLM end-user identifier.
//!
//! Mirrors the libc-CSPRNG pattern from `src/modules/logger/RequestId.zig::SessionId.init`:
//!   - Linux: libc `getrandom` (loops on partial reads)
//!   - macOS: locally-declared `getentropy` (always fills in one call, max 256 bytes)
//!   - Windows / other: timestamp + output-buffer-address entropy (NOT crypto-grade,
//!     but matches the RequestId fallback used by the rest of nalar).
//!
//! Format: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" (36 chars), per RFC 4122 §4.4.

const std = @import("std");
const builtin = @import("builtin");

// macOS doesn't expose `getentropy` via `std.c`. Declare it locally;
// Zig's linker prunes unused extern declarations, so this is harmless
// on Linux/Windows (where the symbol is never referenced).
extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;

/// Generate a UUID v4 string into `buf` (must be a `[36]u8`).
/// The output is written verbatim; the caller does NOT need to NUL-terminate
/// because the length is fixed and known.
pub fn generateInstallId(buf: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);

    // Set version (4) and variant (10xx) bits per RFC 4122 §4.4.
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    const hex = "0123456789abcdef";
    var j: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[j] = '-';
            j += 1;
        }
        buf[j] = hex[b >> 4];
        buf[j + 1] = hex[b & 0x0F];
        j += 2;
    }
}

fn fillRandom(bytes: *[16]u8) void {
    if (builtin.os.tag == .linux) {
        var filled: usize = 0;
        while (filled < bytes.len) {
            const rc = std.c.getrandom(bytes[filled..].ptr, bytes.len - filled, 0);
            if (rc < 0) {
                const err = std.c.errno(rc);
                if (err == .INTR) continue;
                break;
            }
            filled += @intCast(rc);
        }
        if (filled == bytes.len) return;
        // Partial fill — fall through to the weak-entropy fallback
    } else if (builtin.os.tag == .macos) {
        if (getentropy(bytes.ptr, bytes.len) == 0) return;
        // getentropy failed — fall through to the weak-entropy fallback
    }
    // Fallback for Windows + getrandom/getentropy failures:
    // timestamp + output-buffer-address seed.
    const ts = std.Io.Timestamp.now(std.testing.io, .real);
    const seed: u64 = @as(u64, @intCast(ts.nanoseconds)) ^
        @as(u64, @intFromPtr(bytes));
    const truncated: u64 = @truncate(seed);
    @as(*u64, @ptrCast(@alignCast(bytes[0..8]))).* = truncated;
    @as(*u64, @ptrCast(@alignCast(bytes[8..16]))).* = @truncate(seed >> 1);
}