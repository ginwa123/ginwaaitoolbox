const std = @import("std");
const timing = @import("timing.zig");

/// Log level for filtering and formatting
pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,

    /// Convert to string representation
    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    /// Parse from string (case-insensitive)
    pub fn fromString(str: []const u8) ?LogLevel {
        const upper = std.ascii.allocUpperString(std.heap.page_allocator, str) catch return null;
        defer std.heap.page_allocator.free(upper);
        
        if (std.mem.eql(u8, upper, "TRACE")) return .trace;
        if (std.mem.eql(u8, upper, "DEBUG")) return .debug;
        if (std.mem.eql(u8, upper, "INFO")) return .info;
        if (std.mem.eql(u8, upper, "WARN")) return .warn;
        if (std.mem.eql(u8, upper, "ERROR")) return .err;
        return null;
    }
};

/// Log entry data structure
pub const LogEntry = struct {
    level: LogLevel,
    timestamp: i64,
    request_id: ?[]const u8,
    message: []const u8,
    context: ?[]const u8 = null,

    /// Format timestamp as ISO string (caller owns memory)
    pub fn formatTimestampIso(self: *const LogEntry, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        return timing.timestampIso(allocator);
    }
};

/// ANSI color codes for terminal output
pub const AnsiColors = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const cyan = "\x1b[36m";
    pub const yellow = "\x1b[33m";
    pub const green = "\x1b[32m";
    pub const red = "\x1b[31m";
    pub const magenta = "\x1b[35m";
    pub const blue = "\x1b[34m";
    pub const white = "\x1b[37m";
    
    /// Color rotation for agent output
    pub const agent_colors = [_][]const u8{ cyan, green, yellow, dim };
};

/// Formatter interface trait
pub const Formatter = struct {
    /// Format a log entry (caller owns returned memory)
    formatFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, entry: LogEntry) anyerror![]const u8,
    ctx: *anyopaque,

    /// Format a log entry
    pub fn format(self: Formatter, allocator: std.mem.Allocator, entry: LogEntry) ![]const u8 {
        return self.formatFn(self.ctx, allocator, entry);
    }
};

/// Plain text formatter
pub const TextFormatter = struct {
    include_timestamp: bool = true,
    include_request_id: bool = true,

    pub fn init() TextFormatter {
        return .{};
    }

    pub fn formatter(self: *TextFormatter) Formatter {
        return .{
            .formatFn = formatImpl,
            .ctx = self,
        };
    }

    fn formatImpl(formatter_ctx: *anyopaque, allocator: std.mem.Allocator, entry: LogEntry) ![]const u8 {
        const self: *TextFormatter = @ptrCast(@alignCast(formatter_ctx));
        
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        
        // Timestamp
        if (self.include_timestamp) {
            const iso = try timing.timestampIso(allocator);
            defer allocator.free(iso);
            try writer.print("[{s}] ", .{iso});
        }
        
        // Level
        try writer.print("[{s}] ", .{entry.level.toString()});
        
        // Request ID
        if (self.include_request_id and entry.request_id != null) {
            try writer.print("[{s}] ", .{entry.request_id.?});
        }
        
        // Message
        try writer.print("{s}", .{entry.message});
        
        // Context
        if (entry.context) |entry_ctx| {
            try writer.print(" ({s})", .{entry_ctx});
        }
        
        try writer.writeByte('\n');
        
        return allocator.dupe(u8, fbs.getWritten());
    }
};

/// JSON structured output formatter
pub const JsonFormatter = struct {
    pretty: bool = false,

    pub fn init() JsonFormatter {
        return .{};
    }

    pub fn formatter(self: *JsonFormatter) Formatter {
        return .{
            .formatFn = formatImpl,
            .ctx = self,
        };
    }

    fn formatImpl(formatter_ctx: *anyopaque, allocator: std.mem.Allocator, entry: LogEntry) ![]const u8 {
        _ = formatter_ctx;
        
        // Build JSON object using anonymous struct
        const json_obj = struct {
            level: []const u8,
            timestamp: i64,
            request_id: ?[]const u8,
            message: []const u8,
            context: ?[]const u8,
        }{
            .level = entry.level.toString(),
            .timestamp = entry.timestamp,
            .request_id = entry.request_id,
            .message = entry.message,
            .context = entry.context,
        };
        
        const options: std.json.Stringify.Options = if (false) .{ .whitespace = .indent_2 } else .{};
        return std.json.Stringify.valueAlloc(allocator, json_obj, options);
    }
};

