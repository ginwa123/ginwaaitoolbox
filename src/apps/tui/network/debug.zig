const std = @import("std");

/// Debug logging levels
pub const DebugLevel = enum(u8) {
    off = 0,
    err = 1,
    info = 2,
    verbose = 3,
};

/// Global debug level - set via environment or compile time
pub var global_debug_level: DebugLevel = .off;

/// ANSI color codes for terminal output
const colors = struct {
    const reset = "\x1b[0m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const dim = "\x1b[2m";
};

/// Log a message at the specified level
pub fn log(level: DebugLevel, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(global_debug_level)) return;
    
    const level_str = switch (level) {
        .err => "ERROR",
        .info => "INFO ",
        .verbose => "VERB ",
    };
    
    const color = switch (level) {
        .err => colors.red,
        .info => colors.cyan,
        .verbose => colors.dim,
        .off => colors.reset,
    };
    
    const timestamp = std.time.timestamp();
    std.debug.print("{s}[{s}][{d}] {s}" ++ fmt ++ "{s}\n", .{
        color, level_str, timestamp, "", args, colors.reset,
    });
}

/// Log an error with context
pub fn logError(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

/// Log an info message
pub fn logInfo(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

/// Log verbose debug info
pub fn logVerbose(comptime fmt: []const u8, args: anytype) void {
    log(.verbose, fmt, args);
}

/// Dump hex data for debugging raw streams
pub fn dumpHex(label: []const u8, data: []const u8, max_len: usize) void {
    if (@intFromEnum(global_debug_level) < @intFromEnum(DebugLevel.verbose)) return;
    
    const show_len = @min(data.len, max_len);
    logVerbose("{s} ({d}/{d} bytes):", .{label, show_len, data.len});
    
    var i: usize = 0;
    var line = std.ArrayList(u8).empty;
    while (i < show_len) : (i += 1) {
        _ = line.writer().print("{x:0>2} ", .{data[i]}) catch break;
        if (i % 16 == 15 or i == show_len - 1) {
            logVerbose("  {s}", .{line.items});
            line.clearRetainingCapacity();
        }
    }
}

/// Set debug level from string
pub fn setLevelFromString(level_str: []const u8) void {
    if (std.mem.eql(u8, level_str, "off")) global_debug_level = .off
    else if (std.mem.eql(u8, level_str, "error")) global_debug_level = .err
    else if (std.mem.eql(u8, level_str, "info")) global_debug_level = .info
    else if (std.mem.eql(u8, level_str, "verbose")) global_debug_level = .verbose;
}

test "debug level parsing" {
    setLevelFromString("error");
    try std.testing.expect(global_debug_level == .err);
    
    setLevelFromString("verbose");
    try std.testing.expect(global_debug_level == .verbose);
    
    setLevelFromString("invalid");
    try std.testing.expect(global_debug_level == .verbose); // unchanged
}
