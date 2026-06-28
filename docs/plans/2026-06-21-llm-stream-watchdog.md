# LLM Stream Watchdog — Force-Close Socket on Idle/Max Timeout

**Date:** 2026-06-21
**Author:** Follow-up to the `2026-06-21 10:08` investigation report
**Scope:** Single file (`src/modules/agent/Agent.zig`) + its regression test
**Risk:** Low (additive, isolated to one read loop)

---

## Problem (recap)

`callStreaming` at `src/modules/agent/Agent.zig:1166-1522` reads chunks via
`reader.readSliceShort(...)` at `Agent.zig:1359`. On `std.Io.Threaded`, that
read dispatches to a worker thread which is parked in the kernel's blocking
`recv()`. The user-space deadline checks at `Agent.zig:1406-1430` only run
**after** `readSliceShort` returns — so when the upstream stalls silently
(no RST, no FIN, no data, no keepalive probe ACK), the worker is stuck in
`recv()` indefinitely and no error is ever surfaced to the caller.

TCP keepalive (`apply_tcp_keepalive` at `Agent.zig:793-823`, ~25s detection
window) is the only current escape, and the project memory
`zig-socket-deadlines.md` documents that keepalive does NOT fire on loopback
because the peer kernel always ACKs the probes. Three regression tests in
`src/modules/agent/call_streaming_test.zig:252-277` are therefore
explicitly skipped with `error.SkipZigTest`.

`SO_RCVTIMEO` is intentionally avoided (see `Agent.zig:790-792` comment) —
in Zig 0.16's `std.Io.Threaded`, `EAGAIN` from `recv()` is mapped to
`errnoBug` which panics in debug and returns `error.Unexpected` in release
(verified at `/usr/local/lib/zig/std/Io/Threaded.zig:14054-14057`).

## Fix

Spawn a lightweight **watchdog thread** alongside the read loop. The
watchdog wakes every ~250 ms, checks elapsed idle / total time, and when a
budget is exceeded it `close()`s the underlying socket fd from outside the
Io runtime. The Io worker's `recv()` then returns an error (typically
`EBADF` or `ECONNRESET`), the existing error handler at
`Agent.zig:1360-1380` maps it to `error.StreamInterrupted`, and the read
loop exits cleanly.

This is the surgical option (b) from the report's closing analysis. It:

- keeps the existing `std.Io.Threaded` HTTP path unchanged,
- keeps the existing user-space deadline checks as a fast-path (still useful
  for cases where the kernel returns promptly),
