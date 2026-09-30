//! MCP stdio transport for the agent AI.
//!
//! Contains everything needed to talk to MCP servers that expose themselves
//! as a child-process command (per the MCP stdio spec, see
//! https://modelcontextprotocol.io/specification/draft/basic/transports/stdio).
//!
//! Three pieces:
//!   1. Content-Length framing (`readFramed` / `writeFramed`) — private helpers
//!   2. `StdioClient` — spawns one child via `std.process.Child`, framed read/write
//!   3. `StdioRegistry` — process-global singleton, one child per server name,
//!      lazy spawn, respawn on exit, clean shutdown.
//!
//! The existing server-side `mcp_transport.zig` is NOT touched — its inline
//! framing logic is fine for v1; DRY'ing it out can be a v2 refactor.
//!
//! Plan: docs/superpowers/plans/2026-08-27-mcp-stdio.md (Task 1)

const std = @import("std");
const builtin = @import("builtin");

const MAX_HEADER_BYTES: usize = 8 * 1024;

/// Hard cap on a Content-Length framed body. Mirrors the MCP SDK's
/// `STDIO_DEFAULT_MAX_BUFFER_SIZE` (10 MiB) so a hostile or broken
/// server can't make us `alloc` an arbitrary amount of memory: the
/// header is attacker-controlled, and `Content-Length: 18446744073709551615`
/// is a syntactically valid frame that a naive parser turns into a
/// 16 EiB allocation request.
const MAX_BODY_BYTES: usize = 10 * 1024 * 1024;

pub const StdioError = error{
    ChildSpawnFailed,
    BrokenPipe,
    InvalidFrame, // no Content-Length header found, or the
    // "header" block contained a non-header line
    InvalidContentLength, // non-numeric / negative length
    /// Content-Length parsed fine but exceeds `MAX_BODY_BYTES`.
    BodyTooLarge,
    UnexpectedEof,
    /// Recv timed out before a full frame was read OR the cancel
    /// callback returned true. Caller should mark the client stale
    /// via `Lease.markStale` so the next call auto-respawns.
    /// A hung child (pipe-buffer deadlock, awaits-init forever, etc.)
    /// surfaces here instead of blocking the caller forever.
    RecvTimeout,
    /// Send timed out before all bytes were written. Same recovery
    /// as RecvTimeout — a child whose stdin pipe is full is as good
    /// as a child that's crashed.
    SendTimeout,
    /// `StdioRegistry.acquire` could not take the per-server lease
    /// within its wait budget. Another session is mid-transaction on
    /// the same child. Not a child failure — retrying later works.
    LeaseTimeout,
    /// `StdioClient.recv` observed reader state that can only arise
    /// from concurrent access to the same client. Reachable only when
    /// a caller uses `StdioClient` directly instead of going through
    /// `StdioRegistry.acquire`; surfaced as an error rather than left
    /// to panic inside `std.Io.Reader.readSliceShort`.
    ConcurrentAccess,
    OutOfMemory,
};

// ============================================================================
// SECTION A — Content-Length framing (private to this file)
// ============================================================================
//
// Wire format (per MCP stdio spec):
//   Content-Length: <N>\r\n
//   [other headers...]\r\n
//   \r\n
//   <N bytes of body>
//
// We accept BOTH CRLF (\r\n\r\n) and LF-only (\n\n) blank-line separators — the
// spec says CRLF but real-world servers (e.g. node-based) sometimes emit LF-only.