/// ANSI colorized formatter for TUI
pub const ColorFormatter = struct {
    include_timestamp: bool = true,
    include_request_id: bool = true,
    color_by_level: bool = true,

    pub fn init() ColorFormatter {
        return .{};
    }

    pub fn formatter(self: *ColorFormatter) Formatter {
        return .{
            .formatFn = formatImpl,
            .ctx = self,
        };
    }

    fn getLevelColor(level: LogLevel) []const u8 {
        return switch (level) {
            .trace => AnsiColors.dim,
            .debug => AnsiColors.cyan,
            .info => AnsiColors.green,
            .warn => AnsiColors.yellow,
            .err => AnsiColors.red,
        };
    }

    fn formatImpl(formatter_ctx: *anyopaque, allocator: std.mem.Allocator, entry: LogEntry) ![]const u8 {
        const self: *ColorFormatter = @ptrCast(@alignCast(formatter_ctx));
        
        var buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        
        const level_color = if (self.color_by_level) getLevelColor(entry.level) else "";
        const reset = if (self.color_by_level) AnsiColors.reset else "";
        
        // Timestamp (dimmed)
        if (self.include_timestamp) {
            const iso = try timing.timestampIso(allocator);
            defer allocator.free(iso);
            try writer.print("{s}{s}{s} ", .{ AnsiColors.dim, iso, AnsiColors.reset });
        }
        
        // Level (colored)
        try writer.print("{s}{s}{s} ", .{ level_color, entry.level.toString(), reset });
        
        // Request ID (cyan)
        if (self.include_request_id and entry.request_id != null) {
            try writer.print("{s}[{s}]{s} ", .{ AnsiColors.cyan, entry.request_id.?, AnsiColors.reset });
        }
        
        // Message
        try writer.print("{s}", .{entry.message});
        
        // Context (dimmed)
        if (entry.context) |entry_ctx| {
            try writer.print(" {s}({s}){s}", .{ AnsiColors.dim, entry_ctx, AnsiColors.reset });
        }
        
        try writer.writeByte('\n');
        
        return allocator.dupe(u8, fbs.getWritten());
    }
};

/// Get color for agent index (rotates through colors)
pub fn getAgentColor(agent_index: usize) []const u8 {
    return AnsiColors.agent_colors[agent_index % AnsiColors.agent_colors.len];
}

// Tests
test "LogLevel toString" {
    try std.testing.expectEqualStrings("TRACE", LogLevel.trace.toString());
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug.toString());
    try std.testing.expectEqualStrings("INFO", LogLevel.info.toString());
    try std.testing.expectEqualStrings("WARN", LogLevel.warn.toString());
    try std.testing.expectEqualStrings("ERROR", LogLevel.err.toString());
}

test "LogLevel fromString" {
    try std.testing.expectEqual(LogLevel.trace, LogLevel.fromString("trace").?);
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromString("DEBUG").?);
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("Info").?);
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("WARN").?);
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("error").?);
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("invalid"));
}

test "TextFormatter produces correct output" {
    var formatter = TextFormatter.init();
    const entry = LogEntry{
        .level = .info,
        .timestamp = 1234567890000,
        .request_id = "REQ-20240101-120000-ab12",
        .message = "Test message",
    };
    
    const output = try formatter.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    try std.testing.expect(std.mem.indexOf(u8, output, "[INFO]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "REQ-20240101-120000-ab12") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test message") != null);
}

test "JsonFormatter produces valid JSON" {
    var formatter = JsonFormatter{ .pretty = false };
    const entry = LogEntry{
        .level = .info,
        .timestamp = 1234567890000,
        .request_id = "REQ-20240101-120000-ab12",
        .message = "Test message",
    };
    
    const output = try formatter.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    
    try std.testing.expectEqualStrings("INFO", parsed.value.object.get("level").?.string);
    try std.testing.expectEqualStrings("Test message", parsed.value.object.get("message").?.string);
}

test "ColorFormatter includes ANSI codes" {
    var formatter = ColorFormatter.init();
    const entry = LogEntry{
        .level = .err,
        .timestamp = 1234567890000,
        .request_id = null,
        .message = "Error message",
    };
    
    const output = try formatter.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    // Should contain ANSI reset code
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
    // Should contain red color for error level
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31m") != null);
}

test "getAgentColor rotates through colors" {
    try std.testing.expectEqualStrings(AnsiColors.cyan, getAgentColor(0));
    try std.testing.expectEqualStrings(AnsiColors.green, getAgentColor(1));
    try std.testing.expectEqualStrings(AnsiColors.yellow, getAgentColor(2));
    try std.testing.expectEqualStrings(AnsiColors.dim, getAgentColor(3));
    try std.testing.expectEqualStrings(AnsiColors.cyan, getAgentColor(4)); // Wraps around
}

test "LogEntry with context" {
    var formatter = TextFormatter{ .include_timestamp = false, .include_request_id = false };
    const entry = LogEntry{
        .level = .info,
        .timestamp = 1234567890000,
        .request_id = null,
        .message = "User logged in",
        .context = "user_id=123",
    };
    
    const output = try formatter.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    try std.testing.expect(std.mem.indexOf(u8, output, "User logged in") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(user_id=123)") != null);
}
