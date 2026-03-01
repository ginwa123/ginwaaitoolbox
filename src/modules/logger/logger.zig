const std = @import("std");
const timing = @import("timing.zig");
const request_id = @import("request_id.zig");
const formatter = @import("formatter.zig");

/// Re-export types from formatter module
pub const LogLevel = formatter.LogLevel;
pub const LogEntry = formatter.LogEntry;
pub const Formatter = formatter.Formatter;
pub const TextFormatter = formatter.TextFormatter;
pub const JsonFormatter = formatter.JsonFormatter;
pub const ColorFormatter = formatter.ColorFormatter;
pub const AnsiColors = formatter.AnsiColors;
pub const getAgentColor = formatter.getAgentColor;

/// Re-export types from request_id module
pub const RequestId = request_id.RequestId;
pub const SessionId = request_id.SessionId;
pub const generateRequestId = request_id.generateRequestId;
pub const generateSessionId = request_id.generateSessionId;

/// Re-export timing functions
pub const timestampMs = timing.timestampMs;
pub const elapsedMs = timing.elapsedMs;
pub const formatDuration = timing.formatDuration;
pub const timestampIso = timing.timestampIso;
pub const timestampCompact = timing.timestampCompact;

/// Configuration for Logger
pub const LoggerConfig = struct {
    /// Minimum log level to output (messages below this level are filtered)
    min_level: LogLevel = .info,
    /// Include timestamp in output
    include_timestamp: bool = true,
    /// Include request ID in output
    include_request_id: bool = true,
    /// Output writer (defaults to stdout)
    output: ?std.fs.File = null,
};