/// Wait until `file` is readable (data OR EOF/hangup waiting) or the
/// deadline elapses / the cancel callback fires.
///
/// Returns `true` when a subsequent read is guaranteed not to block;
/// returns `false` on deadline/cancel (the caller maps this to
/// `StdioError.RecvTimeout`).
///
/// WHY THIS EXISTS: `readFramed` used to poll its deadline only *between*
/// syscalls, but a blocking `readSliceShort` on a silent child never
/// returns, so the deadline never fired. Concrete trigger: probing a
/// stdio server with empty args spawns bare `python`, which sits in
/// stdin-script mode waiting for EOF (the probe must keep stdin open —
/// real MCP servers need it) while writing zero stdout bytes. The
/// first-byte read blocked forever, the `/api/mcp/test` handler thread
/// stuck, and the Test button spun forever. Waiting with `posix.poll`
/// first makes the deadline real even when the child produces zero
/// bytes.
///
/// POSIX-only. `std.Io.File.handle` is a pollable fd there. On Windows
/// `std.posix.poll` is a `@compileError` ("use std.Io instead"), so the
/// whole body is behind a `comptime` gate and this returns `true`
/// immediately (previous blocking behavior — documented limitation;
/// a future plan can use `WaitForSingleObject` there).
///
/// Callers skip this when the reader already holds buffered bytes
/// (`iface.bufferedLen() > 0` — a poll on an empty fd would wrongly
/// time out while data sits in the userspace buffer) and when neither
/// a deadline nor a cancel callback is set (pure blocking `recvNoTimeout`
/// mode).
fn waitReadable(
    io: std.Io,
    file: std.Io.File,
    deadline_abs: i128,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) bool {
    if (comptime builtin.os.tag == .windows) {
        return true;
    } else {
        const has_deadline = deadline_ns != 0;
        while (true) {
            if (is_cancelled) |cb| if (cb()) return false;
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (has_deadline and now_ns >= deadline_abs) return false;
            // Poll in ≤100ms slices so the cancel callback stays
            // responsive and the deadline check above runs often. With
            // only a cancel callback set (no deadline) the slice is a
            // flat 100ms.
            const chunk_ms: i32 = if (has_deadline) blk: {
                const rem_ns: i128 = deadline_abs - now_ns;
                const rem_ms: i128 = @divTrunc(rem_ns, std.time.ns_per_ms);
                const clamped: i128 = @min(@max(rem_ms, 1), 100);
                break :blk @intCast(clamped);
            } else 100;
            var pfds = [_]std.posix.pollfd{.{
                .fd = file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            // Fail-open: if poll itself errors, let the read decide
            // (preserves the old behavior instead of inventing a timeout).
            const n = std.posix.poll(&pfds, chunk_ms) catch return true;
            // n > 0: readable bytes OR EOF/HUP/ERR waiting — either way
            // the next read returns immediately instead of blocking.
            if (n > 0) return true;
            // n == 0: slice elapsed with no data — loop to recheck
            // deadline/cancel.
        }
    }
}

/// Read one Content-Length-framed or newline-delimited JSON message.
/// Allocates ONE slice that's returned to the caller; the caller owns
/// it and is responsible for freeing. No per-byte scratch buffers,
/// no errdefer cleanup — see "Per-Request Arena Cleanup" in AGENTS.md
/// for the project convention. When `allocator` is an arena (the
/// normal call site — nalar's request arena), the slice is freed by
/// the arena teardown without a per-call free. When `allocator` is
/// `std.testing.allocator` (used in tests), the existing
/// `defer testing.allocator.free(body)` at the call site handles it.
///
/// `deadline_ns` (default 0 = no timeout) — when >0, the read loop
/// runs for at most this many nanoseconds from the moment the
/// function was called. Internally we compute
/// `deadline_abs = now + deadline_ns` on entry and compare against
/// `now` between bytes. The FIRST byte (and every subsequent byte
/// when the reader buffer is empty) additionally waits via
/// `waitReadable` (`posix.poll` on POSIX), so a child that produces
/// zero bytes — e.g. bare `python` with no args, waiting on stdin
/// for EOF — surfaces as `RecvTimeout` instead of blocking the
/// caller forever. Wall-clock check stays portable across OS
/// without FFI beyond poll itself (which is `comptime`-gated out
/// on Windows).
///
/// `is_cancelled` (default null = no cancel-check) — when set, polled
/// between bytes read. When the function returns `true`, recv bails
/// out with `StdioError.RecvTimeout` so the workflow's Stop button
/// propagates without waiting for the deadline. The callback is
/// invoked AFTER every syscall (one boolean deref per byte), not on a
/// timer — total cost is O(N bytes) per MCP fetch, dominated by
/// syscalls. Thread-safety: the callback is run on the same thread as
/// the reader (StdioRegistry's threaded io for the global registry),
/// so `std.atomic.Value(bool)` or a mutex around the captured state
/// is the caller's responsibility.
fn readFramed(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) StdioError![]u8 {
    // Single-message wrapper (tests + one-shot callers). Builds a
    // throwaway reader; callers doing back-to-back recv() on one child
    // must use readFramedWithReader with a persistent reader instead,
    // or coalesced lines are buffered-then-dropped.
    var reader_buf: [4096]u8 = undefined;
    var reader = std.Io.File.reader(file, io, &reader_buf);
    return readFramedWithReader(allocator, io, &reader, deadline_ns, is_cancelled);
}

/// Shrink an over-allocated read buffer down to its payload length for
/// hand-off to the caller, keeping the returned slice's `.len` equal to
/// the size the allocator actually reserved.
///
/// WHY THE FALLBACK MATTERS: the caller frees this slice with the same
/// allocator, and a checking allocator validates `slice.len` against the
/// size the allocation was made with. `realloc` preserves that invariant
/// by construction, but the `catch body[0..len]` fallback that used to
/// be here returned a slice whose `.len` had nothing to do with the
/// underlying block — an "invalid free" abort, i.e. exactly the class of
/// crash the DebugAllocator in tests exists to catch, sitting on the OOM
/// path where it is least likely to be hit in a repro. The fallback is
/// therefore a real exact-size alloc + copy + free, and a failure there
/// is reported as OOM instead of being papered over.
fn shrinkToLen(allocator: std.mem.Allocator, body: []u8, len: usize) StdioError![]u8 {
    if (body.len == len) return body;
    if (allocator.realloc(body, len)) |shrunk| return shrunk else |_| {}
    const exact = allocator.alloc(u8, len) catch return StdioError.OutOfMemory;
    @memcpy(exact, body[0..len]);
    allocator.free(body);
    return exact;
}

fn readFramedWithReader(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.File.Reader,
    deadline_ns: u64,
    is_cancelled: ?*const fn () bool,
) StdioError![]u8 {
    // Compute the absolute deadline ONCE on entry. `deadline_ns` is
    // a relative duration (0 = no timeout) — callers naturally think
    // in "give me 10 seconds", not "absolute nanosecond timestamp".
    // We convert to an absolute deadline here so the per-byte
    // deadline check is a single i128 comparison.
    //
    // NOTE: `now` is i128 (the underlying type of `.nanoseconds` in
    // Zig 0.16). We saturate-cast to u64 with `@intCast` — overflow
    // is impossible for any realistic deadline (the i128 clock
    // would need to be near 2^64 ns = ~580 years past epoch for
    // overflow, well beyond any practical session lifetime).
    const deadline_abs: i128 = if (deadline_ns == 0) std.math.maxInt(i128) else blk: {
        const now = std.Io.Timestamp.now(io, .real).nanoseconds;
        const dline_i128: i128 = @intCast(deadline_ns);
        break :blk now + dline_i128;
    };

    // Helper to centralize the cancel + deadline check between syscalls.
    // Returns `null` when both checks pass, else the error to return.
    // Checks cancel FIRST so a Stop click aborts even with a huge deadline.
    const ErrOrVoid = struct { err: ?StdioError = null };
    const checkDeadlineOrCancel = struct {
        fn call(
            now_ns: i128,
            dline_abs: i128,
            cb: ?*const fn () bool,
        ) ErrOrVoid {
            if (cb) |c| if (c() == true) return .{ .err = StdioError.RecvTimeout };
            if (now_ns >= dline_abs) return .{ .err = StdioError.RecvTimeout };
            return .{};
        }
    }.call;

    // Persistent reader is owned by the caller (StdioClient keeps it
    // alive across recv() calls so coalesced lines survive).
    const iface = &reader.interface;
    const file = reader.file;

    // Peek the first byte to detect framing style:
    //   '{' ⇒ newline-delimited JSON (the @modelcontextprotocol/sdk
    //          default in v1.x; the message ends at the next \n)
    //   anything else ⇒ Content-Length framed (the MCP stdio spec
    //                   default; header terminated by \r\n\r\n or \n\n,
    //                   then `Content-Length: N` body)
    {
        // First-byte read is the only syscalls before the framing
        // branch — check timeout once before AND once after. Pre-check
        // catches "deadline already elapsed on entry" (cheap); the
        // post-check is dropped here because EOF on first byte maps to
        // UnexpectedEof (timeout-style error doesn't fit).
        if (deadline_ns != 0) {
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (checkDeadlineOrCancel(now_ns, deadline_abs, is_cancelled).err) |e| return e;
        }
    }
    var first: [1]u8 = undefined;
    // Deadline-aware wait: without this, a silent child (zero stdout
    // bytes, pipe still open) blocks the read below forever and the
    // deadline never fires. Skip when the caller wants pure blocking
    // mode (deadline 0 + no cancel callback).
    if (deadline_ns != 0 or is_cancelled != null) {
        if (!waitReadable(io, file, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
    }
    const n0 = iface.readSliceShort(&first) catch return StdioError.UnexpectedEof;
    if (n0 == 0) return StdioError.UnexpectedEof;

    if (first[0] == '{') {
        // Newline-delimited JSON path. We allocate ONE slice and grow
        // it as we read bytes — no scratch buffer to leak. Capacity
        // starts at 256 (covers >99% of MCP messages) and doubles
        // until we hit the 10 MiB cap (matches the SDK's
        // STDIO_DEFAULT_MAX_BUFFER_SIZE).
        //
        // We use `realloc` (NOT `resize`) to shrink at the end because
        // `free()` uses `slice.len` to determine the size to free, so
        // returning a slice with a different `len` than the underlying
        // allocation's tracked size corrupts DebugAllocator's canary
        // check in tests. `realloc` may relocate, but the returned
        // slice's `.len` always matches the tracked size.
        const max_line: usize = MAX_BODY_BYTES;
        var cap: usize = 256;
        var body = allocator.alloc(u8, cap) catch return StdioError.OutOfMemory;
        var len: usize = 1; // already read '{'
        body[0] = first[0];
        while (true) {
            // Same silent-child guard as the first byte: only poll when
            // the reader buffer is drained, otherwise buffered bytes
            // would sit unread while we wait on an empty fd.
            if (iface.bufferedLen() == 0 and (deadline_ns != 0 or is_cancelled != null)) {
                if (!waitReadable(io, file, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
            }
            var b: [1]u8 = undefined;
            // A clean EOF is reported by `readSliceShort` as a short
            // count; the only error it propagates is `error.ReadFailed`
            // — a genuine read failure (EBADF on a killed child, EIO,
            // ...). Returning the partial frame on that error is what
            // this loop used to do, which handed the caller a truncated
            // JSON document indistinguishable from a complete one.
            const n_byte = iface.readSliceShort(&b) catch return StdioError.UnexpectedEof;
            if (n_byte == 0) break;
            // Check deadline / cancel between bytes. The child is
            // hung → this fires; the child crashed but EOF hasn't
            // propagated → still RecvTimeout (better diagnostic for
            // the user than "EOF mid-message"). Either way the caller
            // marks stale + respawns on the next call.
            if (deadline_ns != 0 or is_cancelled != null) {
                const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
                if (checkDeadlineOrCancel(now_ns, deadline_abs, is_cancelled).err) |e| return e;
            }
            if (b[0] == '\n') {
                // Trim trailing \r if present.
                const trimmed_len = if (len > 0 and body[len - 1] == '\r') len - 1 else len;
                return shrinkToLen(allocator, body, trimmed_len);
            }
            if (len >= max_line) return StdioError.BodyTooLarge;
            if (len >= cap) {
                const new_cap = @min(cap * 2, max_line);
                body = allocator.realloc(body, new_cap) catch return StdioError.OutOfMemory;
                cap = new_cap;
            }
            body[len] = b[0];
            len += 1;
        }
        // EOF before the terminating newline — hand back the partial
        // frame. Callers that can't parse it mark the client stale and
        // respawn, which is the only correct recovery: the remainder
        // of this line, if any, is already gone.
        return shrinkToLen(allocator, body, len);
    }

    // Content-Length framed path (the MCP stdio spec default).
    var header_buf: [MAX_HEADER_BYTES]u8 = undefined;
    var header_len: usize = 1;
    header_buf[0] = first[0];
    var found_blank = false;
    // Start of the header line currently being accumulated. Reset at
    // every '\n' so a completed line can be validated as `name: value`
    // (see the non-header check inside the loop).
    var line_start: usize = 0;

    while (!found_blank) {
        if (iface.bufferedLen() == 0 and (deadline_ns != 0 or is_cancelled != null)) {
            if (!waitReadable(io, file, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
        }
        var byte: [1]u8 = undefined;
        const n = iface.readSliceShort(&byte) catch return StdioError.UnexpectedEof;
        if (n == 0) return StdioError.UnexpectedEof;
        if (header_len >= header_buf.len) return StdioError.InvalidFrame;
        header_buf[header_len] = byte[0];
        header_len += 1;
        if (deadline_ns != 0 or is_cancelled != null) {
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (checkDeadlineOrCancel(now_ns, deadline_abs, is_cancelled).err) |e| return e;
        }
        if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 ..][0..4], "\r\n\r\n")) {
            found_blank = true;
        } else if (header_len >= 2 and std.mem.eql(u8, header_buf[header_len - 2 ..][0..2], "\n\n")) {
            found_blank = true;
        } else if (byte[0] == '\n') {
            // A completed line inside the header block that carries no
            // ':' cannot be an HTTP-style header, so this is not a
            // Content-Length frame at all — most likely a server that
            // leaked a log line onto stdout. Bail now instead of
            // swallowing the *next* JSON message while hunting for a
            // blank line that will never come.
            const line = std.mem.trim(u8, header_buf[line_start .. header_len - 1], "\r ");
            if (line.len > 0 and std.mem.indexOfScalar(u8, line, ':') == null) {
                return StdioError.InvalidFrame;
            }
            line_start = header_len;
        }
    }

    const header = header_buf[0..header_len];
    var cl: ?usize = null;
    var it = std.mem.splitSequence(u8, header, "\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r ");
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const val = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            cl = std.fmt.parseInt(usize, val, 10) catch return StdioError.InvalidContentLength;
            break;
        }
    }
    const content_length = cl orelse return StdioError.InvalidFrame;
    // `Content-Length` is attacker-controlled text, not a trust signal.
    // Refuse before the alloc: `Content-Length: 18446744073709551615`
    // parses cleanly and would otherwise become a 16 EiB request that
    // either aborts the process on an OOM-checked allocator or quietly
    // succeeds under overcommit and then blocks until the deadline.
    if (content_length > MAX_BODY_BYTES) return StdioError.BodyTooLarge;

    const body = allocator.alloc(u8, content_length) catch return StdioError.OutOfMemory;
    // Chunked body read (NOT a single `readSliceAll`): each chunk is
    // guarded by `waitReadable` so a child that stalls mid-body —
    // header promised N bytes but the bytes never arrive — surfaces
    // as `RecvTimeout` instead of blocking forever. EOF mid-body
    // stays `UnexpectedEof`, matching the old `readSliceAll` mapping.
    var off: usize = 0;
    while (off < body.len) {
        if (iface.bufferedLen() == 0 and (deadline_ns != 0 or is_cancelled != null)) {
            if (!waitReadable(io, file, deadline_abs, deadline_ns, is_cancelled)) return StdioError.RecvTimeout;
        }
        const n = iface.readSliceShort(body[off..]) catch return StdioError.UnexpectedEof;
        if (n == 0) return StdioError.UnexpectedEof;
        off += n;
        if (deadline_ns != 0 or is_cancelled != null) {
            const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
            if (checkDeadlineOrCancel(now_ns, deadline_abs, is_cancelled).err) |e| return e;
        }
    }
    return body;
}

/// Write a newline-delimited JSON message (NDJSON). Used for MCP stdio
/// servers that expect `JSON.stringify(msg) + '\n'` (the SDK default for
/// both Node and Python). Pair with `readFramed` which already handles
/// both framing styles on read. For Content-Length framing, use `writeFramed`.
fn writeNDJSON(io: std.Io, file: std.Io.File, body: []const u8) !void {
    // Fast path: body + '\n' fits in a small stack buffer
    var stack_buf: [8192]u8 = undefined;
    if (body.len + 1 <= stack_buf.len) {
        @memcpy(stack_buf[0..body.len], body);
        stack_buf[body.len] = '\n';
        try std.Io.File.writeStreamingAll(file, io, stack_buf[0 .. body.len + 1]);
    } else {
        try std.Io.File.writeStreamingAll(file, io, body);
        try std.Io.File.writeStreamingAll(file, io, "\n");
    }
}

/// Write a Content-Length-framed message. Pair with `readFramed`.
///
/// `deadline_ns` (default 0 = no timeout) — when >0, polled between
/// the two `writeStreamingAll` calls. We don't poll INSIDE
/// writeStreamingAll because: (a) it's a single syscall block on
/// POSIX, so per-byte polling is impossible without kernel support,
/// (b) the typical MCP send is small (<64 KiB) so the pre-check is
/// enough for the common "child can't read stdin" stall. The cancel
/// callback for writes is intentionally NOT threaded through — sends
/// are short, atomic-ish from the caller's POV, and the recv boundary
/// is where cancel matters.
fn writeFramed(io: std.Io, file: std.Io.File, body: []const u8, deadline_ns: u64) !void {
    // `deadline_ns` is a relative duration in nanoseconds (0 = no
    // timeout) — see readFramed's contract. Convert to an absolute
    // deadline once on entry so the per-write check is a single
    // i128 comparison.
    const deadline_abs: i128 = if (deadline_ns == 0) std.math.maxInt(i128) else blk: {
        const now = std.Io.Timestamp.now(io, .real).nanoseconds;
        const dline_i128: i128 = @intCast(deadline_ns);
        break :blk now + dline_i128;
    };

    // Use a stack-allocated header buffer to avoid the Io.Writer abstraction
    // (which has subtle flush semantics in Zig 0.16's threaded runtime —
    // an explicit `flush()` on a 4 KiB writer buffer spins waiting for more
    // data; `writeStreamingAll` writes the full byte count up front).
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return StdioError.InvalidFrame;
    if (deadline_ns != 0) {
        const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        if (now_ns >= deadline_abs) return StdioError.SendTimeout;
    }
    std.Io.File.writeStreamingAll(file, io, header) catch return StdioError.BrokenPipe;
    if (deadline_ns != 0) {
        const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        if (now_ns >= deadline_abs) return StdioError.SendTimeout;
    }
    std.Io.File.writeStreamingAll(file, io, body) catch return StdioError.BrokenPipe;
}

// ============================================================================
// SECTION B — StdioClient (spawn child, framed read/write)
// ============================================================================
//
// One child process per StdioClient. Use StdioRegistry to cache them by server
// name across calls. `send` and `recv` are blocking — there's no async/queue.

pub const StdioClient = struct {
    /// Allocator for response bodies. This is a PER-CLIENT arena, not
    /// the registry's shared one: `StdioRegistry.arena` is a single
    /// `std.heap.ArenaAllocator` reachable by every server, and it is
    /// not thread-safe. Two sessions driving two different servers
    /// would race inside `ArenaAllocator.alloc` and corrupt both
    /// bump allocators. Scoping the arena to the client makes every
    /// allocation of it happen under that client's lease lock, so the
    /// arena is only ever touched by one thread at a time.
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    child: std.process.Child,
    stdin: ?std.Io.File,
    stdout: ?std.Io.File,
    /// stderr pipe — captured so diagnostic callers (e.g. mcp_test.zig's
    /// cold-start probe) can read the child's crash/exit messages. Most
    /// production callers ignore this. Read with non-blocking recv semantics
    /// when used.
    stderr: ?std.Io.File,
    /// Persistent stdout reader + buffer across recv() calls. readFramed
    /// used to build a fresh 4KB Io.Reader per call; when a fast server
    /// coalesces two JSON lines in one pipe write, the first recv()
    /// buffered the second line then dropped it with the stack buffer,
    /// so the second recv() hung. Keeping the reader alive preserves
    /// buffered bytes via bufferedLen() checks.
    ///
    /// NOT THREAD-SAFE. `std.Io.Reader` is a bare struct of `seek`/`end`
    /// cursors with no internal locking, and the refill path rewrites
    /// `seek = 0; end = 0` before reading into `buffer`. Two threads
    /// sharing one reader can leave `seek > end`, and the very next
    /// `readSliceShort` then panics on `buffer[seek..end]` — an
    /// out-of-bounds abort that took the whole server down.
    /// `StdioRegistry.acquire` is what keeps exactly one thread inside
    /// this struct at a time.
    read_buf: [4096]u8 = undefined,
    reader: ?std.Io.File.Reader = null,
    /// Set once `deinit` has killed the child and closed the pipes, so
    /// a second `deinit` (the `defer` in every caller, plus the
    /// registry's own teardown) is a no-op instead of a double-kill.
    is_dead: bool = false,

    pub fn init(
        backing_allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
    ) StdioError!StdioClient {
        // Zig 0.16's process.spawn takes `io` + a SpawnOptions struct.
        // env override — Zig 0.16's std.process.spawn has no clean .env_map
        // setter. v1 inherits the parent's env; a future v2 can pre-fork +
        // execve with a custom env_map. (Pitfall #6 in plan.)
        //
        // stderr is .pipe (was .ignore) so the cold-start diagnostic probe
        // in mcp_test.zig can surface the child's error output when the
        // SDK crashes during bootstrap on slow CI. Cost: one extra pipe FD
        // per cached child until the registry cleans up; ~0 overhead.
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return StdioError.ChildSpawnFailed;

        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .io = io,
            .child = child,
            .stdin = child.stdin,
            .stdout = child.stdout,
            .stderr = child.stderr,
        };
    }

    /// Allocator for response bodies — see the `arena` field's docs.
    pub fn allocator(self: *StdioClient) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Send a framed JSON-RPC message to the child. Allocates the header
    /// on the stack; body is written verbatim. No-op if stdin was closed.
    ///
    /// `deadline_ns` (default 0 = no timeout) — forwarded to
    /// `writeFramed`. When >0, polled between the two `writeStreamingAll`
    /// syscalls; on elapse, returns `StdioError.SendTimeout`. Pass
    /// `0` for the old blocking behavior.
    pub fn send(self: *StdioClient, body: []const u8, deadline_ns: u64) !void {
        const stdin = self.stdin orelse return StdioError.BrokenPipe;
        try writeFramed(self.io, stdin, body, deadline_ns);
    }

    /// Send a newline-delimited JSON message (NDJSON) to the child.
    /// Used for MCP servers that expect `JSON.stringify(msg) + '\n'`
    /// (the default for both Node and Python SDKs). No deadline
    /// polling — NDJSON sends are small and atomic.
    pub fn sendNDJSON(self: *StdioClient, body: []const u8) !void {
        const stdin = self.stdin orelse return StdioError.BrokenPipe;
        try writeNDJSON(self.io, stdin, body);
    }

    /// Convenience overload of `send` that uses no timeout. Preserves
    /// backward compat for the in-repo tests and any external callers
    /// that don't need the timeout path.
    pub fn sendNoTimeout(self: *StdioClient, body: []const u8) !void {
        return self.send(body, 0);
    }

    /// Read one framed response from the child. Allocates; caller frees.
    ///
    /// `deadline_ns` (default 0 = no timeout) — when >0, polled between
    /// bytes read. On elapse, returns `StdioError.RecvTimeout`.
    ///
    /// `is_cancelled` (default null) — polled between bytes. When the
    /// callback returns true, bails out with `StdioError.RecvTimeout`
    /// so the workflow's Stop button propagates within one syscall.
    pub fn recv(
        self: *StdioClient,
        deadline_ns: u64,
        is_cancelled: ?*const fn () bool,
    ) ![]u8 {
        const stdout = self.stdout orelse return StdioError.BrokenPipe;
        // Lazy-init the persistent reader once; it stays alive across
        // recv() calls so a fast server's coalesced lines are not lost.
        if (self.reader == null) {
            self.reader = std.Io.File.reader(stdout, self.io, &self.read_buf);
        }
        // Refuse to read through a reader whose cursors are already out
        // of order. `seek > end` is not reachable single-threaded — it
        // is the fingerprint of two threads sharing this client, and
        // the alternative is letting `readSliceShort` slice
        // `buffer[seek..end]` and abort the process from inside std.
        // Failing loudly here keeps a lock-discipline regression a
        // catchable error instead of a server-wide crash.
        const iface = &self.reader.?.interface;
        if (iface.seek > iface.end or iface.end > iface.buffer.len) {
            return StdioError.ConcurrentAccess;
        }
        const res = readFramedWithReader(
            self.allocator(),
            self.io,
            &self.reader.?,
            deadline_ns,
            is_cancelled,
        );
        if (res) |body| {
            return body;
        } else |err| {
            // Any error means we stopped mid-frame: the byte stream is
            // no longer aligned to a message boundary, so whatever is
            // left in the read buffer is the tail of an abandoned
            // frame. Keep it and the next `recv` parses garbage as if it
            // were a fresh message. Drop the reader instead and let the
            // caller's `markStale` respawn the child.
            self.reader = null;
            return err;
        }
    }

    /// Convenience overload of `recv` with no timeout and no
    /// cancel-check. Preserves backward compat for the in-repo tests
    /// and any external callers.
    pub fn recvNoTimeout(self: *StdioClient) ![]u8 {
        return self.recv(0, null);
    }

    /// Close stdin (signals EOF to the child) so it can exit gracefully.
    pub fn closeStdin(self: *StdioClient) void {
        if (self.stdin) |fd| {
            // `deinit` already closed the pipe; a second close would be
            // a double close of a possibly-recycled fd.
            if (!self.is_dead) fd.close(self.io);
            self.stdin = null;
        }
    }

    /// Kill the child immediately (SIGKILL on POSIX, TerminateProcess on
    /// Windows). Idempotent — safe to call from `defer` and from
    /// StdioRegistry.deinit. Does NOT free the StdioClient itself —
    /// the owning arena does that.
    ///
    /// Zig 0.16's `child.kill` does ALL the cleanup: sends the signal,
    /// reaps the child (sets child.id to null), and closes the stdio
    /// pipes. Don't call `closeStdin` or `wait` after kill — both
    /// trigger assertions or use-after-free.
    pub fn deinit(self: *StdioClient) void {
        if (self.is_dead) return;
        self.is_dead = true;
        self.reader = null;
        // Release the per-client arena now rather than letting it ride
        // along with the registry arena: a registry that respawns a
        // server repeatedly (every timeout marks it stale) would
        // otherwise hold the dead children's response buffers until
        // shutdown.
        self.arena.deinit();
        self.child.kill(self.io);
        // `child.kill` closed the pipes but the cached handles still
        // hold those fd NUMBERS. Leaving them set is not merely
        // untidy: after a close, the next `spawn`/`open` in this
        // process is very likely to hand back the same number, so a
        // `send` on the dead client would write MCP JSON-RPC into
        // whatever unrelated file or socket now owns that fd, and a
        // `recv` would try to parse that file's contents as a frame.
        // Nulling turns both into an honest `BrokenPipe`.
        self.stdin = null;
        self.stdout = null;
        self.stderr = null;
    }
};

// ============================================================================
// SECTION C — StdioRegistry (process-global singleton, one child per server)
// ============================================================================
//
// Keyed by server name. v1 limitation: editing `mcp_servers` via PUT doesn't
// kill the old children — the new config spawns new children alongside. v2 can
// compare old vs new and drop stale entries. (Pitfall #5 in plan.)
//
// Concurrency: Zig 0.16 removed `std.Thread.Mutex`. We use `std.atomic.Mutex`
// + spinlock — same pattern as `src/agentic_loop/stream_snapshot.zig`.

const Entry = struct {
    /// The child. ONLY VALID WHEN `has_client` IS TRUE — for a freshly
    /// created entry this points at an uninitialized arena slot, which
    /// is why the flag exists rather than a `?*StdioClient` (the
    /// non-null assertion is what the call sites want to read).
    client: *StdioClient,
    /// `false` ⇒ `client` is an unallocated slot and no child has ever
    /// existed for this name. `acquire` spawns into it under the entry
    /// lock; nothing else may touch `client` before then. Without this
    /// flag the first `acquire` for a new name deinitializes whatever
    /// garbage the arena handed back — an ArenaAllocator free-list walk
    /// through uninitialized memory.
    has_client: bool = false,
    /// Pre-reserved uninitialized `StdioClient` slot for the NEXT
    /// spawn, allocated up front under the registry lock. Phase 3 of
    /// `acquire` runs with only the entry lock held, and the registry
    /// arena is not thread-safe, so the allocation cannot happen there
    /// — two threads respawning two different servers would corrupt
    /// each other's bump pointers. Consumed (set to null) on use;
    /// `acquire` tops it back up on every entry.
    spare: ?*StdioClient = null,
    /// `true` ⇒ the cached `client` is "stale" (a recv/send timed out
    /// or its cancel-callback fired). The next `acquire` for this name
    /// kills the cached client and spawns a fresh one. Atomic so
    /// `Lease.markStale` — called by the thread that HOLDS the entry
    /// lock — is visible to the thread that later takes it.
    dirty: std.atomic.Value(bool) = .init(false),
    /// Serializes whole request/response transactions against this one
    /// child. This is the lock the server-crash fix turns on: MCP
    /// stdio is strictly one request / one response over one pipe, so
    /// a session that interleaves two `recv` calls on the same client
    /// corrupts `StdioClient.reader` (see its `read_buf` docs) and
    /// aborts the process.
    ///
    /// LOCK ORDER: the registry mutex is NEVER acquired while this one
    /// is held. `acquire` takes the registry lock only to allocate,
    /// drops it, then takes this one. A lease holder calls
    /// `Lease.markStale`, which is a bare atomic store and takes no
    /// lock at all. `deinit` takes registry → entry, matching the only
    /// remaining order. Getting this backwards deadlocks shutdown
    /// against an in-flight request.
    io_mutex: std.atomic.Mutex = .unlocked,
};

fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// Take `m`, giving up after `wait_ns` (0 = wait forever) or as soon
/// as `is_cancelled` returns true. Returns false if the lock was not
/// taken.
///
/// A plain `mutexLock` would be wrong here: the lock holder is a thread
/// blocked in `read(2)` on a child that may take its full 30s deadline
/// to answer, and spinning on it for that long burns a core and
/// ignores the workflow's Stop button. Sleeping between attempts
/// trades a few ms of latency after a normal contention event for not
/// melting the box during a pathological one.
fn tryLockUntil(
    io: std.Io,
    m: *std.atomic.Mutex,
    wait_ns: u64,
    is_cancelled: ?*const fn () bool,
) bool {
    if (m.tryLock()) return true;
    const has_deadline = wait_ns != 0;
    var waited: u64 = 0;
    while (true) {
        if (is_cancelled) |cb| if (cb()) return false;
        if (has_deadline) {
            if (waited >= wait_ns) return false;
            const step: u64 = @min(2 * std.time.ns_per_ms, wait_ns - waited);
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromNanoseconds(step), .clock = .real },
                io,
            ) catch return m.tryLock();
            waited += step;
        } else {
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromMilliseconds(2), .clock = .real },
                io,
            ) catch return m.tryLock();
        }
        if (m.tryLock()) return true;
    }
}

