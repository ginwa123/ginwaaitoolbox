---
name: zig016-drive-std-tls-client-over-fd
description: "How to drive Zig 0.16's std.crypto.tls.Client over a raw socket fd in a test — the Io.Reader/Io.Writer vtable shims it demands, the buffer-size relationships, entropy/clock sources, the two-flush write path, close_notify, and the threading + socket-timeout harness that keeps a broken handshake from hanging the run."
---
---
name: zig016-drive-std-tls-client-over-fd
description: How to drive Zig 0.16's std.crypto.tls.Client over a raw socket fd in a test — the Io.Reader/Io.Writer vtable shims it demands, the buffer-size relationships, entropy/clock sources, the two-flush write path, close_notify, and the threading + socket-timeout harness that keeps a broken handshake from hanging the run.
tags: [zig, zig-0.16, tls, testing, std-io, ffi]
---

## When to Use

Writing tests that drive a **real TLS client** through a socket (your own TLS
server, a TLS proxy, a record layer). Also use it whenever you need a
`std.Io.Reader`/`std.Io.Writer` over a raw fd, or when a Zig 0.16 test needs
entropy or wall-clock time.

## Context

* Zig 0.16 reworked both TLS (`std.crypto.tls.Client`) and I/O (`std.Io.Reader` /
  `std.Io.Writer` with vtables). The client takes `*Reader`/`*Writer` plus buffers,
  entropy and `realtime_now` — it does **not** take a socket or a `net.Stream`.
* `std.crypto.tls.Client` has **no ALPN support at all** (zero `alpn` hits in
  `/usr/lib/zig/std`). If the test needs ALPN, drive the other side with OpenSSL
  (`TLS_client_method` plus `SSL_set_alpn_protos`) — see the
  `openssl-c-bindings-from-zig016` skill.
* `std.testing.io` is initialised by the compiler's own `test_runner.zig`, so it
  works under a plain `zig test FILE.zig` (no hand-rolled runner needed).
* Socket I/O on the *client* side of the test must be POSIX-only in this repo:
  `std.c.read`/`std.c.write` are POSIX declarations (Windows UCRT exposes
  `_read`/`_write`), and the module's Windows socketpair yields winsock SOCKETs
  the C runtime fd table cannot read.

## Procedure

1. **Local socketpair.** `zig test FILE.zig` restricts imports to that file's
   directory, so a test file under `src/MOD/src/http2/` cannot
   `@import("../test_helpers.zig")` (fails: "import of file outside module
   path"). Inline a dozen lines instead:
   ```zig
   fn createPair() ![2]i32 {
       var fds: [2]std.posix.fd_t = undefined;
       if (std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, fds_ptr) < 0)
           return error.SocketPairFailed;
       return .{ fds[0], fds[1] };
   }
   ```
2. **Give the pair a timeout** (`setsockopt` with `SO_RCVTIMEO`/`SO_SNDTIMEO`,
   10 s) so a logic error becomes a test failure instead of a hung suite
   (`zig test` has no watchdog).
3. **Write the Reader shim** — `stream` alone is enough; the default `readVec`
   drives it:
   ```zig
   fn init(fd: i32, buffer: []u8) SocketReader {
       return .{ .fd = fd, .interface = .{
           .vtable = VTABLE, .buffer = buffer, .seek = 0, .end = 0 } };
   }
   fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
       const self: *SocketReader = @fieldParentPtr("interface", r);
       const dest = limit.slice(try w.writableSliceGreedy(1));
       const n = readFd(self.fd, dest) catch return error.ReadFailed;
       if (n == 0) return error.EndOfStream;   // 0 bytes on a stream == peer closed
       w.advance(n);
       return n;
   }
   ```
4. **Write the Writer shim** mirroring std's socket writer: buffered bytes first,
   then `data[0..len-1]`, then the last slice `splat` times, and hand the total to
   `w.consume(sent)` so `end`/`buffer` bookkeeping stays correct.
5. **Buffers** (mirroring `std/http/Client.zig`, which is the working reference):
   * socket reader buffer at least `Client.min_buffer_len` (the client asserts
     this, then calls `input.rebase(max_ciphertext_record_len)`),
   * socket writer buffer at least `Client.min_buffer_len` (the client calls
     `output.writableSliceGreedy(min_buffer_len)`),
   * `options.read_buffer` at least `min_buffer_len`; `options.write_buffer` can
     be about 1 KiB.
6. **Options**:
   ```zig
   var entropy: [Client.Options.entropy_len]u8 = undefined;
   testing.io.random(entropy_ptr);                    // std.crypto.random is GONE in 0.16
   var client = try Client.init(reader_iface, writer_iface, .{
       .host = .no_verification, .ca = .no_verification,
       .read_buffer = decrypted_buffer, .write_buffer = plaintext_buffer,
       .entropy = entropy_ptr,
       .realtime_now = std.Io.Clock.real.now(testing.io),   // std.time.nanoTimestamp is GONE
   });
   ```
7. **Writes need TWO flushes**: `client.writer.writeAll(bytes)` then
   `client.writer.flush()` (encrypts into the socket writer's buffer) **and then**
   `socket_writer.interface.flush()` (hits the wire). Forgetting the second looks
   exactly like a deadlock.
8. **Clean close**: `client.end()` (writes close_notify) then flush the socket
   writer. The server side must then see a clean EOF, not a truncation error.
9. **Thread it**: the fds are blocking, so run the client in
   `std.Thread.spawn(.{}, Task.run, .{task_ptr})` and the server handshake on the
   test thread. Make the task a struct with `err: ?[]const u8` filled from
   `catch |err| { self.err = @errorName(err); }`, and **always join before
   asserting**.

## Pitfalls

* Missing second flush (step 7) — the classic "it hangs / nothing arrives".
* Buffer too small — a panicked assert inside `Client.init`, not a nice error.
* `_ = param;` inside a `if (comptime windows)` branch of a function whose POSIX
  branch uses the same param is rejected as a **pointless discard**. Use a
  container-level split instead:
  `const socket_io = if (builtin.os.tag == .windows) struct { A } else struct { B };`
  (only the selected branch is analysed at all).
* Reading with `take(n)`/`readSliceAll` needs an exact byte count — know how many
  bytes the peer will send, or read one byte at a time via `fill`/`buffered`.
* If the task's thread errors before the server's accept, the server blocks until
  the socket timeout: keep the timeouts in place and assert on `task.err` *after*
  join so the failure is legible rather than an unexplained stall.

## Verification

* `zig test -lc FILE.zig` green, several runs in a row (handshakes and mtime
  assertions are where flakes hide).
* Also run `-OReleaseSafe` (Debug-only checks hide in release).
* Prove the test is load-bearing: mutate the thing under test (e.g. make the
  ALPN callback pick the wrong protocol) and confirm the expected assertions
  **fail**, then revert. An always-green TLS test is usually an unasserted
  handshake.

