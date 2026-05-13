const std = @import("std");
const timing = @import("Timing.zig");

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

    /// Initialize a new SessionId with random hex
    pub fn init() SessionId {
        var self: SessionId = undefined;
        
        // Generate random 8-character hex using high-res timestamp-seeded RNG
        var random_bytes: [4]u8 = undefined;
        const ts = std.Io.Timestamp.now(std.testing.io, .real);
        // Use nanoseconds + pointer as seed for uniqueness
        const seed = @as(u64, @intCast(ts.nanoseconds)) ^ @as(u64, @intFromPtr(&self));
        var rng = std.Random.DefaultPrng.init(seed);
        rng.fill(&random_bytes);
        
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