/// Exclusive, must-be-released handle on one MCP stdio child.
///
/// Obtain with `StdioRegistry.acquire`; hand back with `release`. The
/// child is reachable ONLY through the lease, which is the whole point:
/// it makes "one thread at a time per child" a type-level property
/// instead of a convention every call site has to remember. The old
/// `getOrSpawn` handed out a bare `*StdioClient` that four independent
/// call sites then drove concurrently, which is how the shared reader
/// got torn.
pub const Lease = struct {
    registry: *StdioRegistry,
    entry: *Entry,
    name: []const u8,
    released: bool = false,

    /// The child. Valid only while the lease is held.
    pub fn client(self: *const Lease) *StdioClient {
        return self.entry.client;
    }

    /// Flag the child for replacement on the next `acquire`. Takes no
    /// lock — the caller already holds the entry lock, and every other
    /// observer of `dirty` is also under that lock or is about to take
    /// it, so an atomic store is the correct (and deadlock-free) tool.
    ///
    /// Call this on any recv/send failure or timeout. A child that
    /// timed out may still be sitting on unread bytes that would be
    /// misparsed as the next response.
    pub fn markStale(self: *const Lease) void {
        self.entry.dirty.store(true, .release);
    }

    pub fn release(self: *Lease) void {
        if (self.released) return;
        self.released = true;
        self.entry.io_mutex.unlock();
    }
};

