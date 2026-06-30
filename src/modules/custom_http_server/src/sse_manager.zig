const std = @import("std");
const posix = std.posix;
const socket = posix.system;
const c = std.c;

const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_bsd = switch (builtin.os.tag) {
    .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

const LOOP_COUNT = 4;

pub const Self = @This();

pub const SseClient = struct {
    io: std.Io,
    id: [16]u8,
    fd: i32,
    arena: std.heap.ArenaAllocator,
    alive: bool,
    last_heartbeat: u64,
    message_queue: std.ArrayListUnmanaged([]const u8),
    lock: std.Io.Mutex = .init,

    pub fn init(id: [16]u8, fd: i32, parent_allocator: std.mem.Allocator, io: std.Io) SseClient {
        return .{
            .id = id,
            .fd = fd,
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .alive = true,
            .last_heartbeat = timestamp(),
            .message_queue = .empty,
            .lock = .init,
            .io = io,
        };
    }

    pub fn allocator(self: *SseClient) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *SseClient) void {
        self.message_queue.deinit(self.allocator());
        self.arena.deinit();
        _ = socket.close(self.fd);
    }

    pub fn forceDestroy(self: *SseClient) void {
        _ = socket.close(self.fd);
    }

    pub fn markDisconnected(self: *SseClient) void {
        // Zig 0.16 std.Io.Mutex requires the `io` argument for
        // lock/unlock. The previous zero-arg call form compiled
        // under Zig 0.15 but is a compile error in 0.16 (member
        // function expected 1 argument(s), found 0). This function
        // is currently dead code (no callers in the codebase), but
        // fixing it now prevents the next person who wires it up
        // from hitting the same error.
        self.lock.lock(self.io) catch return;
        defer self.lock.unlock(self.io);
        self.alive = false;
    }

    pub fn sendEvent(self: *SseClient, event: []const u8) !void {
        // The lock covers all three writes of the chunked frame so a
        // concurrent sendHeartbeat / sendToClient on the same fd cannot
        // interleave its hex length between our hex length and data.
        self.lock.lock(self.io) catch return error.ClientDisconnected;
        defer self.lock.unlock(self.io);
        if (!self.alive) return error.ClientDisconnected;
        writeChunkedFrame(self.fd, event) catch {
            self.alive = false;
            return error.ClientDisconnected;
        };
    }
};

