const std = @import("std");
const timing = @import("Timing.zig");

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
    file: ?[]const u8 = null,
    line: ?u32 = null,

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
    include_location: bool = false,

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
        
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        
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
        
        // Location (file:line)
        if (self.include_location and entry.file != null) {
            try writer.print("[{s}:{d}] ", .{entry.file.?, entry.line.?});
        }
        
        // Message
        try writer.print("{s}", .{entry.message});
        
        // Context
        if (entry.context) |entry_ctx| {
            try writer.print(" ({s})", .{entry_ctx});
        }
        
        try writer.writeByte('\n');
        
        return list.toOwnedSlice(allocator);
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
            file: ?[]const u8,
            line: ?u32,
        }{
            .level = entry.level.toString(),
            .timestamp = entry.timestamp,
            .request_id = entry.request_id,
            .message = entry.message,
            .context = entry.context,
            .file = entry.file,
            .line = entry.line,
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
    include_location: bool = false,

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
        
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        
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
        
        // Location (dimmed)
        if (self.include_location and entry.file != null) {
            try writer.print("{s}[{s}:{d}]{s} ", .{ AnsiColors.dim, entry.file.?, entry.line.?, AnsiColors.reset });
        }
        
        // Message
        try writer.print("{s}", .{entry.message});
        
        // Context (dimmed)
        if (entry.context) |entry_ctx| {
            try writer.print(" {s}({s}){s}", .{ AnsiColors.dim, entry_ctx, AnsiColors.reset });
        }
        
        try writer.writeByte('\n');
        
        return list.toOwnedSlice(allocator);
    }
};

/// Get color for agent index (rotates through colors)
pub fn getAgentColor(agent_index: usize) []const u8 {
    return AnsiColors.agent_colors[agent_index % AnsiColors.agent_colors.len];
}

// Tests

test {
    _ = @import("formatter_test.zig");
}
