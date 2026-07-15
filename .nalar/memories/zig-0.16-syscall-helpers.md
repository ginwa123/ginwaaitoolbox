# Zig 0.16 — std.posix No Longer Exposes Common Syscall Wrappers

In Zig 0.16, `std.posix.socket/bind/listen/accept/connect/recv/send/close` are **not public functions**. They live in `std.os.linux.*` (or `std.os.windows.*`, `std.os.darwin.*` etc.) and return a raw `usize`:
- On success: a non-negative value (fd for socket/accept, byte count for recv/write, 0 for close, etc.)
- On failure: a value > `std.math.maxInt(i32)` — i.e. the negation of errno, encoded as `usize`

The `errno()` helper inside `posix.zig` is private, so you can't reuse it.

## The pattern

```zig
const fd_rc = std.os.linux.socket(
    std.os.linux.AF.INET,
    std.os.linux.SOCK.STREAM,
    0,
);
if (fd_rc > std.math.maxInt(i32)) return error.SocketFailed;
const fd: i32 = @intCast(fd_rc);
defer _ = std.os.linux.close(fd);
```

`@intCast` from `usize` to `i32` works because the success fd fits in i32 (fds are ≤ 65535 on every realistic platform) and the error path has already been rejected.

## Other related removals

- **`std.Thread.sleep(ns)` is gone** — use `std.c.nanosleep(&std.posix.timespec{ .sec = ..., .nsec = ... }, null)`.
- **`std.fs.accessAbsolute(path, .{})` is gone** — use libc `faccessat(AT_FDCWD, path, mode, 0)` directly via `@cImport` or `std.c.faccessat`.
- **`std.fs.File.createFileAbsolute` / `writeFileAbsolute` may have signature changes** — verify by compiling a minimal test.

## The `Io.Threaded` non-blocking socket problem

`std.Io.Threaded` opens sockets **non-blocking** internally. This is fine for long-lived HTTP streams (the Io's `readVec`/`writeVec` loops on `EAGAIN`) but **breaks one-shot probes** like a TCP health check:

1. Client `connect()` returns as soon as SYN/ACK completes — before the server's `accept()` has run.
2. Client calls `readSliceShort`; the kernel has the connection in the server's accept queue but no data in the receive buffer.
3. `readv()` returns `EAGAIN` (no data on a non-blocking socket).
4. The Io's `netReadPosix` maps `EAGAIN` to an error, not "block until data".
5. `readSliceShort` returns the error to the caller.

**Fix for one-shot probes:** use raw blocking syscalls with `SO_RCVTIMEO` for the per-call deadline. This gives "block until response or 1s" semantics that match the use case:

```zig
const fd = std.os.linux.socket(...);
const rcvtimeo = [_]u8{ 0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0 }; // {tv_sec=1, tv_usec=0} little-endian
_ = std.os.linux.setsockopt(fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.RCVTIMEO, &rcvtimeo, 16);
// now read() will block for up to 1s
```

The `struct timeval` is 16 bytes: 4 bytes `tv_sec` (little-endian) + 4 bytes `tv_usec` (little-endian) = 8 bytes per field × 2 fields = 16 bytes total.

## Multi-threaded `Io.Threaded` doesn't work

`std.Io.Threaded` does **not** support multiple threads awaiting on the same Io runtime. If you spawn a thread that does `io.run()` and the main thread also calls `io.async(...)`, they race. The thread-safe pattern is:

- **Thread 1** (e.g. server): uses **raw syscalls** (`std.os.linux.*`), no Io runtime at all.
- **Main thread**: uses the Io runtime for client-side operations.

Mixed `Io.Threaded` + raw-syscall thread is the cleanest pattern for "spin up a tiny mock server in a test thread" — see `src/apps/desktop_app/subprocess_test.zig` for the working example.

## When This Bites

- Any new code that spawns subprocesses with `std.process.spawn` and needs to interact via TCP/HTTP
- One-shot TCP probes (health checks, banner checks, etc.)
- Test code that needs a mock server
- Path resolution that needs `access(2)` (use `faccessat`)

## How to verify

If you see a 0.16 codebase hanging on a TCP health check, the cause is almost always the non-blocking Io socket + one-shot probe mismatch. Switch to raw syscalls with `SO_RCVTIMEO` and the hang goes away.