pub const SseManager = struct {
    io: std.Io,
    clients: std.AutoHashMapUnmanaged([16]u8, *SseClient),
    fd_to_id: std.AutoHashMapUnmanaged(i32, [16]u8),
    lock: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    server_allocator: std.mem.Allocator,
    running: bool,
    on_disconnect: ?*const fn (client_id: [16]u8) void = null,
    notify_pipe: [2]i32,

    pub fn init(allocator: std.mem.Allocator, server_allocator: std.mem.Allocator, io: std.Io) !SseManager {
        var notify_pipe: [2]i32 = .{ -1, -1 };
        if (!is_windows) {
            const rc = socket.pipe(&notify_pipe);
            if (rc < 0) return error.PipeFailed;
        }
        return .{
            .clients = .empty,
            .fd_to_id = .empty,
            .lock = .init,
            .allocator = allocator,
            .server_allocator = server_allocator,
            .running = true,
            .io = io,
            .notify_pipe = notify_pipe,
        };
    }

    pub fn deinit(self: *SseManager) void {
        self.running = false;
        if (self.notify_pipe[1] >= 0) {
            var byte_buf: [1]u8 = .{'q'};
            _ = socket.write(self.notify_pipe[1], &byte_buf, 1);
        }
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.forceDestroy();
            self.server_allocator.destroy(entry.value_ptr);
        }
        self.clients.clearRetainingCapacity();
        self.fd_to_id.clearRetainingCapacity();

        if (self.notify_pipe[0] >= 0) _ = socket.close(self.notify_pipe[0]);
        if (self.notify_pipe[1] >= 0) _ = socket.close(self.notify_pipe[1]);
    }

    pub fn registerClient(self: *SseManager, fd: i32) ![16]u8 {
        _ = try self.lock.lock(self.io);
        defer self.lock.unlock(self.io);

        if (self.getClientIdByFdLocked(fd)) |id| return id;

        var id: [16]u8 = undefined;
        while (true) {
            self.io.random(&id);
            if (!self.clients.contains(id)) break;
        }

        const client = try self.server_allocator.create(SseClient);
        client.* = SseClient.init(id, fd, self.allocator, self.io);

        try self.clients.put(self.server_allocator, id, client);
        try self.fd_to_id.put(self.server_allocator, fd, id);

        // Wake up all event loops so they pick up the new client
        self.notifyLoops();

        return id;
    }

    /// Test-only helper that registers `fd` with a caller-provided id,
    /// bypassing `self.io.random` (which requires being called on the
    /// Io runtime's own thread and therefore crashes when called from
    /// a unit test's main thread). NOT for production use — production
    /// code should call `registerClient` so the id is cryptographically
    /// random and collisions are detected.
    pub fn registerClientForTest(self: *SseManager, fd: i32, id: [16]u8) ![16]u8 {
        // Skip the std.Io.Mutex here: the Io runtime's `lock` requires
        // being called from the Io thread, and we're in a unit test's
        // main thread. Tests must not call this concurrently with
        // other SseManager methods.
        if (self.fd_to_id.get(fd)) |existing| return existing;
        if (self.clients.contains(id)) return error.TestIdAlreadyUsed;

        const client = try self.server_allocator.create(SseClient);
        client.* = SseClient.init(id, fd, self.allocator, self.io);

        try self.clients.put(self.server_allocator, id, client);
        try self.fd_to_id.put(self.server_allocator, fd, id);

        return id;
    }

    pub fn removeClient(self: *SseManager, id: [16]u8) void {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        if (self.clients.fetchRemove(id)) |entry| {
            _ = self.fd_to_id.remove(entry.value.*.fd);
            // Send the chunked-encoding terminator (0\r\n\r\n) BEFORE
            // closing the fd so intermediaries (Vite, browser) can
            // finalize their chunked-decoding state cleanly. The
            // write will fail silently if the peer is already gone
            // (which is the common POLL.HUP case), and that's fine.
            _ = sendAll(entry.value.*.fd, "0\r\n\r\n");
            entry.value.*.deinit();
            self.server_allocator.destroy(entry.value);
            if (self.on_disconnect) |cb| cb(id);
        }
    }

    pub fn removeClientByFd(self: *SseManager, fd: i32) ?[16]u8 {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        if (self.fd_to_id.fetchRemove(fd)) |entry| {
            const id = entry.value;
            if (self.clients.fetchRemove(id)) |client_entry| {
                // Same as removeClient: send terminator BEFORE close.
                _ = sendAll(client_entry.value.*.fd, "0\r\n\r\n");
                client_entry.value.*.deinit();
                self.server_allocator.destroy(client_entry.value);
            }
            if (self.on_disconnect) |cb| cb(id);
            return id;
        }
        return null;
    }

    fn getClientIdByFdLocked(self: *SseManager, fd: i32) ?[16]u8 {
        return self.fd_to_id.get(fd);
    }

    pub fn getClientIdByFd(self: *SseManager, fd: i32) ?[16]u8 {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);
        return self.getClientIdByFdLocked(fd);
    }

    fn notifyLoops(self: *SseManager) void {
        if (self.notify_pipe[1] >= 0) {
            var byte_buf: [1]u8 = .{'x'};
            _ = socket.write(self.notify_pipe[1], &byte_buf, 1);
        }
    }

    /// Start LOOP_COUNT concurrent event loops using std.Io.Group
    pub fn startEventLoop(self: *SseManager, heartbeat_secs: u32) !void {
        self.running = true;
        var group: std.Io.Group = .init;
        defer group.cancel(self.io);

        for (0..LOOP_COUNT) |loop_id| {
            try group.concurrent(
                self.io,
                struct {
                    fn run(mgr: *SseManager, secs: u32, id: usize) void {
                        mgr.runEventLoop(secs, id);
                    }
                }.run,
                .{ self, heartbeat_secs, loop_id },
            );
        }

        try group.await(self.io);
    }

    pub fn gracefulShutdown(self: *SseManager) void {
        const close_msg = "event: close\ndata: Server shutting down\n\n";

        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const fd = entry.value_ptr.*.fd;
            // Send the close event as one chunked frame, then send the
            // chunked-encoding terminator (0\r\n\r\n) so the peer can
            // finalize its chunked-decoding state cleanly. Both writes
            // are best-effort — `forceDestroy` below closes the fd
            // regardless, and a stale peer will get EPOLLHUP on its
            // next read.
            writeChunkedFrame(fd, close_msg) catch {};
            _ = sendAll(fd, "0\r\n\r\n");
        }

        while (self.clients.count() > 0) {
            var it2 = self.clients.iterator();
            if (it2.next()) |entry| {
                const id = entry.key_ptr.*;
                const fd = entry.value_ptr.*.fd;
                entry.value_ptr.*.forceDestroy();
                _ = self.clients.remove(id);
                _ = self.fd_to_id.remove(fd);
            }
        }
        self.clients.clearRetainingCapacity();
        self.fd_to_id.clearRetainingCapacity();
    }

    pub fn stop(self: *SseManager) void {
        self.running = false;
        self.notifyLoops();
    }

    /// Each loop handles clients at indices where client_index % LOOP_COUNT == loop_id
    fn runEventLoop(self: *SseManager, heartbeat_secs: u32, loop_id: usize) void {
        const heartbeat_ms: i32 = @intCast(heartbeat_secs * 1000);
        var last_hb: i64 = @intCast(timestamp());

        while (self.running) {
            // --- snapshot fds under lock (fast, no poll while holding lock) ---
            self.lock.lock(self.io) catch unreachable;

            var my_fds = std.ArrayListUnmanaged(i32).empty;
            defer my_fds.deinit(self.allocator);

            var it = self.clients.iterator();
            while (it.next()) |entry| {
                // deterministic ownership by client id — stable across inserts/removes
                if (entry.value_ptr.*.id[0] % LOOP_COUNT == loop_id) {
                    my_fds.append(self.allocator, entry.value_ptr.*.fd) catch break;
                }
            }
            self.lock.unlock(self.io); // release before poll — critical

            const has_pipe = self.notify_pipe[0] >= 0;
            const total_fds = if (has_pipe) my_fds.items.len + 1 else my_fds.items.len;

            if (total_fds == 0) {
                // no clients — wait for notification or heartbeat interval
                var ts: socket.timespec = .{
                    .sec = @intCast(heartbeat_secs),
                    .nsec = 0,
                };
                _ = socket.nanosleep(&ts, null);
                continue;
            }

            var poll_fds: []posix.pollfd = self.allocator.alloc(posix.pollfd, total_fds) catch {
                var ts: socket.timespec = .{
                    .sec = @intCast(heartbeat_secs),
                    .nsec = 0,
                };
                _ = socket.nanosleep(&ts, null);
                continue;
            };
            defer self.allocator.free(poll_fds);

            var idx: usize = 0;
            if (has_pipe) {
                poll_fds[0] = .{
                    .fd = self.notify_pipe[0],
                    .events = posix.POLL.IN,
                    .revents = undefined,
                };
                idx = 1;
            }
            for (my_fds.items) |fd| {
                poll_fds[idx] = .{
                    .fd = fd,
                    .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.NVAL,
                    .revents = undefined,
                };
                idx += 1;
            }

            // poll blocks here — lock is FREE, sendToClient/registerClient can proceed
            _ = posix.poll(poll_fds, heartbeat_ms) catch continue;

            for (poll_fds[0..total_fds]) |pfd| {
                const revents = @as(u16, @bitCast(pfd.revents));
                if (revents == 0) continue;

                const poll_err = @as(u16, @intCast(posix.POLL.ERR));
                const poll_hup = @as(u16, @intCast(posix.POLL.HUP));
                // POLL.NVAL is the only event the kernel can set on a
                // "sock but not IPv4" orphan FD — the classic signature
                // of a leaked FD whose underlying kernel socket has
                // already been reaped (peer FIN + 2MSL + unlink) but
                // whose userspace FD was never close()'d. Without this
                // branch, those FDs are invisible to the reaper and
                // accumulate until `RLIMIT_NOFILE` is hit, surfacing as
                // `ProcessFdQuotaExceeded` for every FD-allocating
                // syscall (`read_file`, `bash`, sub-agent `spawn`, etc.).
                const poll_nval = @as(u16, @intCast(posix.POLL.NVAL));
                const poll_in = @as(u16, @intCast(posix.POLL.IN));

                if (revents & (poll_err | poll_hup | poll_nval) != 0) {
                    _ = self.removeClientByFd(pfd.fd);
                    continue;
                }

                if (revents & poll_in != 0) {
                    if (has_pipe and pfd.fd == self.notify_pipe[0]) {
                        var buf: [64]u8 = undefined;
                        _ = socket.read(self.notify_pipe[0], &buf, buf.len);
                    } else {
                        var buf: [64]u8 = undefined;
                        const n = socket.read(pfd.fd, &buf, buf.len);
                        if (n <= 0) {
                            _ = self.removeClientByFd(pfd.fd);
                        }
                    }
                }
            }

            // only send heartbeat when actually due
            const now: i64 = @intCast(timestamp());
            if (now - last_hb >= heartbeat_ms) {
                self.sendHeartbeat(loop_id);
                last_hb = now;
                // Belt-and-suspenders sweep: pick up any client whose
                // `last_heartbeat` is older than 3 heartbeat cycles.
                // Defends against any future bug that lets a dead
                // client slip past the poll reaper (POLL.HUP/ERR/NVAL)
                // and the heartbeat reaper (EPIPE/ECONNRESET/EBADF).
                // Capped at 64 removals per iteration to avoid O(N²)
                // behaviour when many clients go stale at once (e.g.,
                // a server-side rollback).
                self.sweepStaleClients(@as(u64, @intCast(heartbeat_ms)) * 3, 64);
            }
        }
    }

    /// Sweep clients whose `last_heartbeat` is older than
    /// `max_stale_ms`. Removes up to `max_per_call` clients per call to
    /// bound the worst-case CPU cost when a large batch goes stale at
    /// once. Must be called under the per-loop cadence — typically
    /// once per heartbeat cycle.
    ///
    /// Exposed as `pub` so the unit test can verify the staleness
    /// sweep without standing up the full event loop. Production
    /// callers should rely on `runEventLoop`'s per-cycle call.
    pub fn sweepStaleClients(self: *SseManager, max_stale_ms: u64, max_per_call: usize) void {
        const now = timestamp();

        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);

        var stale_ids: std.ArrayListUnmanaged([16]u8) = .empty;
        defer stale_ids.deinit(self.allocator);

        var it = self.clients.iterator();
        outer: while (it.next()) |entry| {
            const client = entry.value_ptr.*;
            const age_ms = now -| client.last_heartbeat;
            if (age_ms > max_stale_ms) {
                stale_ids.append(self.allocator, client.id) catch break :outer;
                if (stale_ids.items.len >= max_per_call) break :outer;
            }
        }

        // Reap under the same lock. Mirrors the close-before-deinit
        // pattern in `removeClient` so partial-write chunked frames
        // don't produce `ERR_INCOMPLETE_CHUNKED_ENCODING` in the browser.
        for (stale_ids.items) |id| {
            if (self.clients.fetchRemove(id)) |entry| {
                const fd = entry.value.*.fd;
                _ = self.fd_to_id.remove(fd);
                _ = sendAll(fd, "0\r\n\r\n");
                entry.value.*.deinit();
                self.server_allocator.destroy(entry.value);
            }
        }
    }

    /// Only send heartbeat to clients owned by this loop
    fn sendHeartbeat(self: *SseManager, loop_id: usize) void {
        const ping = "data: ping\n\n";

        // Snapshot the client pointers under the lock. Without the lock,
        // a concurrent `registerClient` / `removeClient` could invalidate
        // the iterator or free a client we are about to dereference —
        // the resulting use-after-free corrupts the heap, and a write to
        // an already-closed fd can also produce a half-flushed chunked
        // frame (no terminating `0\r\n\r\n`), which the browser then
        // surfaces as `net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)`
        // after the long-idle page finally drops the connection.
        // The probability of hitting this race grows with uptime and
        // concurrent register/remove activity, which matches the
        // "long period on page" symptom from the user report.
        self.lock.lock(self.io) catch unreachable;
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        // Shard by `id[0] % LOOP_COUNT` to MATCH the poll loop's
        // sharding rule (`sse_manager.zig:308`). The previous
        // implementation used `global_idx % LOOP_COUNT`, which depended
        // on hashmap iteration order — two shards can disagree on which
        // loop "owns" a client. While every client was still heartbeated
        // (the modulo covered all residue classes), the sharding rule
        // had to match the poll loop's so future per-client ownership
        // invariants (e.g., the periodic sweep in
        // `sweepStaleClients`) can rely on a single source of truth.
        while (it.next()) |entry| {
            if (entry.value_ptr.*.id[0] % LOOP_COUNT == loop_id) {
                client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
            }
        }
        self.lock.unlock(self.io);

        var dead_ids: std.ArrayListUnmanaged([16]u8) = .empty;
        defer dead_ids.deinit(self.allocator);

        for (client_ptrs.items) |client| {
            // Only update `last_heartbeat` on a SUCCESSFUL write — a
            // failed heartbeat leaves the timestamp stale, so the
            // periodic sweep (`sweepStaleClients`) can catch the
            // client on the next iteration even if `dead_ids` itself
            // races with another thread's `removeClient` call.
            // Previously the timestamp was updated unconditionally,
            // which made the sweep blind to actual staleness.
            if (writeChunkedFrame(client.fd, ping)) |_| {
                client.last_heartbeat = timestamp();
            } else |_| {
                dead_ids.append(self.allocator, client.id) catch break;
            }
        }

        for (dead_ids.items) |id| {
            self.removeClient(id);
        }
    }

    pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
        const client = self.clients.get(id) orelse return error.ClientNotFound;

        // Route through the chunked-encoding helper so the peer's
        // HTTP/1.1 chunked-decoder can parse the byte stream. A
        // write failure (peer gone) means the client is dead; remove
        // it and bubble up the error to the caller.
        if (writeChunkedFrame(client.fd, data)) {
            // success
        } else |_| {
            self.removeClient(id);
            return error.ClientDisconnected;
        }
    }

    pub fn broadcast(self: *SseManager, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{data});
        defer self.allocator.free(event);

        self.lock.lock(self.io) catch unreachable;
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock(self.io);

        for (client_ptrs.items) |client| {
            // Send the broadcast as a chunked frame so the peer's
            // HTTP/1.1 chunked-decoder can parse the byte stream. A
            // write failure (peer gone) means the client is dead;
            // remove it from the manager.
            if (writeChunkedFrame(client.fd, event)) {
                // success
            } else |_| {
                self.removeClient(client.id);
            }
        }
    }

    pub fn broadcastTyped(self: *SseManager, event_type: []const u8, data: []const u8) !void {
        const event = try std.fmt.allocPrint(self.allocator, "event: {s}\ndata: {s}\n\n", .{ event_type, data });
        defer self.allocator.free(event);

        self.lock.lock(self.io) catch unreachable;
        var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
        defer client_ptrs.deinit(self.allocator);

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
        }
        self.lock.unlock(self.io);

        for (client_ptrs.items) |client| {
            // Send the typed broadcast as a chunked frame so the
            // peer's HTTP/1.1 chunked-decoder can parse the byte
            // stream. A write failure (peer gone) means the client
            // is dead; remove it from the manager.
            if (writeChunkedFrame(client.fd, event)) {
                // success
            } else |_| {
                self.removeClient(client.id);
            }
        }
    }

    pub fn clientCount(self: *SseManager) usize {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);
        return self.clients.count();
    }

    /// Send `data` as one HTTP/1.1 chunked-transfer-encoding frame
    /// on the wire: `<hex length>\r\n<data>\r\n`. Returns
    /// `error.ClientDisconnected` if the peer hung up (peer socket
    /// closed) or the write itself failed.
    ///
    /// Allocates a small stack-buffer for the length header (16 bytes
    /// is enough for any 64-bit length).
    pub fn sendChunked(self: *SseManager, id: [16]u8, data: []const u8) !void {
        const client = self.clients.get(id) orelse return error.ClientNotFound;
        try writeChunkedFrame(client.fd, data);
    }

    /// Send the chunked-encoding terminator: `0\r\n\r\n`. Call this
    /// once on every SSE connection just before closing the socket,
    /// so that intermediaries (Vite, browser) can finalize their
    /// chunked decoding state cleanly. Failure is non-fatal — the
    /// socket close itself signals end-of-stream.
    pub fn sendTerminatingChunk(self: *SseManager, id: [16]u8) void {
        const client = self.clients.get(id) orelse return;
        // Failure is non-fatal — caller is about to close the fd anyway.
        _ = sendAll(client.fd, "0\r\n\r\n");
    }
};

