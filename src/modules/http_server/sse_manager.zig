const std = @import("std");
const httpz = @import("httpz");

pub const SseEvent = struct {
    data: []const u8,

    /// Maximum size for SSE event formatting (16KB - should be enough for any chunk)
    pub const MAX_SSE_SIZE = 16384;

    /// Format SSE event into a provided buffer (stack-allocated, no heap allocations)
    /// Returns the formatted bytes or error.BufferTooSmall if buffer is insufficient
    pub fn formatInto(self: SseEvent, buf: []u8) error{BufferTooSmall}![]u8 {
        var pos: usize = 0;

        // Write data lines: "<line>\n" for each line (raw XML, no "data:" prefix)
        var iter = std.mem.splitScalar(u8, self.data, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue; // Skip empty lines from split
            const needed_for_line = line.len + 1;
            if (pos + needed_for_line > buf.len) return error.BufferTooSmall;
            @memcpy(buf[pos..][0..line.len], line);
            pos += line.len;
            buf[pos] = '\n';
            pos += 1;
        }

        // Final newline to end the event
        if (pos + 1 > buf.len) return error.BufferTooSmall;
        buf[pos] = '\n';
        pos += 1;

        return buf[0..pos];
    }

    pub fn format(self: SseEvent, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        // Write raw XML data (no "data:" prefix)
        try result.appendSlice(allocator, self.data);
        try result.appendSlice(allocator, "\n\n");

        return result.toOwnedSlice(allocator);
    }
};

/// Thread-safe manager for SSE connections
/// Thread-safe manager for SSE connections using direct stream writing
pub const SseConnectionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Map from session_id to stream - stream is owned by httpz's startEventStream
    connections: std.StringHashMap(std.net.Stream),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(std.net.Stream).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Note: we don't close the stream here - httpz manages that
        }
        self.connections.deinit();
    }

    /// Register a new SSE connection
    pub fn register(self: *Self, session_id: []const u8, stream: std.net.Stream) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key);

        try self.connections.put(key, stream);
        std.log.info("SSE registered: session_id={s}", .{session_id});
    }

    /// Remove a connection (called when client disconnects)
    pub fn remove(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.fetchRemove(session_id)) |entry| {
            self.allocator.free(entry.key);
            std.log.info("SSE removed: session_id={s}", .{session_id});
        }
    }

    /// Send an event to a specific session (uses stack buffer, falls back to heap for large events)
    /// Includes retry logic for race conditions where session isn't registered yet
    pub fn sendEvent(self: *Self, session_id: []const u8, event: SseEvent) !void {
        // Retry up to 3 times with 50ms delay to handle race condition where
        // SSE stream handler hasn't registered the session yet
        const max_retries = 3;
        const retry_delay_ms = 50;

        for (0..max_retries) |attempt| {
            self.mutex.lock();
            if (self.connections.get(session_id)) |stream| {
                // First try with stack buffer (fast path for small events)
                var stack_buf: [SseEvent.MAX_SSE_SIZE]u8 = undefined;
                const formatted = event.formatInto(&stack_buf) catch |err| {
                    if (err == error.BufferTooSmall) {
                        // Stack buffer too small - fall back to heap allocation for large events
                        const heap_formatted = event.format(self.allocator) catch |heap_err| {
                            self.mutex.unlock();
                            std.log.err("SSE sendEvent: heap allocation failed: {s}", .{@errorName(heap_err)});
                            return error.AllocationFailed;
                        };
                        defer self.allocator.free(heap_formatted);
                        stream.writeAll(heap_formatted) catch |write_err| {
                            self.mutex.unlock();
                            std.log.err("SSE sendEvent: write failed: {s}", .{@errorName(write_err)});
                            return error.WriteFailed;
                        };
                        self.mutex.unlock();
                        return; // Success with heap buffer
                    }
                    self.mutex.unlock();
                    return err;
                };

                // Write directly to stream
                stream.writeAll(formatted) catch |err| {
                    self.mutex.unlock();
                    std.log.err("SSE sendEvent: write failed: {s}", .{@errorName(err)});
                    return error.WriteFailed;
                };
                self.mutex.unlock();
                return; // Success
            }
            self.mutex.unlock();

            // Session not found - retry after short delay
            if (attempt < max_retries - 1) {
                std.log.warn("SSE sendEvent: session {s} not found, retrying ({}/{})...", .{ session_id, attempt + 1, max_retries });
                std.Thread.sleep(retry_delay_ms * 1_000_000);
            }
        }

        // All retries exhausted
        std.log.err("SSE sendEvent: session not found after {} retries: {s}", .{ max_retries, session_id });
        return error.SessionNotFound;
    }

    /// Check if a session exists
    pub fn hasSession(self: *Self, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.contains(session_id);
    }

    /// Broadcast an event to ALL connected sessions
    /// Uses heap allocation for large events when stack buffer is too small
    pub fn broadcast(self: *Self, event: SseEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // First try stack buffer, fall back to heap for large events
        const formatted = blk: {
            var stack_buf: [SseEvent.MAX_SSE_SIZE]u8 = undefined;
            break :blk event.formatInto(&stack_buf) catch |err| {
                if (err == error.BufferTooSmall) {
                    // Fall back to heap allocation for large events
                    const heap_result = event.format(self.allocator) catch {
                        std.log.err("SSE broadcast: heap allocation failed", .{});
                        return;
                    };
                    defer self.allocator.free(heap_result);
                    // Write with heap buffer
                    var iter = self.connections.iterator();
                    while (iter.next()) |entry| {
                        entry.value_ptr.writeAll(heap_result) catch {
                            std.log.warn("SSE broadcast: failed to write to session {s}", .{entry.key_ptr.*});
                        };
                    }
                    return;
                }
                std.log.err("SSE broadcast: format failed: {s}", .{@errorName(err)});
                return;
            };
        };

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.writeAll(formatted) catch {
                std.log.warn("SSE broadcast: failed to write to session {s}", .{entry.key_ptr.*});
            };
        }
    }
};
