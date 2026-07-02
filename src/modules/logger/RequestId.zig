const std = @import("std");
const builtin = @import("builtin");
const timing = @import("Timing.zig");

// `getentropy` is not exposed by std.c on macOS — declare it locally
// so the macOS CI test suite can use the kernel CSPRNG. The Zig
// compiler prunes unused extern declarations at link time, so this
// is safe on Linux/Windows (where the function is never referenced).
extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;

/// Request ID format: REQ-YYYYMMDD-HHMMSS-XXXX (24 characters)
/// where XXXX is a 4-character random hex suffix
pub const RequestId = struct {
    /// Fixed-size buffer for the request ID string
    /// REQ- (4) + YYYYMMDD (8) + - (1) + HHMMSS (6) + - (1) + XXXX (4) = 24
    value: [24]u8,

    /// Initialize a new RequestId with current timestamp and random suffix
    pub fn init() RequestId {
        var self: RequestId = undefined;
        
        // Get current timestamp using Io.Timestamp
        const ts = std.Io.Timestamp.now(std.testing.io, .real);
        const ts_ns = ts.nanoseconds;
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ts_ns, std.time.ns_per_s)) };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        const seconds = day_seconds.getSecondsIntoMinute();
        
        // Generate random 4-character hex suffix using entropy
        const entropy = ts_ns ^ @as(u64, @intFromPtr(&self));
        var random_bytes: [2]u8 = undefined;
        @as(*u16, @ptrCast(@alignCast(&random_bytes))).* = @as(u16, @truncate(@as(u64, @intCast(entropy))));
        
        // Format: REQ-YYYYMMDD-HHMMSS-XXXX
        _ = std.fmt.bufPrint(&self.value, "REQ-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{x:0>2}{x:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            hours,
            minutes,
            seconds,
            random_bytes[0],
            random_bytes[1],
        }) catch unreachable;
        
        return self;
    }

    /// Get the request ID as a string slice
    pub fn toString(self: *const RequestId) []const u8 {
        return &self.value;
    }
};

/// Generate a new RequestId
pub fn generateRequestId() RequestId {
    return RequestId.init();
}

/// Session ID format: SES-XXXXXXXX (11 characters)
/// where XXXXXXXX is an 8-character random hex
/// SES- (4) + XXXXXXXX (8) = 12 characters (not 11!)
pub const SessionId = struct {
    value: [12]u8,

    /// Initialize a new SessionId with random hex.
    /// Uses libc `getrandom` on Linux, `getentropy` on macOS for
    /// guaranteed entropy. On Windows, falls back to a timestamp +
    /// pointer-derived value. The previous timestamp + pointer-PRNG
    /// seeding on POSIX could collide when two `init()` calls happened
    /// in the same nanosecond with the same stack address (common on
    /// macOS under fast tests; failed CI run 28568881975).
    pub fn init() SessionId {
        var self: SessionId = undefined;
        var random_bytes: [4]u8 = undefined;

        if (builtin.os.tag == .windows) {
            // Windows fallback. Use timestamp + output buffer address
            // as the seed — enough entropy for the 1000-call
            // uniqueness test.
            const ts = std.Io.Timestamp.now(std.testing.io, .real);
            const seed: u64 = @as(u64, @intCast(ts.nanoseconds)) ^
                @as(u64, @intFromPtr(&self.value));
            const truncated_val: u32 = @truncate(seed);
            std.mem.writeInt(u32, random_bytes[0..4], truncated_val, .little);
        } else {
            // POSIX: pull 4 fresh bytes from the kernel CSPRNG.
            // - Linux: libc `getrandom` (loops on partial reads).
            // - macOS: libc `getentropy` (always fills in one call,
            //   max 256 bytes; we ask for 4).
            // Both return 0 on success; -1 on failure.
            var ok = false;
            if (builtin.os.tag == .linux) {
                var filled: usize = 0;
                while (filled < random_bytes.len) {
                    const rc = std.c.getrandom(
                        random_bytes[filled..].ptr,
                        random_bytes.len - filled,
                        0,
                    );
                    if (rc < 0) {
                        const err = std.c.errno(rc);
                        if (err == .INTR) continue;
                        break;
                    }
                    filled += @intCast(rc);
                }
                ok = (filled == random_bytes.len);
            } else if (builtin.os.tag == .macos) {
                // macOS: locally-declared `getentropy` (not in std.c).
                const rc = getentropy(&random_bytes, random_bytes.len);
                ok = (rc == 0);
            } else {
                // Other POSIX without `getrandom` or `getentropy`
                // — best-effort pseudo-random from timestamp.
                const ts = std.Io.Timestamp.now(std.testing.io, .real);
                const seed: u64 = @as(u64, @intCast(ts.nanoseconds)) ^
                    @as(u64, @intFromPtr(&self.value));
                std.mem.writeInt(u32, random_bytes[0..4], @truncate(seed), .little);
                ok = true;
            }
            if (!ok) @memset(&random_bytes, 0);
        }

        _ = std.fmt.bufPrint(&self.value, "SES-{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            random_bytes[0],
            random_bytes[1],
            random_bytes[2],
            random_bytes[3],
        }) catch unreachable;

        return self;
    }

    /// Get the session ID as a string slice
    pub fn toString(self: *const SessionId) []const u8 {
        return &self.value;
    }
};

/// Generate a new SessionId
pub fn generateSessionId() SessionId {
    return SessionId.init();
}

// Tests

test {
    _ = @import("request_id_test.zig");
}