/// Thread-safe logger with pluggable formatters
pub const Logger = struct {
    allocator: std.mem.Allocator,
    config: LoggerConfig,
    mutex: std.Thread.Mutex,
    formatter_ctx: FormatterContext,
    request_id: ?RequestId,
    
    const FormatterContext = union(enum) {
        text: TextFormatter,
        json: JsonFormatter,
        color: ColorFormatter,
    };

    /// Initialize a new Logger with text formatter
    pub fn init(allocator: std.mem.Allocator, config: LoggerConfig) Logger {
        return .{
            .allocator = allocator,
            .config = config,
            .mutex = .{},
            .formatter_ctx = .{ .text = TextFormatter{
                .include_timestamp = config.include_timestamp,
                .include_request_id = config.include_request_id,
            }},
            .request_id = null,
        };
    }

    /// Initialize a new Logger with JSON formatter
    pub fn initJson(allocator: std.mem.Allocator, config: LoggerConfig) Logger {
        return .{
            .allocator = allocator,
            .config = config,
            .mutex = .{},
            .formatter_ctx = .{ .json = JsonFormatter{ .pretty = false } },
            .request_id = null,
        };
    }

    /// Initialize a new Logger with color formatter (for TUI)
    pub fn initColor(allocator: std.mem.Allocator, config: LoggerConfig) Logger {
        return .{
            .allocator = allocator,
            .config = config,
            .mutex = .{},
            .formatter_ctx = .{ .color = ColorFormatter{
                .include_timestamp = config.include_timestamp,
                .include_request_id = config.include_request_id,
                .color_by_level = true,
            }},
            .request_id = null,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Logger) void {
        // No heap allocations to clean up in Logger itself
        // The mutex is statically allocated
        _ = self;
    }

    /// Set a new request ID for subsequent log messages
    pub fn setRequestId(self: *Logger, id: RequestId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.request_id = id;
    }

    /// Generate and set a new request ID
    pub fn generateAndSetRequestId(self: *Logger) RequestId {
        const id = generateRequestId();
        self.setRequestId(id);
        return id;
    }

    /// Clear the current request ID
    pub fn clearRequestId(self: *Logger) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.request_id = null;
    }

    /// Get the current request ID as a string (if set)
    pub fn getRequestIdString(self: *const Logger) ?[]const u8 {
        if (self.request_id) |id| {
            return id.toString();
        }
        return null;
    }

    /// Log a message at the specified level
    pub fn log(self: *Logger, level: LogLevel, message: []const u8) !void {
        // Filter by minimum level
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        const entry = LogEntry{
            .level = level,
            .timestamp = timestampMs(),
            .request_id = self.getRequestIdString(),
            .message = message,
        };

        try self.writeEntry(entry);
    }

    /// Log a message at the specified level with context
    pub fn logWithContext(self: *Logger, level: LogLevel, message: []const u8, context: []const u8) !void {
        // Filter by minimum level
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        const entry = LogEntry{
            .level = level,
            .timestamp = timestampMs(),
            .request_id = self.getRequestIdString(),
            .message = message,
            .context = context,
        };

        try self.writeEntry(entry);
    }

    /// Log a formatted message at the specified level
    pub fn logFmt(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(message);
        try self.log(level, message);
    }

    /// Log at TRACE level
    pub fn trace(self: *Logger, message: []const u8) !void {
        try self.log(.trace, message);
    }

    /// Log at DEBUG level
    pub fn debug(self: *Logger, message: []const u8) !void {
        try self.log(.debug, message);
    }

    /// Log at INFO level
    pub fn info(self: *Logger, message: []const u8) !void {
        try self.log(.info, message);
    }

    /// Log at WARN level
    pub fn warn(self: *Logger, message: []const u8) !void {
        try self.log(.warn, message);
    }

    /// Log at ERROR level
    pub fn err(self: *Logger, message: []const u8) !void {
        try self.log(.err, message);
    }

    /// Log formatted at TRACE level
    pub fn traceFmt(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.logFmt(.trace, fmt, args);
    }

    /// Log formatted at DEBUG level
    pub fn debugFmt(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.logFmt(.debug, fmt, args);
    }

    /// Log formatted at INFO level
    pub fn infoFmt(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.logFmt(.info, fmt, args);
    }

    /// Log formatted at WARN level
    pub fn warnFmt(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.logFmt(.warn, fmt, args);
    }

    /// Log formatted at ERROR level
    pub fn errFmt(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.logFmt(.err, fmt, args);
    }

    /// Write a log entry using the configured formatter
    fn writeEntry(self: *Logger, entry: LogEntry) !void {
        // Format the entry
        const output: []const u8 = switch (self.formatter_ctx) {
            .text => |*f| try f.formatter().format(self.allocator, entry),
            .json => |*f| try f.formatter().format(self.allocator, entry),
            .color => |*f| try f.formatter().format(self.allocator, entry),
        };
        defer self.allocator.free(output);

        // Thread-safe write to output
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = self.config.output orelse std.fs.File.stdout();
        try file.writeAll(output);
    }

    /// Set the minimum log level
    pub fn setMinLevel(self: *Logger, level: LogLevel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.config.min_level = level;
    }

    /// Get the current minimum log level
    pub fn getMinLevel(self: *const Logger) LogLevel {
        return self.config.min_level;
    }
};

/// Global logger instance (optional convenience)
var global_logger: ?Logger = null;
var global_mutex: std.Thread.Mutex = .{};

/// Initialize the global logger
pub fn initGlobal(allocator: std.mem.Allocator, config: LoggerConfig) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    
    if (global_logger) |*logger| {
        logger.deinit();
    }
    global_logger = Logger.init(allocator, config);
}

/// Initialize the global logger with color formatter
pub fn initGlobalColor(allocator: std.mem.Allocator, config: LoggerConfig) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    
    if (global_logger) |*logger| {
        logger.deinit();
    }
    global_logger = Logger.initColor(allocator, config);
}

/// Deinitialize the global logger
pub fn deinitGlobal() void {
    global_mutex.lock();
    defer global_mutex.unlock();
    
    if (global_logger) |*logger| {
        logger.deinit();
        global_logger = null;
    }
}

