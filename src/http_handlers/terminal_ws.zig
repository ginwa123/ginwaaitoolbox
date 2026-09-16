//! `WS /api/terminal/ws?id=<session-id>` — duplex PTY streaming.
//!
//! The session is still spawned via `POST /api/terminal/sessions`
//! (cwd/shell/size validation lives there); this socket only
//! ATTACHES to a live session id passed as `?id=`. Unknown id → the
//! handler returns immediately and the server runs the close
//! handshake (clean reject, no frames).
//!
//! Wire protocol (all client→server frames MUST be masked — browsers
//! always mask; unmasked frames are a protocol error):
//!
//!   C→S text   {"type":"input","data":"ls\n"}   — keystrokes
//!   C→S text   {"type":"resize","cols":100,"rows":40}
//!   S→C binary <raw PTY bytes>                  — terminal output
//!   S→C text   {"type":"exit","exit_code":0}    — shell ended (then close)
//!
//! Ping is answered with pong (RFC 6455 §5.5.3); binary C→S frames are
//! ignored; on attach the server flushes the currently buffered output
//! once, then streams only new bytes. The REST output endpoint stays
//! available as a fallback (frontend polls only when the socket fails).
//!
//! The handler runs on the connection's thread (kabelweb contract) and
//! multiplexes PTY + socket with a zero-alloc `poll()` loop — no extra
//! threads. Returning ends the socket; the SESSION survives (a new WS
//! can re-attach; `DELETE /api/terminal/sessions/:id` kills it).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const terminal_session = @import("terminal_session.zig");
const ws_frames = gserverz.ws_frames;

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

const POLLIN: c_short = 1;
extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout: c_int) c_int;

/// Max buffered client bytes before a complete frame must arrive.
/// Control frames are tiny (keystrokes, resize JSON); anything larger
/// is a protocol error and ends the socket.
const max_pending: usize = 64 * 1024;
/// PTY bytes forwarded per loop iteration (split into 16 KiB frames).
const max_forward_per_tick: usize = 64 * 1024;
const out_frame_chunk: usize = 16 * 1024;
/// Largest single WS payload we accept from the client (paste guard).
const max_client_payload: usize = 1024 * 1024;

pub const WsControl = struct {
    @"type": []const u8 = "",
    data: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

/// Wire length of the FIRST frame in `buf` (header + mask key +
/// payload). Client frames must be masked; unmasked → InvalidFrame.
/// Short buffer → IncompleteFrame. Absurd lengths → FrameTooLarge.
pub fn frameWireLen(buf: []const u8) !usize {
    if (buf.len < 2) return error.IncompleteFrame;
    const masked = (buf[1] & 0x80) != 0;
    if (!masked) return error.InvalidFrame;
    const len7: usize = buf[1] & 0x7F;
    var header: usize = 2;
    var payload: usize = 0;
    if (len7 < 126) {
        payload = len7;
    } else if (len7 == 126) {
        if (buf.len < 4) return error.IncompleteFrame;
        payload = (@as(usize, buf[2]) << 8) | buf[3];
        header = 4;
    } else {
        if (buf.len < 10) return error.IncompleteFrame;
        var len64: u64 = 0;
        for (buf[2..10]) |b| len64 = (len64 << 8) | b;
        if (len64 > max_client_payload) return error.FrameTooLarge;
        // usize is 64-bit on every target we serve WS on.
        payload = @intCast(len64);
        header = 10;
    }
    const total = header + 4 + payload; // +4 masking key
    if (buf.len < total) return error.IncompleteFrame;
    return total;
}

fn sendBinary(server: *gserverz.GinwaServer, allocator: std.mem.Allocator, fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const end = @min(off + out_frame_chunk, bytes.len);
        const wire = try ws_frames.encodeFrame(allocator, .{ .opcode = .binary, .payload = bytes[off..end] });
        defer allocator.free(wire);
        _ = try server.sendToClient(fd, wire);
        off = end;
    }
}

fn sendExit(server: *gserverz.GinwaServer, allocator: std.mem.Allocator, fd: i32, exit_code: ?i32) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .@"type" = "exit",
        .exit_code = exit_code,
    }, .{});
    defer allocator.free(body);
    const wire = try ws_frames.encodeFrame(allocator, .{ .opcode = .text, .payload = body });
    defer allocator.free(wire);
    _ = try server.sendToClient(fd, wire);
}