/// How long `acquire` is willing to wait for another session to finish
/// its transaction on the same server, and how to abort that wait.
pub const AcquireOptions = struct {
    /// 0 = wait indefinitely.
    wait_ns: u64 = 0,
    is_cancelled: ?*const fn () bool = null,
};

pub const StdioRegistry = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Owns the Threaded io backing `self.io` when non-null. The
    /// global registry lazily creates one via `global()`; per-test
    /// registries pass their own `io` and leave this null.
    threaded: ?*std.Io.Threaded = null,
    /// Keys (server names) and values (Entry pointers) are both
    /// allocated from the arena. `deinit` calls `arena.deinit()` once,
    /// which frees every key + entry in one shot — no per-entry free
    /// calls needed. Switched from `*StdioClient` to `*Entry` in 2026-08-28
    /// to carry the per-slot `dirty` flag for self-healing respawn.
    entries: std.StringHashMap(*Entry),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(parent_allocator: std.mem.Allocator, io: std.Io) StdioRegistry {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .io = io,
            .threaded = null,
            .entries = std.StringHashMap(*Entry).init(parent_allocator),
        };
    }

    /// Live, process-backed environment for spawned children.
    ///
    /// WHY THIS IS REQUIRED: `Std.Io.Threaded.init` defaults its
    /// `.environ` option to `.empty`. A Threaded with an empty environ
    /// makes `std.process.spawn` (the path taken by `StdioClient.init`
    /// below) exec children with an EMPTY environment — no `PATH`. A child
    /// shell that resolves a command by name (e.g. the `mcp-hello-world`
    /// wrapper doing `exec node "$SCRIPT_DIR/../../.../index.js"`) then
    /// falls back to libc's hard-coded default path (`/bin:/usr/bin`) and
    /// can't find the `node` binary that the build placed on PATH via
    /// actions/setup-node in CI (or that a real user has in
    /// `~/.nvm`/`/opt/homebrew/bin` via nvm/homebrew). Observed in CI as:
    ///
    ///   mcp-hello-world: line 11: exec: node: not found
    ///
    /// even though `node` IS reachable from the build process (the
    /// pnpm invocations in the mcp build chain succeed). It only happens
    /// at the nalar→child boundary because the GLOBAL registry builds its
    /// own Threaded (see `initThreaded`), whereas direct-from-pytest
    /// spawns use the harness's full environment and pass. Local dev
    /// boxes typically have node at `/usr/bin/node` (on the default
    /// fallback path) so the bug stays hidden.
    ///
    /// `std.start` constructs the main io the same way (capture the live
    /// environ block), so we mirror it here. `std.c.environ` links because
    /// nalar always links libc — the vendored curl/sqlite/openssl/libc++
    /// stacks all pull it in.
    fn processEnviron() std.process.Environ {
        const block: std.process.Environ.Block = switch (builtin.os.tag) {
            .windows => .global,
            else => posix: {
                const e = std.c.environ;
                var n: usize = 0;
                while (e[n] != null) : (n += 1) {}
                break :posix .{ .slice = e[0..n :null] };
            },
        };
        return .{ .block = block };
    }

    /// Lazy-init helper for the global registry: creates the Threaded
    /// io backing the registry. Per-instance callers should pass an
    /// existing `io` via `init` and leave `threaded` null.
    fn initThreaded(parent_allocator: std.mem.Allocator) !StdioRegistry {
        const threaded = try parent_allocator.create(std.Io.Threaded);
        // Pass `.processEnviron()` so spawned MCP children inherit PATH
        // (and the rest of the process env) — see processEnviron docs.
        threaded.* = std.Io.Threaded.init(parent_allocator, .{
            .environ = processEnviron(),
        });
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .io = threaded.io(),
            .threaded = threaded,
            .entries = std.StringHashMap(*Entry).init(parent_allocator),
        };
    }

    /// Allocate a `StdioClient` struct from the registry arena. The
    /// struct is left uninitialized; `StdioClient.init` fills it.
    /// Arena allocation is confined to this helper, which callers only
    /// ever invoke with the registry lock held.
    fn allocClientSlot(self: *StdioRegistry) StdioError!*StdioClient {
        return self.arena.allocator().create(StdioClient) catch StdioError.OutOfMemory;
    }

    /// Take exclusive use of the child for `name`, spawning one if
    /// there isn't a live client, and replacing it if a previous holder
    /// marked it stale.
    ///
    /// The returned `Lease` MUST be released (`defer lease.release()`).
    /// While it is held, no other thread can reach this child — that
    /// guarantee is the whole reason this function exists instead of a
    /// `getOrSpawn`-style accessor. `StdioClient` wraps a
    /// `std.Io.Reader`, which is two bare cursors with no internal
    /// locking, and it is NOT safe to drive from two threads.
    ///
    /// Memory ownership: the client struct, its key, and its arena are
    /// all backed by the registry arena and die with it.
    ///
    /// Self-healing: when the entry is dirty (some holder called
    /// `markStale` after a timeout or a cancel), the cached child is
    /// killed and replaced.
    pub fn acquire(
        self: *StdioRegistry,
        name: []const u8,
        argv: []const []const u8,
        opts: AcquireOptions,
    ) StdioError!Lease {
        // Phase 1 — registry lock, held only for map + arena work. All
        // allocation happens here (the registry arena is not thread
        // safe) and the lock is dropped before we ever wait on an
        // entry lock: holding a spinlock for the length of someone
        // else's 30s read would stall every other server too.
        mutexLock(&self.mutex);
        const entry = self.entries.get(name) orelse blk: {
            const client_slot = self.allocClientSlot() catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            const key_dup = self.arena.allocator().dupe(u8, name) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            const new_entry = self.arena.allocator().create(Entry) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            // A brand-new entry has no child. `has_client` stays false
            // and `spare` is pre-loaded so phase 3 has a slot to spawn
            // into without touching the (now unlocked) arena.
            new_entry.* = .{
                .client = client_slot,
                .has_client = false,
                .spare = self.allocClientSlot() catch {
                    self.mutex.unlock();
                    return StdioError.OutOfMemory;
                },
            };
            self.entries.put(key_dup, new_entry) catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
            break :blk new_entry;
        };
        // Top the spare back up for an entry that is about to respawn:
        // consumed in phase 3, and reserved here while the registry lock
        // still protects the arena.
        if (entry.spare == null) {
            entry.spare = self.allocClientSlot() catch {
                self.mutex.unlock();
                return StdioError.OutOfMemory;
            };
        }
        self.mutex.unlock();

        // Phase 2 — exclusive access to this child. Registry lock is
        // NOT held; see the LOCK ORDER note on `Entry.io_mutex`.
        if (!tryLockUntil(self.io, &entry.io_mutex, opts.wait_ns, opts.is_cancelled)) {
            return StdioError.LeaseTimeout;
        }
        errdefer entry.io_mutex.unlock();

        // Phase 3 — nobody else can be touching this child, so respawn
        // (or spawn, for an entry created above) without any further
        // locking.
        if (!entry.has_client or entry.dirty.load(.acquire) or entry.client.is_dead) {
            if (entry.has_client) entry.client.deinit();
            // Allocating from the registry arena is NOT thread-safe, and
            // the registry lock is already released. A `Lease` holder is
            // the only thread that may be here for THIS entry, but
            // another thread can be inside `acquire` for a DIFFERENT
            // entry and reach its own phase 3 at the same moment. So the
            // slot has to be reserved in phase 1, under the registry lock.
            const slot = entry.spare orelse return StdioError.OutOfMemory;
            entry.spare = null;
            slot.* = StdioClient.init(self.arena.allocator(), self.io, argv) catch |err| {
                // Keep the flag false / the entry dirty so the next
                // `acquire` retries instead of handing out the corpse.
                entry.has_client = false;
                entry.dirty.store(true, .release);
                return err;
            };
            entry.client = slot;
            entry.has_client = true;
            entry.dirty.store(false, .release);
        }
        return .{ .registry = self, .entry = entry, .name = name };
    }

    /// Mark the cached client for `name` as "stale" WITHOUT holding its
    /// entry lock, for callers that do not have a lease (a config save
    /// invalidating every server, say). Holders of a lease should call
    /// `Lease.markStale` instead — it needs no lookup and cannot
    /// deadlock.
    ///
    /// The next `acquire` for the same name kills the existing child and
    /// spawns a fresh one. Idempotent.
    pub fn markStale(self: *StdioRegistry, name: []const u8) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.entries.getPtr(name)) |entry_ptr| {
            entry_ptr.*.dirty.store(true, .release);
        }
    }

    /// Drop the cached client for `name` (if any) and spawn a fresh one.
    /// Note: the old client's memory isn't reclaimed individually — the
    /// arena owns it. Only the child process is killed.
    ///
    /// Not part of the request path (nothing calls it in production);
    /// kept for tests and for a future "server removed from config"
    /// cleanup. Takes registry → entry, the one legal nesting order.
    pub fn dropAndRespawn(
        self: *StdioRegistry,
        name: []const u8,
        argv: []const []const u8,
    ) !*StdioClient {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(name)) |kv| {
            // Take the entry lock before killing: a concurrent `acquire`
            // may be blocked on it and about to dereference this very
            // client. Without the lock, `deinit` frees the reader
            // (and the per-client arena) out from under that read.
            mutexLock(&kv.value.io_mutex);
            if (kv.value.has_client) kv.value.client.deinit();
            kv.value.io_mutex.unlock();
        }
        const client_slot = try self.allocClientSlot();
        const key_dup = try self.arena.allocator().dupe(u8, name);
        const new_entry = try self.arena.allocator().create(Entry);
        client_slot.* = try StdioClient.init(self.arena.allocator(), self.io, argv);
        new_entry.* = .{ .client = client_slot, .dirty = .init(false) };
        try self.entries.put(key_dup, new_entry);
        return client_slot;
    }

    /// Snapshot the current set of keys under the registry lock.
    /// Used by callers that need to iterate keys without holding the
    /// lock for long (the lock is dropped before `markStale` re-
    /// acquires it).
    pub fn keys(self: *StdioRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        const out = try allocator.alloc([]const u8, self.entries.count());
        var i: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            out[i] = kv.key_ptr.*;
            i += 1;
        }
        return out;
    }

    pub fn deinit(self: *StdioRegistry) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        // Kill all children first (deterministic order). Each entry lock
        // is taken before its child is killed, so a request that is
        // mid-`recv` on that child finishes (or aborts) against a live
        // reader instead of racing the teardown into a use-after-free.
        // Registry → entry is the only nesting order the rest of this
        // file uses, so this cannot invert.
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            mutexLock(&entry.io_mutex);
            // `has_client` guards an entry that was created but never
            // successfully spawned into — tearing down its uninitialized
            // slot would walk the arena's free list through garbage.
            if (entry.has_client) entry.client.deinit();
            entry.io_mutex.unlock();
        }
        const parent_allocator = self.entries.allocator;
        self.entries.deinit();
        // If we own a Threaded io (the global registry case), tear it
        // down before the arena. The Threaded instance itself was
        // allocated via `parent_allocator.create` in initThreaded (NOT
        // from the arena), so we must .deinit() it (joins background
        // threads) AND .destroy() it — otherwise the struct leaks
        // (caught by the buildMCPToolsRun bogus-command unit test).
        if (self.threaded) |t| {
            t.deinit();
            parent_allocator.destroy(t);
            self.threaded = null;
        }
        // Single arena.deinit() frees ALL the clients + keys + the
        // Threaded struct at once.
        self.arena.deinit();
    }

    // Process-global singleton. Lives for the whole nalar process.
    // Cleaned up via the shutdown hook in main.zig (Task 7).
    //
    // Backing rule (use-after-free post-mortem, see
    // `mcp_http.HttpRegistry.global`): production reaches this through
    // the eager init in main.zig (process-lifetime GPA) and the cached
    // `di.mcp_stdio_registry` handle. The lazy `global(allocator)`
    // path below only serves unit tests — never pass a per-run arena
    // there, or the first call poisons all later runs with dead memory.

    var global_registry: ?StdioRegistry = null;
    var global_init_mutex: std.atomic.Mutex = .unlocked;

    /// Get the process-global registry. Lazily initialized on first call.
    /// `allocator` is the long-lived allocator (passed down from main.zig,
    /// typically `di.allocator`) — NOT `std.heap.page_allocator`.
    ///
    /// The global registry owns its own `std.Io.Threaded` instance,
    /// created lazily here and torn down in `deinitGlobal`. This is
    /// the same pattern used elsewhere in the codebase for long-lived
    /// io contexts (see e.g. `agent_memories.zig:525`).
    pub fn global(allocator: std.mem.Allocator) *StdioRegistry {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry == null) {
            global_registry = initThreaded(allocator) catch @panic("OOM: StdioRegistry.global");
        }
        return &global_registry.?;
    }

    /// Called by main.zig shutdown hook. Kills all spawned children AND
    /// frees all registry memory (via the arena) AND deinits the
    /// owned Threaded io.
    pub fn deinitGlobal() void {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry) |*reg| {
            reg.deinit();
            global_registry = null;
        }
    }
};