/// Write one HTTP/1.1 chunked-transfer-encoding frame to `fd`:
/// `<hex length>\r\n<data>\r\n`. Returns `error.WriteFailed` if the
/// underlying send fails for any reason.
///
/// This is a free function so both `SseManager.sendChunked` (which
/// looks up the client by id) and `SseClient.sendEvent` (which
/// already has the fd and is inside its per-client lock) can call
/// it without duplicating the 3-write loop.
pub fn writeChunkedFrame(fd: i32, data: []const u8) !void {
    var len_buf: [16]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{x}\r\n", .{data.len}) catch
        return error.WriteFailed;
    const trailer = "\r\n";

    if (sendAll(fd, len_str) < len_str.len) return error.WriteFailed;
    if (sendAll(fd, data) < data.len) return error.WriteFailed;
    if (sendAll(fd, trailer) < trailer.len) return error.WriteFailed;
}

/// Write all of `data` to `fd`, looping on short writes. Returns
/// the number of bytes actually written, or -1 on error.
///
/// On Linux uses `sendto(fd, buf, len, MSG_NOSIGNAL, null, 0)` so a
/// peer-closed socket returns `EPIPE` instead of killing the process
/// with SIGPIPE. On non-Linux platforms falls back to
/// `posix.system.write` (macOS has SIGPIPE ignored by default in
/// many setups; Windows has no SIGPIPE at all).
fn sendAll(fd: i32, data: []const u8) isize {
    if (is_linux) {
        var sent: usize = 0;
        const flags: u32 = std.os.linux.MSG.NOSIGNAL;
        while (sent < data.len) {
            // sendto(fd, buf, len, flags, addr=null, alen=0) is
            // equivalent to send(2) on a connected socket — but
            // unlike send(2), sendto accepts flags so we can pass
            // MSG_NOSIGNAL to suppress SIGPIPE on peer close.
            const rc = std.os.linux.sendto(fd, data[sent..].ptr, data.len - sent, flags, null, 0);
            if (rc > std.math.maxInt(i32)) return -1;
            const n: isize = @intCast(rc);
            if (n < 0) return -1;
            if (n == 0) return -1;
            sent += @as(usize, @intCast(n));
        }
        return @intCast(sent);
    } else {
        // macOS / Windows / BSD: use posix.system.write. SIGPIPE
        // is a no-op on Windows (no signal) and on macOS the default
        // disposition varies; the SseClient-side `self.alive` flag
        // and the next `sendEvent` call will surface the disconnect.
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = posix.system.write(fd, data[sent..].ptr, data.len - sent);
            if (rc > std.math.maxInt(i32)) return -1;
            const n: isize = @intCast(rc);
            if (n < 0) return -1;
            if (n == 0) return -1;
            sent += @as(usize, @intCast(n));
        }
        return @intCast(sent);
    }
}

fn timestamp() u64 {
    var ts: socket.timespec = undefined;
    _ = socket.clock_gettime(socket.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1000000;
}