fn sendPong(server: *gserverz.GinwaServer, allocator: std.mem.Allocator, fd: i32, payload: []const u8) !void {
    const wire = try ws_frames.encodeFrame(allocator, .{ .opcode = .pong, .payload = payload });
    defer allocator.free(wire);
    _ = try server.sendToClient(fd, wire);
}

fn handleControl(
    server: *gserverz.GinwaServer,
    allocator: std.mem.Allocator,
    fd: i32,
    session: *terminal_session.Session,
    payload: []const u8,
) !bool {
    // Returns false when the socket should close (session exited).
    const parsed = std.json.parseFromSliceLeaky(WsControl, allocator, payload, .{}) catch return true;
    if (std.mem.eql(u8, parsed.@"type", "input")) {
        const data = parsed.data orelse return true;
        if (data.len == 0) return true;
        _ = terminal_session.writeInput(session, data) catch |err| {
            if (err == error.SessionExited) {
                const out = terminal_session.readOutput(session, std.math.maxInt(u64));
                try sendExit(server, allocator, fd, out.exit_code);
                return false;
            }
            return true; // transient write failure — keep the socket.
        };
        return true;
    }
    if (std.mem.eql(u8, parsed.@"type", "resize")) {
        const cols = parsed.cols orelse return true;
        const rows = parsed.rows orelse return true;
        terminal_session.resizeSession(session, cols, rows) catch {};
        return true;
    }
    return true; // unknown type — ignore, keep the socket.
}

pub fn terminalWsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    server_ptr: *anyopaque,
    client_fd: i32,
    client_id: *[16]u8,
) !void {
    _ = client_id;
    const server: *gserverz.GinwaServer = @ptrCast(@alignCast(server_ptr));
    const allocator = ctx.allocator;

    const id = req.query.get("id") orelse return;
    if (id.len == 0) return;
    const session = terminal_session.getSession(id) orelse return;

    // No PTY on this OS (Windows): close handshake runs on return.
    // NOTE: this MUST be an if/else on the comptime condition — a bare
    // `if (comptime !is_pty_os) return;` does NOT prune the code below
    // for codegen (verified: lld-link still sees `poll`), only the
    // untaken if/else branch is dropped. The raw `poll` extern is
    // absent from msvcrt, so any live reference breaks the Windows
    // build (CI run 35031625755).
    if (comptime terminal_session.is_pty_os) {
        return pumpPosix(server, allocator, client_fd, id, session);
    } else {
        return;
    }
}

/// Connection pump (POSIX only — see the comptime gate above).
fn pumpPosix(
    server: *gserverz.GinwaServer,
    allocator: std.mem.Allocator,
    client_fd: i32,
    id: []const u8,
    session: *terminal_session.Session,
) !void {
    // Attach flush: everything currently buffered, then stream.
    {
        const out = terminal_session.readOutput(session, 0);
        if (out.data.len > 0) {
            // Cap the attach burst (long-lived sessions may hold 256 KiB).
            const burst = out.data[0..@min(out.data.len, max_forward_per_tick)];
            sendBinary(server, allocator, client_fd, burst) catch return;
        }
        if (out.exited) {
            sendExit(server, allocator, client_fd, out.exit_code) catch {};
            return;
        }
    }
    var cursor = terminal_session.getSession(id).?.totalCursor();

    var net_buf: [8192]u8 = undefined;
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(allocator);

    while (true) {
        // Multiplex PTY + socket (100ms tick — no threads).
        var pfds = [_]PollFd{
            .{ .fd = session.masterFd(), .events = POLLIN, .revents = 0 },
            .{ .fd = client_fd, .events = POLLIN, .revents = 0 },
        };
        if (poll(&pfds, 2, 100) < 0) return;

        // PTY → socket.
        if (pfds[0].revents & POLLIN != 0) {
            const out = terminal_session.readOutput(session, cursor);
            cursor = out.cursor;
            if (out.data.len > 0) {
                const burst = out.data[0..@min(out.data.len, max_forward_per_tick)];
                sendBinary(server, allocator, client_fd, burst) catch return;
            }
            if (out.exited) {
                sendExit(server, allocator, client_fd, out.exit_code) catch {};
                return;
            }
        } else {
            // No PTY bytes, but the child may have exited silently.
            const out = terminal_session.readOutput(session, cursor);
            cursor = out.cursor;
            if (out.exited) {
                sendExit(server, allocator, client_fd, out.exit_code) catch {};
                return;
            }
        }

        // Socket → PTY.
        if (pfds[1].revents & POLLIN == 0) continue;
        const n = server.recvFromClient(client_fd, &net_buf) catch return;
        if (n == 0) return; // peer closed
        if (pending.items.len + n > max_pending) return;
        pending.appendSlice(allocator, net_buf[0..n]) catch return;

        // Handle every complete frame in the buffer.
        while (pending.items.len > 0) {
            const wire_len = frameWireLen(pending.items) catch |err| {
                if (err == error.IncompleteFrame) break;
                return; // InvalidFrame / FrameTooLarge — protocol error.
            };
            var frame = ws_frames.parseFrame(allocator, pending.items[0..wire_len]) catch return;
            defer frame.deinit(allocator);

            switch (frame.opcode) {
                .text => {
                    const keep = handleControl(server, allocator, client_fd, session, frame.payload) catch return;
                    if (!keep) return;
                },
                .binary => {}, // binary C→S is ignored (input goes via JSON).
                .ping => sendPong(server, allocator, client_fd, frame.payload) catch return,
                .close => return,
                else => {},
            }

            // Shift the consumed frame off the buffer.
            const rest = pending.items.len - wire_len;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[wire_len..]);
            pending.items.len = rest;
        }
    }
}