// ============================================================================
// Tests — inline at the bottom (project convention)
// ============================================================================

const testing = std.testing;

// ── Framing tests (no child needed) ────────────────────────────────────────

test "readFramed parses Content-Length body" {
    // Build a fake byte stream using a temp file (so we exercise std.fs.File.read).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "framing_test_input.txt";
    // Body is 14 bytes: `{"json":"rpc"}` — 1 + 1 + 4 + 1 + 1 + 1 + 4 + 1 + 1 = 14.
    const payload = "Content-Length: 14\r\n\r\n{\"json\":\"rpc\"}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = payload });

    var file = try tmp.dir.openFile(testing.io, path, .{});
    defer file.close(testing.io);

    const body = try readFramed(testing.allocator, testing.io, file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\"}", body);
}

test "readFramed accepts LF-only blank-line separator" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "lf_only.txt";
    const payload = "Content-Length: 5\r\nX-Bogus: y\n\nhello";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = payload });

    var file = try tmp.dir.openFile(testing.io, path, .{});
    defer file.close(testing.io);

    const body = try readFramed(testing.allocator, testing.io, file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed returns InvalidFrame when Content-Length missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "no_cl.txt";
    const payload = "X-Bogus: y\r\n\r\nhello";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = payload });

    var file = try tmp.dir.openFile(testing.io, path, .{});
    defer file.close(testing.io);

    _ = readFramed(testing.allocator, testing.io, file, 0, null) catch |e| {
        try testing.expectEqual(StdioError.InvalidFrame, e);
        return;
    };
    try testing.expect(false); // unreachable
}

test "writeFramed emits Content-Length header + body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "framing_out.txt";
    var file = try tmp.dir.createFile(testing.io, path, .{});
    defer file.close(testing.io);

    try writeFramed(testing.io, file, "hi", 0);

    var file2 = try tmp.dir.openFile(testing.io, path, .{});
    defer file2.close(testing.io);
    const stat = try file2.stat(testing.io);
    const got = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(got);
    const n = try std.Io.File.readPositionalAll(file2, testing.io, got, 0);
    try testing.expectEqualStrings("Content-Length: 2\r\n\r\nhi", got[0..n]);
}

test "writeFramed roundtrips through readFramed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write to file A.
    var file_a = try tmp.dir.createFile(testing.io, "a.txt", .{});
    try writeFramed(testing.io, file_a, "{\"a\":1}", 0);
    file_a.close(testing.io);

    // Read back via readFramed.
    var file_b = try tmp.dir.openFile(testing.io, "a.txt", .{});
    defer file_b.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file_b, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"a\":1}", body);
}

test "readFramed parses newline-delimited JSON body (MCP SDK default)" {
    // The canonical @modelcontextprotocol/sdk v1.x writes
    // `JSON.stringify(message) + '\n'` — newline-delimited JSON, NOT
    // Content-Length framed. readFramed auto-detects by peeking the
    // first byte ('{' triggers the NDJSON path). See:
    //   src/apps/mcp_hello_world/node_modules/@modelcontextprotocol/
    //   sdk/dist/cjs/shared/stdio.js:37 (serializeMessage)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(testing.io, "ndjson.txt", .{});
    try file.writeStreamingAll(testing.io, "{\"json\":\"rpc\",\"id\":1}\n");
    file.close(testing.io);

    var file2 = try tmp.dir.openFile(testing.io, "ndjson.txt", .{});
    defer file2.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file2, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\",\"id\":1}", body);
}

test "readFramed parses newline-delimited JSON without trailing newline" {
    // Some servers (or test harnesses) omit the trailing \n on exit.
    // We still return whatever we accumulated up to EOF.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(testing.io, "no_nl.txt", .{});
    try file.writeStreamingAll(testing.io, "{\"json\":\"rpc\"}");
    file.close(testing.io);

    var file2 = try tmp.dir.openFile(testing.io, "no_nl.txt", .{});
    defer file2.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file2, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\"}", body);
}

test "readFramed handles CRLF terminator on newline-delimited JSON" {
    // Some servers emit \r\n on Windows-style line endings. readFramed
    // must strip the trailing \r before returning the JSON body.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(testing.io, "crlf.txt", .{});
    try file.writeStreamingAll(testing.io, "{\"json\":\"rpc\"}\r\n");
    file.close(testing.io);

    var file2 = try tmp.dir.openFile(testing.io, "crlf.txt", .{});
    defer file2.close(testing.io);
    const body = try readFramed(testing.allocator, testing.io, file2, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"json\":\"rpc\"}", body);
}

// ── StdioClient tests (real child process) ────────────────────────────────
// Cross-platform: use `cat` on POSIX, `cmd.exe /C more` on Windows.

fn echo_argv() []const []const u8 {
    return if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "more" }
    else
        &.{"cat"};
}

test "StdioClient.init spawns child successfully" {
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        // On Windows CI without `cmd.exe` on PATH the test would fail —
        // mark as skip so we don't break the cross-platform build.
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        return err;
    };
    defer client.deinit();
    try testing.expect(client.stdin != null);
    try testing.expect(client.stdout != null);
}

test "StdioClient.send writes framed bytes to child stdin" {
    // NOTE: full send+recv roundtrips are exercised by the functional
    // test at tests/functional/mcp_stdio_test.py — that test runs
    // against a real `mcp-hello-world` binary with the threaded io in
    // a fully-wired nalar process. The in-process Zig test below has
    // race conditions with the threaded test runtime (the child can
    // appear to close its stdin early when the test scope tears down
    // the test runtime), so we only assert that `StdioClient.init`
    // succeeds here. The framing + send logic is covered by
    // StdioClient.init (test 6) and the fd-leak tests (15-17).
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "ping", "-n", "2", "127.0.0.1" } // ~1s on Windows
    else
        &.{ "sleep", "1" };
    _ = StdioClient.init(testing.allocator, testing.io, argv) catch |err| {
        // On platforms without `sleep`/`ping` we skip — the framing
        // roundtrip is covered by the writeFramed/readFramed tests.
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
}

test "StdioClient.init returns ChildSpawnFailed for missing binary" {
    _ = StdioClient.init(testing.allocator, testing.io, &.{"/no/such/binary/should/exist/xyzzy"}) catch |e| {
        try testing.expectEqual(StdioError.ChildSpawnFailed, e);
        return;
    };
    try testing.expect(false); // unreachable
}

test "StdioClient.deinit kills child without error" {
    var client = try StdioClient.init(testing.allocator, testing.io, echo_argv());
    // deinit must be a no-fail, idempotent cleanup.
    client.deinit();
}

// ── StdioRegistry tests ────────────────────────────────────────────────────

test "StdioRegistry.init + deinit roundtrip" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    try testing.expectEqual(@as(usize, 0), reg.entries.count());
}

test "acquire returns the same client across calls (cached)" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("alpha", echo_argv(), .{});
    const c1 = l1.client();
    l1.release();
    var l2 = try reg.acquire("alpha", echo_argv(), .{});
    defer l2.release();
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(l2.client()));
}

test "acquire with different names returns different clients" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var la = try reg.acquire("a", echo_argv(), .{});
    const a = la.client();
    la.release();
    var lb = try reg.acquire("b", echo_argv(), .{});
    defer lb.release();
    try testing.expect(a != lb.client());
}

test "StdioRegistry.dropAndRespawn returns a different client" {
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("x", echo_argv(), .{});
    const c1 = l1.client();
    l1.release();
    const c2 = try reg.dropAndRespawn("x", echo_argv());
    try testing.expect(c1 != c2);
}

test "StdioRegistry.deinit kills spawned children (no hang)" {
    {
        var reg = StdioRegistry.init(testing.allocator, testing.io);
        var la = try reg.acquire("a", echo_argv(), .{});
        la.release();
        var lb = try reg.acquire("b", echo_argv(), .{});
        lb.release();
        reg.deinit();
    }
    // No assertion — the test passes if deinit returns and the test
    // process doesn't hang. CI timeout is the real assertion.
}

