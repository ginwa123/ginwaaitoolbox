# Zig 0.16 — User-Space Deadlines Cannot Interrupt Blocking Socket Reads (and SO_RCVTIMEO Panics)

`std.Io.Threaded` schedules I/O on a worker thread that calls the kernel's
blocking `recv()`. A deadline check on the main thread is **dead code** for that
path — the worker is parked in the kernel until the socket returns
(RST/FIN/error/data/timeout).

## Symptom

You add a `read_loop_deadline` field, track `elapsed_ms` in the loop, and check
`if (elapsed > deadline) return error.Timeout`. The check never fires when the
remote side silently stalls. The unit tests for the deadline logic pass (no
real network). The integration test hangs forever.

## Why

- `std.Io.Threaded`'s vtable for stream reads dispatches to a worker thread.
- The worker calls `recv(fd, buf, len, 0)` on a blocking socket.
- If the kernel has no data, the worker is parked in `recv()` until the kernel
  decides to return (RST, FIN, error, or the per-socket `SO_RCVTIMEO` fires).
- The main thread is `await`ing the worker's completion. The user's deadline
  check is in a loop that runs AFTER `readSliceShort` returns — but
  `readSliceShort` never returns, so the loop body never runs.

## The `SO_RCVTIMEO` "fix" DOES NOT WORK with `std.Io.Threaded`

The old advice (this file, pre-2026-06-11) said to set `SO_RCVTIMEO` and catch
`EAGAIN` in the read loop. **That's wrong for this codebase.** Verified in
`/usr/local/lib/zig/std/Io/Threaded.zig:14054-14057`:

```zig
pub fn errnoBug(err: posix.E) Io.UnexpectedError {
    if (is_debug) std.debug.panic("programmer bug caused syscall error: {t}", .{err});
    return error.Unexpected;
}
```

And the `netReadPosix` switch at line 12615-12635:

```zig
.INVAL => |err| return errnoBug(err),
.FAULT => |err| return errnoBug(err),
.AGAIN => |err| return errnoBug(err),           // ← panic in debug, error.Unexpected in release
.BADF => |err| return errnoBug(err),
.NOBUFS => return error.SystemResources,
.NOMEM => return error.SystemResources,
.NOTCONN => return error.SocketUnconnected,
.CONNRESET => return error.ConnectionResetByPeer,  // ← THE ONE SAFE PATH
.TIMEDOUT => return error.Timeout,
.PIPE => return error.SocketUnconnected,
.NETDOWN => return error.NetworkDown,
```

So in this version of `std.Io.Threaded`:
- `EAGAIN` (from `SO_RCVTIMEO`) → **panic in debug, `error.Unexpected` in release**
- `EAGAIN` is treated as a "programmer bug" because the runtime expects blocking
  sockets to never return `EAGAIN`. `SO_RCVTIMEO` violates this contract.

**The only safe "recv returned early" errors are** `ECONNRESET` (via TCP
keepalive), `ETIMEDOUT` (via connect-timeout), `ENOTCONN`/`EPIPE`,
`ENOBUFS`/`ENOMEM`, `ENETDOWN`. Everything else is a programmer error.

## The Actual Fix: Aggressive TCP Keepalive

Set `TCP_KEEPIDLE` / `TCP_KEEPINTVL` / `TCP_KEEPCNT` on the client socket via
`std.posix.setsockopt`. When the OS detects a dead connection (after the
configured idle window + probes), it sends RST, the client gets `ECONNRESET`,
the Io maps it to `error.ConnectionResetByPeer`, and the read loop returns
`error.ReadFailed`.

```zig
const keepidle: c_int = 2;
std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPIDLE,
    std.mem.asBytes(&keepidle)) catch {};

const keepintvl: c_int = 2;
std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPINTVL,
    std.mem.asBytes(&keepintvl)) catch {};

const keepcnt: c_int = 2;
std.posix.setsockopt(sock, std.posix.SOL.IPPROTO.TCP, std.posix.TCP.KEEPCNT,
    std.mem.asBytes(&keepcnt)) catch {};
```

Total detection time: `keepidle + keepintvl * keepcnt` = 2 + 2*2 = 6s.

**Limitation:** on loopback (e.g., the FakeServer in `call_streaming_test.zig`),
the peer kernel is always alive and ACKs the keepalive probes, so the keepalive
never fires. To verify the dead-conn detection path in tests, the FakeServer
must actually `close()` the socket — the close triggers `ECONNRESET` on the
client, which exercises the same code path. (See
`call_streaming_test.zig`'s `head_only_then_stall` and `one_chunk_then_stall`
tests for the working pattern.)

## When This Bites

- Any network code that wants to detect "peer went silent" (network drop,
  half-open TCP, server crashed without closing the socket).
- LLM streaming clients where the upstream can stall between chunks.
- Long-polling clients where you need a "got data within N seconds" guarantee.
- Tests for any of the above — they hang silently with no timeout.

## How to Test for This

- Test with a fake server that `accept()`s, sends the head, sleeps briefly
  (1-2s), then `close()`s. The close triggers `ECONNRESET` on the client,
  which the read loop's `error.ReadFailed` branch maps to
  `error.StreamInterrupted`. The test should complete in seconds, not hang.
- **Do not** try to test the keepalive on loopback — the server's kernel
  always ACKs the probes, so the keepalive never fires. Use a non-loopback
  IP (or a real network) to exercise the actual keepalive timeout.
- Always verify both: (1) the keepalive values are applied (grep for the
  log line that prints them), and (2) the FakeServer-driven close path
  produces the expected error variant.