/// Get the global logger (returns null if not initialized)
pub fn getGlobal() ?*Logger {
    global_mutex.lock();
    defer global_mutex.unlock();
    
    if (global_logger) |*logger| {
        return logger;
    }
    return null;
}

// Tests
test "Logger init and deinit" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{});
    defer logger.deinit();
    
    try std.testing.expectEqual(LogLevel.info, logger.getMinLevel());
}

test "Logger with custom config" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{
        .min_level = .debug,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger.deinit();
    
    try std.testing.expectEqual(LogLevel.debug, logger.getMinLevel());
}

test "Logger setMinLevel" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{ .min_level = .info });
    defer logger.deinit();
    
    try std.testing.expectEqual(LogLevel.info, logger.getMinLevel());
    
    logger.setMinLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, logger.getMinLevel());
}

test "Logger request ID management" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{});
    defer logger.deinit();
    
    // Initially no request ID
    try std.testing.expectEqual(@as(?[]const u8, null), logger.getRequestIdString());
    
    // Set a request ID
    const id = generateRequestId();
    logger.setRequestId(id);
    
    const id_str = logger.getRequestIdString();
    try std.testing.expect(id_str != null);
    try std.testing.expect(std.mem.startsWith(u8, id_str.?, "REQ-"));
    
    // Clear request ID
    logger.clearRequestId();
    try std.testing.expectEqual(@as(?[]const u8, null), logger.getRequestIdString());
}

test "Logger generateAndSetRequestId" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{});
    defer logger.deinit();
    
    const id = logger.generateAndSetRequestId();
    const id_str = id.toString();
    
    try std.testing.expect(std.mem.startsWith(u8, id_str, "REQ-"));
    try std.testing.expectEqual(id_str.len, 24);
}

test "Logger filters by minimum level" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{ .min_level = .warn });
    defer logger.deinit();
    
    // These should be filtered (no error, just skipped)
    try logger.trace("trace message");
    try logger.debug("debug message");
    try logger.info("info message");
    
    // These should pass
    try logger.warn("warn message");
    try logger.err("error message");
}

test "Logger with JSON formatter" {
    const allocator = std.testing.allocator;
    var logger = Logger.initJson(allocator, .{ .min_level = .info });
    defer logger.deinit();
    
    try logger.info("Test JSON message");
}

test "Logger with color formatter" {
    const allocator = std.testing.allocator;
    var logger = Logger.initColor(allocator, .{ .min_level = .info });
    defer logger.deinit();
    
    try logger.info("Test color message");
    try logger.err("Test error message");
}

test "Logger formatted messages" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{ .min_level = .debug });
    defer logger.deinit();
    
    try logger.debugFmt("User {s} logged in", .{"alice"});
    try logger.infoFmt("Processing {d} items", .{42});
    try logger.warnFmt("Low memory: {d}MB remaining", .{128});
    try logger.errFmt("Failed to connect to {s}:{d}", .{ "localhost", 8080 });
}

test "Logger logWithContext" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{ .min_level = .info });
    defer logger.deinit();
    
    try logger.logWithContext(.info, "User action", "user_id=123&action=login");
}

test "Global logger" {
    const allocator = std.testing.allocator;
    initGlobal(allocator, .{ .min_level = .info });
    defer deinitGlobal();
    
    const logger = getGlobal();
    try std.testing.expect(logger != null);
    try std.testing.expectEqual(LogLevel.info, logger.?.getMinLevel());
}

test "LogLevel ordering" {
    // Verify log levels are ordered correctly for filtering
    try std.testing.expect(@intFromEnum(LogLevel.trace) < @intFromEnum(LogLevel.debug));
    try std.testing.expect(@intFromEnum(LogLevel.debug) < @intFromEnum(LogLevel.info));
    try std.testing.expect(@intFromEnum(LogLevel.info) < @intFromEnum(LogLevel.warn));
    try std.testing.expect(@intFromEnum(LogLevel.warn) < @intFromEnum(LogLevel.err));
}