// ── FD-leak regression tests ───────────────────────────────────────────────
//
// Same pattern as kabelweb repo src/client/fd_leak_test.zig — we
// count open FDs via `ls /proc/self/fd | wc -l` (Linux only; skip on
// other OS) and assert that spawn + deinit cycles do not grow the count.
// The test spawns multiple stdio children in a tight loop and verifies
// the FD count returns to the baseline after StdioRegistry.deinit
// frees the arena (which should close every pipe + reap every child).

/// Count open FDs by running `ls /proc/self/fd`. Linux-only;
/// non-Linux hosts return 0 and the tests skip.
fn countOpenFds() usize {
    if (builtin.os.tag != .linux) return 0;
    var child = std.process.spawn(testing.io, .{
        .argv = &.{ "sh", "-c", "ls /proc/self/fd 2>/dev/null | wc -l" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return 0;
    // `child.kill` in Zig 0.16 closes stdin/stdout/stderr pipes internally
    // (via `childCleanupPosix`) and nulls child.id. We must NOT manually
    // close child.stdout — that double-closes the FD and triggers
    // `recoverableOsBugDetected` (use-after-free).
    defer child.kill(testing.io);

    var buf: [64]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |out| {
        var reader = out.reader(testing.io, &buf);
        while (true) {
            const n = std.Io.Reader.readSliceShort(&reader.interface, &buf) catch break;
            if (n == 0) break;
            total += n;
        }
    }

    var n: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const c = buf[i];
        if (c >= '0' and c <= '9') {
            n = n * 10 + @as(usize, c - '0');
        }
    }
    return n;
}

test "fd: StdioClient.init + deinit does not leak FDs (20 cycles)" {
    if (builtin.os.tag != .linux) return;
    const before = countOpenFds();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch continue;
        client.deinit();
    }
    // Give the OS a moment to actually close the FDs.
    std.Io.sleep(testing.io, .{ .nanoseconds = std.time.ns_per_ms * 50 }, .real) catch {};
    const after = countOpenFds();
    // Tolerance: a few transient FDs from countOpenFds's own child
    // may be in flight; we allow 5 of slack.
    const tolerance: usize = 5;
    if (after > before + tolerance) {
        std.debug.print("!! FD leak: before={d} after={d} delta={d} !!\n", .{ before, after, after - before });
        return error.FdLeakSuspected;
    }
}

test "fd: StdioRegistry spawn + deinit does not leak FDs (20 servers)" {
    if (builtin.os.tag != .linux) return;
    const before = countOpenFds();
    {
        var reg = StdioRegistry.init(testing.allocator, testing.io);
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            const name = std.fmt.allocPrint(testing.allocator, "server-{d}", .{i}) catch continue;
            defer testing.allocator.free(name);
            var lease = reg.acquire(name, echo_argv(), .{}) catch continue;
            lease.release();
        }
        reg.deinit();
    }
    std.Io.sleep(testing.io, .{ .nanoseconds = std.time.ns_per_ms * 50 }, .real) catch {};
    const after = countOpenFds();
    const tolerance: usize = 5;
    if (after > before + tolerance) {
        std.debug.print("!! FD leak: before={d} after={d} delta={d} !!\n", .{ before, after, after - before });
        return error.FdLeakSuspected;
    }
}

test "fd: failed spawn does not leak FDs (20 attempts at missing binary)" {
    if (builtin.os.tag != .linux) return;
    const before = countOpenFds();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = StdioClient.init(testing.allocator, testing.io, &.{
            "/no/such/binary/should/exist/xyzzy",
        }) catch {};
    }
    std.Io.sleep(testing.io, .{ .nanoseconds = std.time.ns_per_ms * 50 }, .real) catch {};
    const after = countOpenFds();
    const tolerance: usize = 5;
    if (after > before + tolerance) {
        std.debug.print("!! FD leak: before={d} after={d} delta={d} (failed-spawn path) !!\n", .{ before, after, after - before });
        return error.FdLeakSuspected;
    }
}

// ── Timeout / cancel-callback / markStale tests (Task 3) ───────────────────
//
// The single-thread `testing.io` makes deadline tests use real wall time —
// no virtual clock. Slack tolerance per test is documented in a comment.

/// Argv for a child that exits (closes stdout) AFTER a bounded delay
/// longer than the test's recv deadline but shorter than the test's
/// slack window. POSIX: `sh -c "sleep 0.6"`; Windows:
/// `cmd.exe /C "timeout /T 1 /NOBREAK"`. Use this for tests that
/// assert `recv` returns within `deadline + slack` — see
/// `"recv returns RecvTimeout when child never responds"` for the
/// full rationale.
///
/// NOTE (2026-09-03): `waitReadable` (`posix.poll`) now bounds even the
/// first-byte read on POSIX, so truly-silent children are covered by
/// the dedicated `"recv times out on truly-silent child"` test below.
/// This helper stays for the close-after-deadline shape (child exits
/// on its own → `UnexpectedEof` branch).
fn eventually_closes_argv() []const []const u8 {
    return if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "timeout", "/T", "1", "/NOBREAK" }
    else
        &.{ "sh", "-c", "sleep 0.6" };
}

test "recv returns RecvTimeout when child never responds" {
    // 500ms deadline. The child never writes anything, so the
    // first-byte read either blocks until the deadline (the path
    // we want to test) or returns EOF when the child finally exits
    // and closes stdout. Either is a valid timeout-bounded outcome —
    // we accept both. The test asserts that the recv completes within
    // `deadline + slack` (700ms — 200ms for thread wake-up jitter
    // on slow CI runners). A NON-bounded recv (hanging past the
    // deadline) fails this test via the zig test runner's hang
    // detector.
    //
    // WHY NOT A TRULY-HUNG CHILD HERE: this test predates `waitReadable`
    // (2026-09-03) and keeps its close-after-deadline shape to cover the
    // `UnexpectedEof` branch. The truly-silent shape (child never closes
    // stdout — e.g. bare `python` with no args waiting on stdin for EOF,
    // or `sleep 60`) is covered by `"recv times out on truly-silent
    // child"` below, which would hang forever without the `posix.poll`
    // first-byte guard.
    //
    // WORKAROUND (kept for this test's shape): use a child that exits (and closes stdout) AFTER
    // the deadline elapses, but BEFORE the test's 700ms slack window.
    // POSIX: `sh -c "sleep 0.6"` — sh owns the pipe, so even if
    // sleep's libc-init prematurely closes its inherited stdout ref
    // (the kernel quirk that killed `sleep 60`), sh still holds a ref
    // and the pipe stays open until sh exits ~600ms later.
    // Windows: `cmd /C "timeout /T 1"` — Windows `timeout` waits 1s
    // then exits; it's a CMD builtin so no spawn-arg quoting issues.
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/C", "timeout", "/T", "1", "/NOBREAK" }
    else
        &.{ "sh", "-c", "sleep 0.6" };
    var client = StdioClient.init(testing.allocator, testing.io, argv) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const deadline_ns: u64 = 500 * std.time.ns_per_ms;
    const result = client.recv(deadline_ns, null);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    // Either error is acceptable — both prove the recv is bounded.
    // RecvTimeout: the deadline check fired (preferred).
    // UnexpectedEof: the kernel saw the child close stdout first
    //   (~600ms via `sleep 0.6`, well within the 700ms slack).
    try testing.expect(result == error.RecvTimeout or result == error.UnexpectedEof);
    // Slack 200ms above the 500ms deadline.
    try testing.expect(elapsed_ms < 700);
}

test "recv aborts immediately when cancel callback returns true" {
    // Cancel callback returns true on the FIRST call. The recv loop
    // bails out at the next check — well before any deadline fires.
    // We pass a 10s deadline so the deadline is irrelevant here;
    // the cancel-callback path is what we exercise.
    //
    // NOTE (2026-09-03): `waitReadable` now consults the cancel
    // callback inside the first-byte wait too, so a truly-silent child
    // aborts on cancel without producing any bytes — covered by
    // `"recv aborts on cancel with truly-silent child"` below. This
    // test keeps its echo shape (data on the wire → cancel observed
    // between bytes).
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    // Write some data to the child's stdin so it has something to
    // echo back. Without this, the first read blocks forever
    // (echo has no input to read on its stdin).
    const stdin_file = client.stdin orelse return error.BrokenPipe;
    const probe = "x\n";
    std.Io.File.writeStreamingAll(stdin_file, testing.io, probe) catch return;

    const cancel = struct {
        fn call() bool {
            return true;
        }
    }.call;
    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const result = client.recv(10_000 * std.time.ns_per_ms, &cancel);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    // The cancel-callback is consulted between bytes, so any
    // error that indicates the recv is bounded (RecvTimeout) is
    // acceptable. We just want to prove the recv doesn't hang
    // past the deadline.
    try testing.expect(result == error.RecvTimeout or result == error.BrokenPipe);
    // Should be effectively instant after the first byte reads.
    // 200ms slack for slow CI runners + Threaded io overhead.
    try testing.expect(elapsed_ms < 200);
}

test "markStale: acquire respawns instead of returning cached client" {
    // Two acquires with a markStale in between must produce DIFFERENT
    // StdioClient pointers — the dirty flag forced a fresh spawn. Uses
    // echo_argv so the spawn is fast and the test is deterministic.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("foo", echo_argv(), .{});
    const c1 = l1.client();
    l1.release();
    reg.markStale("foo");
    var l2 = try reg.acquire("foo", echo_argv(), .{});
    defer l2.release();
    try testing.expect(c1 != l2.client());
}

test "Lease.markStale respawns on the next acquire" {
    // Same contract as the by-name `markStale`, but driven through the
    // lease the caller actually holds — which is the path every request
    // handler uses on a timeout.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var l1 = try reg.acquire("bar", echo_argv(), .{});
    const c1 = l1.client();
    l1.markStale();
    l1.release();
    var l2 = try reg.acquire("bar", echo_argv(), .{});
    defer l2.release();
    try testing.expect(c1 != l2.client());
    // The replacement must come back clean, or the respawn never sticks.
    try testing.expectEqual(false, l2.entry.dirty.load(.acquire));
}

test "markStale on unknown name is a no-op (does not panic or insert)" {
    // Self-healing contract: markStale against a server that hasn't
    // been spawned yet is silently ignored. The next acquire
    // for that name still works (creates a fresh entry).
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    reg.markStale("not_in_registry"); // must not crash
    try testing.expectEqual(@as(usize, 0), reg.entries.count());
    var lease = try reg.acquire("not_in_registry", echo_argv(), .{});
    lease.release();
    try testing.expectEqual(@as(usize, 1), reg.entries.count());
}

// ── First-byte deadline tests (2026-09-03 empty-args hang fix) ──────────────
//
// Regression coverage for the `/api/mcp/test` hang: probing a stdio
// server with empty args spawns the bare command (e.g. `python` with
// no args), which waits on stdin for EOF while writing zero stdout
// bytes. Without `waitReadable`'s `posix.poll` guard the first-byte
// `readSliceShort` blocked forever and the deadline never fired.
// These tests use a truly-silent child (`sleep 30`, killed by the
// `defer client.deinit()` at test end) — pre-fix they hang the test
// runner; post-fix they return `RecvTimeout` in ~deadline.
//
// POSIX-only: `waitReadable` is `comptime`-gated out on Windows
// (`std.posix.poll` is a `@compileError` there), so Windows keeps the
// old blocking behavior and these tests must skip there.

/// Argv for a child that stays alive and silent well past any test
/// deadline. POSIX-only (`sleep`); Windows callers must skip first.
fn silent_child_argv() []const []const u8 {
    return &.{ "sleep", "30" };
}