- does NOT depend on `SO_RCVTIMEO` (no `EAGAIN`/`errnoBug` risk),
- works on loopback (the watchdog closes the fd directly, bypassing the
  kernel's keepalive ACK loop).

---

## 1. Watchdog struct (new, private to `Agent.zig`)

A small private struct near the existing helpers (placed just after
`apply_tcp_keepalive` at `Agent.zig:823`):

```zig
/// Background thread that force-closes the stream socket when the
/// read loop stalls. Works around the std.Io.Threaded "parked in recv()"
/// problem: the user-space deadline checks in the read loop never fire
/// while the worker is blocked in the kernel. The watchdog closes the
/// fd from outside the Io runtime, which makes recv() return an error
/// and the existing error path returns StreamInterrupted / StreamIdleTimeout.
const StreamWatchdog = struct {
    fd: std.atomic.Value(i32),                  // live socket fd; -1 when cancelled
    last_byte_ms: std.atomic.Value(i64),        // wall-clock ms of last received byte
    cancel: std.atomic.Value(bool),             // set by main thread on exit
    fired_for: std.atomic.Value(u8),            // 0=none, 1=idle, 2=max_total
    thread: std.Thread,
    start_ms: i64,
    idle_timeout_ms: i64,
    max_total_ms: i64,

    const Reason = enum(u8) { none = 0, idle = 1, max_total = 2 };

    fn threadMain(wd: *StreamWatchdog) void {
        // Wake every ~250ms. Check cancel, then total, then idle.
        // On timeout: close(fd), set fired_for, exit.
        // On cancel: exit.
        while (true) {
            std.c.nanosleep(&.{ .sec = 0, .nsec = 250 * std.time.ns_per_ms }, null);
            if (wd.cancel.load(.acquire)) return;
            const now = wallClockMs();
            const fd_now = wd.fd.load(.acquire);
            if (fd_now < 0) return;
            if (now - wd.start_ms >= wd.max_total_ms) {
                wd.fired_for.store(@intFromEnum(Reason.max_total), .release);
                _ = std.os.linux.close(fd_now);  // ignore EBADF (already closed)
                return;
            }
            if (now - wd.last_byte_ms.load(.acquire) >= wd.idle_timeout_ms) {
                wd.fired_for.store(@intFromEnum(Reason.idle), .release);
                _ = std.os.linux.close(fd_now);
                return;
            }
        }
    }

    fn wallClockMs() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @intCast(ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
    }
};
```

### Notes on the design

- **`std.c.nanosleep` + `std.c.clock_gettime`** — the watchdog must NOT use
  `std.Io.sleep` or the Io's time accessor: the Io is busy doing HTTP I/O.
  Both are raw libc syscalls, safe to call from any thread.
- **`std.os.linux.close`** — matches the project's existing pattern of using
  `std.os.linux.*` raw syscall wrappers (see `apply_tcp_keepalive` at
  `Agent.zig:800-820` which uses `std.posix.setsockopt`). Returns `void`,
  never throws.
- **`std.atomic.Value`** — Zig 0.16 supports `load(.acquire)` / `store(...,
  .release)` on `Value(T)`. The cross-thread fence is enough for the
  watchdog's small critical section.
- **`EBADF` is ignored** — if the main thread raced ahead and the Io already
  closed the fd (e.g., normal completion), the watchdog's `close` is a
  no-op. We do not care about double-close; the kernel returns EBADF and we
  ignore it.
- **Single-file scope** — kept inline in `Agent.zig` rather than extracted
  to `Watchdog.zig` because (a) only `callStreaming` uses it and (b) it
  shares the `std.posix` socket-fd conventions of `apply_tcp_keepalive`
  immediately above it.

## 2. Plumbing the fd out of `apply_tcp_keepalive`

`apply_tcp_keepalive` currently discards the fd after applying the
keepalive options. Change the signature so callers can recover it:

```zig
fn apply_tcp_keepalive(req: anytype) !i32 {
    const sock = req.connection.?.stream_reader.stream.socket.handle;
    // ... existing setsockopt calls unchanged ...
    return sock;
}
```

Return type is `!i32` (can fail if the connection is missing — keep the
existing failure path). Existing single caller at `Agent.zig:1237` is
updated to capture the return:

```zig
const stream_fd = try apply_tcp_keepalive(&req);
```

## 3. Wire the watchdog into `callStreaming`

Three integration points, all in `src/modules/agent/Agent.zig`:

### 3a. Spawn (just after `apply_tcp_keepalive`, before the read loop)

Insert after `Agent.zig:1237` (currently the `apply_tcp_keepalive(&req)`
call), before `Agent.zig:1241-1246` (the `req.receiveHead(...)` call):

```zig
const stream_fd: i32 = try apply_tcp_keepalive(&req);

const wd_start_ms = StreamWatchdog.wallClockMs();
var watchdog: StreamWatchdog = .{
    .fd = std.atomic.Value(i32).init(stream_fd),
    .last_byte_ms = std.atomic.Value(i64).init(wd_start_ms),
    .cancel = std.atomic.Value(bool).init(false),
    .fired_for = std.atomic.Value(u8).init(0),
    .thread = undefined,  // assigned below
    .start_ms = wd_start_ms,
    .idle_timeout_ms = @intCast(self.httpOptions.idle_timeout_ms),
    .max_total_ms = @intCast(self.httpOptions.read_timeout_ms),
};
watchdog.thread = try std.Thread.spawn(.{}, StreamWatchdog.threadMain, .{&watchdog});
```

### 3b. Bump `last_byte_ms` on each chunk received

In the read loop, the line `const n = reader.readSliceShort(read_buffer[0..])`
at `Agent.zig:1359` is followed by an `n > 0` branch. Add a single line:

```zig
if (n > 0) {
    watchdog.last_byte_ms.store(StreamWatchdog.wallClockMs(), .release);
    // ... existing chunk-processing code unchanged ...
}
```

### 3c. Cancel + join on every exit path

There are ~7 `return` statements inside the read loop (success, all error
variants). Rather than add `defer` at each site, use a single `defer` at the
top of the read loop that fires once:

```zig
defer {
    watchdog.cancel.store(true, .release);
    watchdog.thread.join();
    // Map watchdog's fire-reason onto the error variant if the read
    // loop didn't already return its own error.
}
```

The defer runs on every exit (normal, `StreamTimeout`, `StreamIdleTimeout`,
`StreamInterrupted`, parse error, anything). After join, we read
`watchdog.fired_for`:

- If `fired_for == 2` (max_total) AND the function would otherwise return
  success, translate to `error.StreamTimeout`.
- If `fired_for == 1` (idle) AND the function would otherwise return
  success, translate to `error.StreamIdleTimeout`.

In practice the watchdog firing **also** causes the read loop to error
(returning `error.StreamInterrupted` from the existing path), so the
translation rarely fires — but it's there for defense in depth and to
preserve the original error semantics where possible.

### 3d. Reset fd on cancel

If the read loop errors out, the Io runtime will close the fd itself. The
watchdog's atomic fd may still point at the (now closed) fd. Set it to -1
in the defer:

```zig
defer {
    watchdog.fd.store(-1, .release);  // tell watchdog "fd is gone"
    watchdog.cancel.store(true, .release);
    watchdog.thread.join();
}
```

The watchdog's loop checks `if (fd_now < 0) return;` after each sleep, so
it exits cleanly.

## 4. Unskip the 3 existing regression tests

`src/modules/agent/call_streaming_test.zig:252-277` currently has 3 tests
that all return `error.SkipZigTest`. With the watchdog in place they should
now actually pass:

- The "stalls after head" test → watchdog fires on idle → read loop returns
  `error.StreamInterrupted` (or `error.StreamIdleTimeout` if we map the
  fired_for reason).
- The "stalls after one chunk" test → same path.
- The "stalls after a few chunks" test → same path.

**Adjust the assertions**: the existing tests assert specific error
variants (`error.StreamIdleTimeout`, `error.StreamTimeout`). Update each to
accept either the original variant OR `error.StreamInterrupted`, since the
watchdog may force-close via the `error.ReadFailed` path before the
user-space deadline check fires.

**Adjust the timeouts**: the tests currently configure 60-second idle /
300-second total. Drop these to 200 ms / 5000 ms so the tests complete
quickly. The watchdog wakes every 250 ms, so detection is ~200-500 ms
after the budget expires — well under the default test timeout.

## 5. Add 2 new tests for the watchdog specifically

In `src/modules/agent/call_streaming_test.zig`:

1. **`watchdog returns within ~1s of idle_timeout`** — server sends head,
   stalls; idle_timeout=500ms; assert that `callStreaming` returns within
   `[500ms, 1500ms]`. Uses a wall-clock measurement (`std.time.timestamp`).

2. **`watchdog cancels cleanly on normal completion`** — server sends head
   + a complete stream (with `finish_reason: "stop"`); assert
   `callStreaming` returns `null` (success) in normal time, AND the
   watchdog thread is joined (no thread leak). Assert by reading the
   watchdog's `cancel` and `fired_for` after the call (would require
   exposing them, or using a side channel — see "Open question" below).

