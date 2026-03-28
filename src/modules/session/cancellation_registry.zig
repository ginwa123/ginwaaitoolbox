const std = @import("std");

/// Thread-safe registry for per-session cancellation flags
pub const CancellationRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    sessions: std.StringHashMap(*std.atomic.Value(bool)),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .sessions = std.StringHashMap(*std.atomic.Value(bool)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    /// Register a new session with a cancellation flag
    pub fn register(self: *Self, session_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If already registered, just reset it
        if (self.sessions.get(session_id)) |atomic| {
            atomic.store(false, .seq_cst);
            return;
        }

        const atomic = try self.allocator.create(std.atomic.Value(bool));
        atomic.* = std.atomic.Value(bool).init(false);

        const key = try self.allocator.dupe(u8, session_id);
        try self.sessions.put(key, atomic);
    }

    /// Unregister a session and free its resources
    pub fn unregister(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.fetchRemove(session_id)) |entry| {
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }
    }

    /// Cancel a specific session
    pub fn cancel(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |atomic| {
            atomic.store(true, .seq_cst);
        }
    }

    /// Reset cancellation for a specific session
    pub fn reset(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |atomic| {
            atomic.store(false, .seq_cst);
        }
    }

    /// Check if a session is cancelled
    pub fn is_cancelled(self: *Self, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |atomic| {
            return atomic.load(.seq_cst);
        }
        return false;
    }

    /// Check if a session is registered
    pub fn isRegistered(self: *Self, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.sessions.contains(session_id);
    }
    /// Check if any sessions are registered
    pub fn hasSessions(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count() > 0;
    }

    /// Get the number of registered sessions
    pub fn sessionCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }


    /// Get a direct pointer to the atomic for a session (for TUIWorkflow to store)
    /// Caller must ensure session is registered
    pub fn getAtomic(self: *Self, session_id: []const u8) ?*std.atomic.Value(bool) {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.sessions.get(session_id);
    }
};

// Global registry instance
var g_registry: ?CancellationRegistry = null;
var g_registry_mutex: std.Thread.Mutex = .{};

/// Initialize the global registry (call once at startup)
pub fn initGlobalRegistry(allocator: std.mem.Allocator) void {
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    if (g_registry == null) {
        g_registry = CancellationRegistry.init(allocator);
    }
}

/// Get the global registry instance
pub fn get_global_registry() ?*CancellationRegistry {
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    if (g_registry) |*registry| {
        return registry;
    }
    return null;
}

/// Deinitialize the global registry (call at shutdown)
pub fn deinitGlobalRegistry() void {
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    if (g_registry) |*registry| {
        registry.deinit();
        g_registry = null;
    }
}

test {
    _ = @import("cancellation_registry_test.zig");
}