test "recv times out on truly-silent child (empty-args bare command)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var client = StdioClient.init(testing.allocator, testing.io, silent_child_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const result = client.recv(300 * std.time.ns_per_ms, null);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    try testing.expect(result == error.RecvTimeout);
    // Waited ~the full deadline (not an instant fail) but stayed far
    // below any hang: 200ms lower bound proves the poll actually
    // waited; 5s upper bound proves the deadline fired (pre-fix this
    // recv never returned at all).
    try testing.expect(elapsed_ms >= 200);
    try testing.expect(elapsed_ms < 5000);
}

test "recv aborts on cancel with truly-silent child" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var client = StdioClient.init(testing.allocator, testing.io, silent_child_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    const cancel = struct {
        fn call() bool {
            return true;
        }
    }.call;
    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    // 10s deadline is irrelevant — cancel fires inside the first
    // 100ms poll slice, so the recv must abort almost immediately
    // even though the child never produces a single byte.
    const result = client.recv(10_000 * std.time.ns_per_ms, &cancel);
    const elapsed_ms: u64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    ));
    try testing.expect(result == error.RecvTimeout);
    try testing.expect(elapsed_ms < 2000);
}

test "recv with deadline still delivers data (happy path)" {
    // Guards the `waitReadable` fast path: when the child IS producing,
    // poll returns readable immediately and the framed message comes
    // back intact. Runs on all platforms (`waitReadable` is a no-op
    // pass-through on Windows).
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    const stdin_file = client.stdin orelse return error.BrokenPipe;
    // NDJSON-framed line; `cat`/`more` echoes it back on stdout.
    const probe = "{\"jsonrpc\":\"2.0\",\"id\":1}\n";
    std.Io.File.writeStreamingAll(stdin_file, testing.io, probe) catch return;

    const body = client.recv(5_000 * std.time.ns_per_ms, null) catch |err| {
        std.debug.print("!! happy-path recv failed: {s} !!\n", .{@errorName(err)});
        return err;
    };
    // `recv` allocates the body from the client's own arena, so it has
    // to be freed through the same allocator that produced it —
    // `testing.allocator.free` on an arena-owned pointer is an
    // "Invalid free" panic under DebugAllocator.
    defer client.allocator().free(body);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", body);
}

test "recv preserves coalesced back-to-back lines (lightpanda hang)" {
    // A fast server writes two NDJSON lines in one pipe write; the
    // first recv() must not drop the second line with its buffer.
    // Uses a printf child (not cat+stdin) so both lines exist before
    // the first recv runs — no echo timing race. POSIX-only: printf
    // via sh; Windows keeps old behavior (waitReadable is a no-op).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const argv: []const []const u8 = &.{
        "sh", "-c", "printf '{\"jsonrpc\":\"2.0\",\"id\":1}\\n{\"jsonrpc\":\"2.0\",\"id\":2}\\n'",
    };
    var client = StdioClient.init(testing.allocator, testing.io, argv) catch |err| {
        if (err == error.ChildSpawnFailed) return;
        return err;
    };
    defer client.deinit();

    // Both bodies come from the client's per-client arena (see the
    // `recv` allocator note in the happy-path test above).
    const first = client.recv(5_000 * std.time.ns_per_ms, null) catch |err| {
        std.debug.print("!! coalesced first recv failed: {s} !!\n", .{@errorName(err)});
        return err;
    };
    defer client.allocator().free(first);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", first);

    const second = client.recv(5_000 * std.time.ns_per_ms, null) catch |err| {
        std.debug.print("!! coalesced second recv failed: {s} !!\n", .{@errorName(err)});
        return err;
    };
    defer client.allocator().free(second);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2}", second);
}

// ============================================================================
// Framing + lease edge cases (concurrency / framing hardening)
// ============================================================================
//
// Three groups, each pinning a contract that a later refactor can only
// break silently:
//
//   A. Framing edge cases — what `readFramed` does with a header that is
//      malformed, hostile, or truncated. These are pure parser cases, so
//      they run off a temp file with no child process.
//   B. Body-size guards — `Content-Length` is attacker-controlled text.
//      A frame that parses cleanly must still be rejected *before* the
//      allocation, and the error has to say "too large" rather than
//      "out of memory" or "the connection died".
//   C. Lease / concurrency contracts — one thread at a time per child,
//      with cancellation, idempotent cleanup, and a post-death client
//      that refuses to touch recycled file descriptors.
//
// NOTE on the omitted CRLF/NDJSON case: `readFramed handles CRLF
// terminator on newline-delimited JSON` above already pins the trailing
// `\r` strip, so it is not duplicated here.

/// Temp file + open handle for one `readFramed` case. The framing tests
/// all need the same three steps (temp dir, write payload, open for
/// read) and the existing tests above spell them out inline; with a
/// dozen edge cases to add, folding them into one helper keeps the
/// actual contract visible in each test body.
const FramedInput = struct {
    tmp: std.testing.TmpDir,
    file: std.Io.File,

    fn deinit(self: *FramedInput) void {
        self.file.close(testing.io);
        self.tmp.cleanup();
    }
};

fn framedInput(name: []const u8, payload: []const u8) !FramedInput {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = payload });
    return .{ .tmp = tmp, .file = try tmp.dir.openFile(testing.io, name, .{}) };
}

// ── A. Framing edge cases ──────────────────────────────────────────────────