## 6. Files to modify

| File | Change | LoC delta |
|---|---|---|
| `src/modules/agent/Agent.zig` | Add `StreamWatchdog` struct (~50 LoC); spawn/cancel/join in `callStreaming` (~15 LoC); `apply_tcp_keepalive` returns fd (~3 LoC changed) | **+65 / -3** |
| `src/modules/agent/call_streaming_test.zig` | Unskip 3 existing tests, adjust assertions and timeouts (~10 LoC); add 2 new watchdog tests (~60 LoC) | **+70 / -10** |

No new files. No new modules. No migration. No API surface change for
callers of `callStreaming` — the existing `CallError` set is unchanged.

## 7. Verification

1. **Type-check** the production binary:
   ```
   timeout 180 zig build install:linux:system 2>&1 | tail -n 15
   ```
   Expect: `compile exe nalar` succeeds; the harmless `/usr/local/bin/nalar`
   cp fails with permission denied (pre-existing).

2. **Test suite**:
   ```
   timeout 180 zig build test --summary all 2>&1 | tail -n 5
   ```
   Expect: test count goes up by +2 (the 3 un-skipped tests replace 3
   `SkipZigTest` returns, which already counted; the 2 new ones add 2).

3. **Manual smoke** (optional, on port 8080):
   ```
   ./zig-out/bin/nalar --port 8080 &
   # Send a streaming chat message, then `kill -STOP <nalar-pid>` mid-stream
   # and confirm the client returns StreamInterrupted within ~30s
   # (idle_timeout default is 60s, keepalive is 25s — whichever fires first).
   kill <pid>
   ```

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Watchdog thread leaks if `cancel` is never set | Use a `defer` at the top of the read loop that always runs (normal + error paths). Tested by the "cancels cleanly on normal completion" new test. |
| `close()` race with the Io runtime closing the fd | `close()` on a closed fd returns EBADF harmlessly. The atomic fd reset to -1 before cancel is a defense in depth. |
| Wall-clock drift between watchdog and main thread | Both use `CLOCK_MONOTONIC`, so no wall-clock issues. The watchdog measures idle/timeout from its own reads, not from a main-thread-provided timestamp. |
| Watchdog fires while the response is being parsed in `parseSseLine` | The close happens at the kernel level; the in-progress parse completes normally (it operates on already-buffered bytes). The NEXT read attempt sees the closed fd. No data corruption. |
| Existing 60s / 300s defaults cause user-visible behavior change | Defaults are unchanged. The watchdog fires at the SAME deadlines as the existing user-space checks would. Users with non-default `HttpOptions` see the same deadlines enforced more reliably. |
| Memory leak in `StreamWatchdog` struct fields | All fields are atomic values or POD; no allocation. `std.Thread.spawn` allocates the thread stack but `join()` releases it. |