// ---------------------------------------------------------------------
// Inline tests (framing + control parsing; the live socket is covered
// by the functional WS harness test).
// ---------------------------------------------------------------------

const testing = std.testing;

fn maskedTextFrame(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    // Minimal masked client frame (FIN + text, len < 126).
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 0x81);
    try out.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try out.appendSlice(allocator, &mask);
    for (payload, 0..) |b, i| try out.append(allocator, b ^ mask[i % 4]);
    return out.toOwnedSlice(allocator);
}

test "frameWireLen measures a masked text frame" {
    const wire = try maskedTextFrame(testing.allocator, "hi");
    defer testing.allocator.free(wire);
    try testing.expectEqual(wire.len, try frameWireLen(wire));
}

test "frameWireLen handles 16-bit extended length" {
    var payload: [300]u8 = undefined;
    @memset(&payload, 'A');
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, 0x82); // FIN + binary
    try out.append(testing.allocator, 0x80 | 126);
    try out.append(testing.allocator, 0x01); // 300 >> 8
    try out.append(testing.allocator, 0x2C); // 300 & 0xFF
    try out.appendSlice(testing.allocator, &[_]u8{ 1, 2, 3, 4 }); // mask
    try out.appendSlice(testing.allocator, &payload);
    try testing.expectEqual(out.items.len, try frameWireLen(out.items));
}

test "frameWireLen reports IncompleteFrame on short buffers" {
    try testing.expectError(error.IncompleteFrame, frameWireLen(&[_]u8{}));
    try testing.expectError(error.IncompleteFrame, frameWireLen(&[_]u8{0x81}));
    const wire = try maskedTextFrame(testing.allocator, "hello");
    defer testing.allocator.free(wire);
    try testing.expectError(error.IncompleteFrame, frameWireLen(wire[0 .. wire.len - 1]));
}

test "frameWireLen rejects unmasked frames" {
    // Server→client style frame (no mask bit) must never arrive C→S.
    try testing.expectError(error.InvalidFrame, frameWireLen(&[_]u8{ 0x81, 0x02, 'h', 'i' }));
}

test "control JSON parses input and resize shapes" {
    var input = try std.json.parseFromSlice(WsControl, testing.allocator, "{\"type\":\"input\",\"data\":\"ls\\n\"}", .{});
    defer input.deinit();
    try testing.expectEqualStrings("input", input.value.@"type");
    try testing.expectEqualStrings("ls\n", input.value.data.?);

    var resize = try std.json.parseFromSlice(WsControl, testing.allocator, "{\"type\":\"resize\",\"cols\":100,\"rows\":40}", .{});
    defer resize.deinit();
    try testing.expectEqualStrings("resize", resize.value.@"type");
    try testing.expectEqual(@as(u16, 100), resize.value.cols.?);
}