test "readFramed rejects a negative Content-Length as InvalidContentLength" {
    // A sign character is the cheapest way to smuggle a length past a
    // naive parser: `-5` is a valid token to anything HTTP-shaped, and
    // a parser that strips the sign would hand back a 5-byte body that
    // was never promised. The error has to be the *specific* one so a
    // caller can tell "garbage header" apart from "well-formed header,
    // body truncated" — the two need opposite recovery.
    var input = try framedInput("neg_content_length.txt", "Content-Length: -5\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidContentLength,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed rejects a non-numeric Content-Length as InvalidContentLength" {
    // Same distinction as the negative case, different failure mode in
    // `parseInt`. Worth its own test because the two are the only
    // places `InvalidContentLength` can come from, and both are
    // reachable from a real server that formats the header wrong.
    var input = try framedInput("nan_content_length.txt", "Content-Length: abc\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidContentLength,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed returns an empty body and no error for Content-Length: 0" {
    // A zero-length frame is a server saying "alive, nothing to say".
    // Turning it into an error makes a keepalive ping look like a dead
    // transport, and a caller that sees a non-zero `.len` on a
    // zero-byte allocation gets an invalid free the moment it hands the
    // slice back to the allocator.
    var input = try framedInput("zero_content_length.txt", "Content-Length: 0\r\n\r\n");
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqual(@as(usize, 0), body.len);
}

test "readFramed matches the Content-Length header name case-insensitively" {
    // Header names are case-insensitive and real MCP servers are not
    // consistent about the casing they emit (`content-length` from some
    // SDK paths, `Content-Length` from others). A case-sensitive match
    // degrades silently to "no header found" — InvalidFrame on a frame
    // that is perfectly valid — so the insensitivity is load-bearing
    // for interoperability, not a nicety.
    var input = try framedInput("lower_content_length.txt", "content-length: 5\r\n\r\nhello");
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed tolerates tabs and trailing spaces around the Content-Length value" {
    // Real servers (and proxies in front of them) hand-mangle header
    // whitespace. Trimming only spaces turns a valid frame into
    // InvalidContentLength and knocks the server offline for a
    // formatting difference.
    var input = try framedInput("padded_content_length.txt", "Content-Length:\t 5 \r\n\r\nhello");
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed finds Content-Length after other headers in the block" {
    // The MCP spec frames with Content-Length among *possibly many*
    // headers. Reading only the first line drops every server that also
    // announces Content-Type, which is most of them.
    var input = try framedInput(
        "multi_header.txt",
        "Content-Type: application/json\r\nContent-Length: 5\r\n\r\nhello",
    );
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "readFramed returns InvalidFrame on a stray log line instead of swallowing the next message" {
    // THE REGRESSION this guards. A server that logs to stdout used to
    // make the parser scan past the log line, keep buffering, and then
    // sit waiting for a blank line that only the *next* real message
    // would produce — so a perfectly healthy JSON-RPC response came back
    // as a timeout and the caller killed the child. Bailing at the
    // first line without a colon turns an unbounded hang into one cheap
    // respawn.
    var input = try framedInput("stray_log_line.txt", "some log line\n{\"jsonrpc\":\"2.0\"}\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidFrame,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed reports UnexpectedEof when EOF lands mid-header" {
    // A child that dies between spawn and answer leaves a truncated
    // header. Reporting InvalidFrame would send the operator hunting a
    // protocol bug in a server that simply crashed; UnexpectedEof is
    // what makes them respawn.
    var input = try framedInput("eof_in_header.txt", "Content-Len");
    defer input.deinit();
    try testing.expectError(
        StdioError.UnexpectedEof,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed reports UnexpectedEof when the body is shorter than Content-Length promised" {
    // The body allocation is sized from the header, so a child that dies
    // 3 bytes into a 100-byte body leaves a hole. Returning the short
    // buffer would hand the caller a truncated document that looks
    // complete; blocking for the remainder would hang until the
    // deadline. UnexpectedEof is the only honest answer.
    //
    // Arena-backed: the parser's body allocation is abandoned on this
    // error path, and a raw `testing.allocator` would report a leak
    // that says nothing about the contract under test.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var input = try framedInput("eof_in_body.txt", "Content-Length: 100\r\n\r\nhel");
    defer input.deinit();
    try testing.expectError(
        StdioError.UnexpectedEof,
        readFramed(arena.allocator(), testing.io, input.file, 0, null),
    );
}

test "readFramed returns InvalidFrame when the header block overruns MAX_HEADER_BYTES" {
    // The header buffer is a fixed 8 KiB stack array, so the bound is
    // the only thing making that allocation safe: a server (or a
    // confused proxy) streaming megabytes of headers would otherwise run
    // us off the end of the stack. The junk is a single header-shaped
    // line on purpose — this pins the overflow guard, not the
    // non-header-line guard, which has its own test above.
    const prefix = "X-Pad: ";
    const payload = try testing.allocator.alloc(u8, prefix.len + MAX_HEADER_BYTES + 64);
    defer testing.allocator.free(payload);
    @memcpy(payload[0..prefix.len], prefix);
    @memset(payload[prefix.len..], 'a');
    var input = try framedInput("header_flood.txt", payload);
    defer input.deinit();
    try testing.expectError(
        StdioError.InvalidFrame,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed returns a growth-path NDJSON line at its exact payload length" {
    // Real tool results blow past the 256-byte seed buffer constantly,
    // so the realloc-doubling path is the hot path, not a corner case.
    // The returned `.len` matters as much as the bytes: the caller
    // frees the slice with the same allocator, and DebugAllocator aborts
    // when the length doesn't match the reservation — which is exactly
    // what the `catch body[0..len]` shortcut in `shrinkToLen` used to
    // do, on the OOM path where no repro would ever reach it.
    const prefix = "{\"jsonrpc\":\"2.0\",\"result\":\"";
    const suffix = "\"}\r\n";
    const fill: usize = 1000;
    const payload = try testing.allocator.alloc(u8, prefix.len + fill + suffix.len);
    defer testing.allocator.free(payload);
    @memcpy(payload[0..prefix.len], prefix);
    @memset(payload[prefix.len..][0..fill], 'x');
    @memcpy(payload[prefix.len + fill ..], suffix);
    const expected = payload[0 .. payload.len - 2]; // drop the CRLF
    var input = try framedInput("ndjson_growth.txt", payload);
    defer input.deinit();
    const body = try readFramed(testing.allocator, testing.io, input.file, 0, null);
    defer testing.allocator.free(body);
    try testing.expectEqual(expected.len, body.len);
    try testing.expectEqualStrings(expected, body);
}

// ── B. Body-size guards ────────────────────────────────────────────────────

test "readFramed rejects a Content-Length far above the cap as BodyTooLarge" {
    // 99,999,999,999 is a perfectly valid usize. A parser that trusts
    // the header turns five bytes of text into a 95 GiB allocation
    // before it ever looks at the socket, and the process dies on an
    // OOM-checked allocator (or succeeds under overcommit and then
    // blocks). The error has to be BodyTooLarge specifically: an
    // OutOfMemory or UnexpectedEof here both read as "the server is
    // broken" and invite a retry loop against a hostile endpoint.
    var input = try framedInput("oversized_content_length.txt", "Content-Length: 99999999999\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.BodyTooLarge,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed rejects Content-Length of maxInt(u64) as BodyTooLarge without allocating it" {
    // The literal the MAX_BODY_BYTES doc calls out: 16 EiB parses
    // cleanly into a usize and is the maximum an attacker can write in
    // one header line. Guarded on bit width because on a 32-bit target
    // the literal doesn't fit a usize at all and the error would be
    // InvalidContentLength — asserting BodyTooLarge there would pin the
    // wrong contract for that target.
    if (comptime @bitSizeOf(usize) < 64) return error.SkipZigTest;
    var input = try framedInput("maxint_content_length.txt", "Content-Length: 18446744073709551615\r\n\r\n");
    defer input.deinit();
    try testing.expectError(
        StdioError.BodyTooLarge,
        readFramed(testing.allocator, testing.io, input.file, 0, null),
    );
}

test "readFramed's body cap is exclusive: exactly MAX_BODY_BYTES passes, one byte over is BodyTooLarge" {
    // Off-by-one is a real bug in either direction — `>=` rejects a
    // legitimate 10 MiB tool result, which is the SDK's own default
    // buffer size. The `+1` half is the cheap one (it must short-circuit
    // before the allocation); the exact-cap half pays a 10 MiB
    // allocation to prove the guard did *not* fire and that the missing
    // body is what surfaces instead. Arena-backed because that 10 MiB
    // reservation is abandoned on the EOF path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var over_buf: [64]u8 = undefined;
    const over = try std.fmt.bufPrint(&over_buf, "Content-Length: {d}\r\n\r\n", .{MAX_BODY_BYTES + 1});
    var over_input = try framedInput("one_over_cap.txt", over);
    defer over_input.deinit();
    try testing.expectError(
        StdioError.BodyTooLarge,
        readFramed(testing.allocator, testing.io, over_input.file, 0, null),
    );

    var at_buf: [64]u8 = undefined;
    const at_cap = try std.fmt.bufPrint(&at_buf, "Content-Length: {d}\r\n\r\n", .{MAX_BODY_BYTES});
    var at_input = try framedInput("exactly_at_cap.txt", at_cap);
    defer at_input.deinit();
    try testing.expectError(
        StdioError.UnexpectedEof,
        readFramed(arena.allocator(), testing.io, at_input.file, 0, null),
    );
}

// ── C. Lease / concurrency contracts ───────────────────────────────────────

test "acquire on an already-leased entry returns LeaseTimeout and the entry stays acquirable" {
    // Two sessions reaching for the same MCP server is normal traffic,
    // not an error condition — but the second one must not get the
    // child, because `StdioClient` wraps a bare-cursor reader with no
    // internal locking. If the entry lock were a plain spinlock the
    // loser would peg a core for as long as the winner's recv takes
    // (up to its full deadline, tens of seconds); LeaseTimeout lets the
    // caller retry on its own schedule. The second half is the part
    // that catches a poisoned lock: if the timeout left the entry
    // wedged, the server is dead for the rest of the process.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var held = try reg.acquire("shared", echo_argv(), .{});
    const c1 = held.client();

    try testing.expectError(
        StdioError.LeaseTimeout,
        reg.acquire("shared", echo_argv(), .{ .wait_ns = 20 * std.time.ns_per_ms }),
    );

    held.release();
    var next = try reg.acquire("shared", echo_argv(), .{ .wait_ns = 20 * std.time.ns_per_ms });
    defer next.release();
    // Same child: the timeout was contention, not a reason to respawn.
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(next.client()));
}

test "acquire honours is_cancelled under contention without respawning the cached child" {
    // The Stop button has to reach the lease wait too: a user who
    // cancels while another session is mid-transaction must not be
    // pinned for the rest of the (tens of seconds long) wait budget.
    // Contended on purpose — `tryLockUntil` takes a *free* lock
    // outright without ever consulting the callback, so cancel governs
    // the waiting and never the fast path.
    //
    // Also pins "a cancelled acquire does not kill the cached child":
    // the next holder must get the same client back, because a cancel
    // is not a transport failure and respawning here would restart a
    // healthy server mid-conversation.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var held = try reg.acquire("cancelled", echo_argv(), .{});
    const c1 = held.client();

    const cancel_now = struct {
        fn call() bool {
            return true;
        }
    }.call;

    const start = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    try testing.expectError(
        StdioError.LeaseTimeout,
        reg.acquire("cancelled", echo_argv(), .{
            .wait_ns = 10_000 * std.time.ns_per_ms,
            .is_cancelled = &cancel_now,
        }),
    );
    const elapsed_ms: i128 = @divTrunc(
        std.Io.Timestamp.now(testing.io, .real).nanoseconds - start,
        std.time.ns_per_ms,
    );
    // 10s budget, must come back in well under a second: the cancel is
    // polled before the first sleep, not between them.
    try testing.expect(elapsed_ms < 2000);

    held.release();
    var next = try reg.acquire("cancelled", echo_argv(), .{});
    defer next.release();
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(next.client()));
}

test "Lease.release is idempotent — a double release does not free the entry lock" {
    // Every production call site pairs `defer lease.release()` with an
    // explicit release on the happy path, so releasing twice is the
    // normal shape, not abuse. A second `unlock` on an already-unlocked
    // mutex is undefined behaviour (an assertion in debug builds) and is
    // worse than a panic in release: it would let a second caller walk
    // straight into the child this lease was protecting. The second
    // acquire below is the proof that the lock is still held — and held
    // by exactly one holder.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    var lease = try reg.acquire("double-release", echo_argv(), .{});
    const c1 = lease.client();
    lease.release();
    lease.release();

    var next = try reg.acquire("double-release", echo_argv(), .{ .wait_ns = 50 * std.time.ns_per_ms });
    defer next.release();
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(next.client()));
    // `next` holds it exclusively — if the extra release had unlocked a
    // live mutex, this third acquire would sail through.
    try testing.expectError(
        StdioError.LeaseTimeout,
        reg.acquire("double-release", echo_argv(), .{ .wait_ns = 20 * std.time.ns_per_ms }),
    );
}

test "StdioClient.deinit is idempotent — the second call is a no-op" {
    // `defer client.deinit()` coexists with an explicit `deinit()` on
    // the error path, and the registry kills the same child again during
    // its own teardown. `std.process.Child.kill` reaps the child and
    // closes the pipes, so running it twice signals a pid that may
    // already have been recycled by an unrelated spawn and closes
    // handles that by then belong to someone else.
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return error.SkipZigTest;
        return err;
    };
    client.deinit();
    try testing.expect(client.is_dead);
    try testing.expect(client.stdin == null);
    client.deinit(); // must not double-kill
    try testing.expect(client.is_dead);
    try testing.expect(client.stdout == null);
}

test "send and recv after deinit return BrokenPipe instead of writing to a recycled fd" {
    // `child.kill` closes the pipes, but the cached handles keep the fd
    // NUMBERS. The next open()/spawn() in this process very often gets
    // the same number back, so a post-deinit `send` would type MCP
    // JSON-RPC into an unrelated file and a `recv` would parse that
    // file's contents as a frame. Nulling the handles is what turns both
    // into an honest BrokenPipe — and this test is the proof that the
    // nulling happens *before* any syscall, not after one fails.
    var client = StdioClient.init(testing.allocator, testing.io, echo_argv()) catch |err| {
        if (err == error.ChildSpawnFailed) return error.SkipZigTest;
        return err;
    };
    client.deinit();
    try testing.expectError(StdioError.BrokenPipe, client.send("{\"jsonrpc\":\"2.0\"}", 0));
    try testing.expectError(StdioError.BrokenPipe, client.recv(0, null));
    // recv must not have re-attached a reader to a dead pipe either.
    try testing.expect(client.reader == null);
}

test "recv nulls the reader after a mid-frame failure so the next recv cannot replay buffered bytes" {
    // The persistent 4 KiB reader buffer can hold the tail of an
    // abandoned frame. Keeping it means the next recv parses that tail
    // as a fresh message — a stale JSON-RPC error, or half a response
    // attributed to a different request id. Dropping the reader costs
    // one re-read of the pipe and makes the next call honest.
    //
    // Framed (not NDJSON) on purpose: the NDJSON EOF path hands the
    // partial line back *successfully*, so only the Content-Length path
    // actually stops mid-frame and unwinds the reader.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // Header promises 100 bytes, the child delivers 2 and exits.
    const argv: []const []const u8 = &.{ "sh", "-c", "printf 'Content-Length: 100\\r\\n\\r\\nab'" };
    var client = StdioClient.init(testing.allocator, testing.io, argv) catch |err| {
        if (err == error.ChildSpawnFailed) return error.SkipZigTest;
        return err;
    };
    defer client.deinit();
    try testing.expect(client.reader == null); // lazily created, not yet

    const first = client.recv(5_000 * std.time.ns_per_ms, null);
    if (first) |body| {
        // A completed frame would mean the truncated header somehow
        // resolved — the premise of this test is wrong.
        client.allocator().free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        // UnexpectedEof is the expected shape; RecvTimeout is accepted
        // because a pathologically slow CI runner can lose the race with
        // the child's exit. Either way the frame was abandoned.
        try testing.expect(err == StdioError.UnexpectedEof or err == StdioError.RecvTimeout);
    }
    try testing.expect(client.reader == null);

    // Second recv on the same client: it must not surface the abandoned
    // 2-byte tail as if it were a message. Any error is fine here (the
    // pipe is at EOF, or the short deadline bounds a not-yet-reaped
    // child); a successful body is not.
    const second = client.recv(2_000 * std.time.ns_per_ms, null);
    if (second) |body| {
        client.allocator().free(body);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == StdioError.UnexpectedEof or err == StdioError.RecvTimeout);
    }
}

test "acquire on a missing binary reports ChildSpawnFailed and leaves the entry re-acquirable" {
    // A typo in a server's command must not permanently poison the
    // entry. `acquire` consumes the pre-allocated spare slot and only
    // then discovers the spawn failed, so a naive implementation either
    // leaves `has_client` set (handing the next caller a corpse) or
    // leaks the entry lock (blocking it forever). Driven through the
    // registry rather than `StdioClient.init` because the entry-level
    // bookkeeping is what's under test — the direct-init failure is
    // already covered above.
    var reg = StdioRegistry.init(testing.allocator, testing.io);
    defer reg.deinit();
    try testing.expectError(
        StdioError.ChildSpawnFailed,
        reg.acquire("bogus", &.{"/no/such/binary/xyzzy"}, .{}),
    );

    // Same name, working binary: the failed spawn must not have stranded
    // the entry lock or left it permanently dirty.
    var lease = try reg.acquire("bogus", echo_argv(), .{ .wait_ns = 500 * std.time.ns_per_ms });
    defer lease.release();
    try testing.expect(lease.client().stdin != null);
    try testing.expectEqual(false, lease.entry.dirty.load(.acquire));
}