## 9. Open question (resolved during impl)

> "Should `watchdog.fired_for` be checked after the read loop to translate
> `error.StreamInterrupted` back into `error.StreamIdleTimeout` /
> `error.StreamTimeout` when the watchdog was the trigger?"

**Decision: yes**, because the LLM-call wrapper at `workflow.zig` may want
to distinguish "I killed the stream because it was idle" from "the
connection died". Implement the check in the `defer` block of `callStreaming`
— if `fired_for != 0` AND the read loop's `n` was 0 (no data after the
trigger), AND no other error has been set, return the timeout variant.

This is a small additional check; see implementation note in §3c.

## 10. What this plan does NOT do

- Does NOT switch to `SO_RCVTIMEO`. The project memory
  `zig-socket-deadlines.md` documents this is unsafe with
  `std.Io.Threaded`. The watchdog is the correct workaround.
- Does NOT change the `std.Io.Threaded` usage in production. The
  `src/main.zig:18` `init.io` is still the threaded Io.
- Does NOT add a new error variant. The existing `StreamTimeout`,
  `StreamIdleTimeout`, `StreamInterrupted` set covers all cases.
- Does NOT touch `src/modules/http/HttpClient.zig` (separate curl-based
  HTTP wrapper, unrelated to LLM streaming).
- Does NOT change `apply_tcp_keepalive`'s keepalive values. The watchdog
  is purely additive — keepalive remains as a slower secondary defense.