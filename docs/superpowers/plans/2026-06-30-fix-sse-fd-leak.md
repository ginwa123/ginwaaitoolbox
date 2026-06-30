# SSE Manager FD-Leak Cross-Check + Fix

## Status

Draft. Awaiting implementation.

## Context

User reports `ProcessFdQuotaExceeded` in `/tmp/agentic_coding.log`:

```
[ERROR] read_file failed: ProcessFdQuotaExceeded
[ERROR] bash failed: ProcessFdQuotaExceeded
[ERROR] Sub-agent workflow error for 'CodeImplementationAgent': ProcessFdQuotaExceeded
[ERROR] runAgenticMultiStepnew failed: ProcessFdQuotaExceeded
```

Investigation by the user (with a friend's help) shows that a long-running
`nalar` process (PID 3578178, ~11 hours uptime) accumulated **1011 leaked
socket FDs**, leaving only 13 FDs below the `RLIMIT_NOFILE` soft cap of
1024. Any new FD-allocating syscall (accept, socket, pipe, open, fork)
returns `EMFILE`, which the project's HTTP layer maps to
`error.ProcessFdQuotaExceeded`.

The process has since been restarted and currently has only 56 FDs / 0
"orphan" sock FDs / 44 live TCP connections, but the code paths that
produced the leak are still present.

The user's friend identified three issues in
`src/modules/custom_http_server/src/sse_manager.zig`. This plan
**cross-checks every claim against the source**, fixes what is broken,
and adds new findings the friend missed.

## Cross-Check of Friend's Claims

### VERIFIED — line numbers exact, code matches

| Claim | Line | Code |
|---|---|---|
| Poll subscription missing POLL.NVAL | `sse_manager.zig:349` | `events = posix.POLL.IN \| posix.POLL.HUP,` |
| Poll reaping branch missing POLL.NVAL check | `sse_manager.zig:366` | `if (revents & (poll_err \| poll_hup) != 0) {` |
| Poll shards by `id[0] % LOOP_COUNT == loop_id` | `sse_manager.zig:308` | `if (entry.value_ptr.*.id[0] % LOOP_COUNT == loop_id) {` |
| Heartbeat shards by `global_idx % LOOP_COUNT == loop_id` | `sse_manager.zig:416` | `if (global_idx % LOOP_COUNT == loop_id) {` |
| `posix.poll` error swallowed silently | `sse_manager.zig:356` | `_ = posix.poll(poll_fds, heartbeat_ms) catch continue;` |
| Non-SSE branch closes FD | `http_server.zig:297` | `_ = socket.close(fd);` |
| SSE branch transfers FD ownership | `http_server.zig:234-246` | `registerClient(fd)` then `return;` (no close) |

The friend correctly identified the SSE manager as the leak source.

### PARTIALLY WRONG — over-stated effect of heartbeat sharding mismatch

Friend's claim:
> "the same client can be heartbeated multiple times per cycle and also
> skipped multiple times in a row"

Reality: each `it.next()` returns exactly one entry per iteration, and the
`global_idx % LOOP_COUNT` rule covers all 0..LOOP_COUNT-1 residue classes
exactly once. So **every client is heartbeated by exactly one loop per
cycle** — never skipped, never duplicated. The sharding mismatch is a
code-smell (the poll and heartbeat shards disagree on which loop "owns"
a client) but does not by itself cause missed heartbeats.

The real bug is more subtle: see "New findings" below.

### INCOMPLETE — friend missed two issues

#### Finding 1 — TOCTOU use-after-free in `sendHeartbeat`, `broadcast`, `broadcastTyped`

```zig
// sendHeartbeat (line 409-420)
self.lock.lock(self.io) catch unreachable;
var client_ptrs: std.ArrayListUnmanaged(*SseClient) = .empty;
...
var it = self.clients.iterator();
while (it.next()) |entry| {
    client_ptrs.append(self.allocator, entry.value_ptr.*) catch break;
}
self.lock.unlock(self.io);   // <-- lock released

for (client_ptrs.items) |client| {                       // <-- dereferences
    client.last_heartbeat = timestamp();                  //     raw pointers
    if (writeChunkedFrame(client.fd, ping)) |_| {} else |_| {
        dead_ids.append(self.allocator, client.id) catch break;
    }
}
```

Between the lock release and the `for` loop, the poll reaper (running in
another thread) can call `removeClient(id)`, which **frees the SseClient**
via `self.server_allocator.destroy(entry.value)`. The next iteration then
dereferences a freed pointer → heap corruption / crash.

`broadcast` and `broadcastTyped` have the same pattern at lines 460-468
and 487-495 respectively. The user's friend did not flag this.

#### Finding 2 — `last_heartbeat` is updated BEFORE the write, hiding staleness

```zig
// sendHeartbeat line 425-428
for (client_ptrs.items) |client| {
    client.last_heartbeat = timestamp();   // <-- updated unconditionally
    if (writeChunkedFrame(client.fd, ping)) |_| {} else |_| {
        dead_ids.append(self.allocator, client.id) catch break;
    }
}
```

`last_heartbeat` is the field any periodic sweep would consult to detect
stale clients. By updating it BEFORE the write, a failed heartbeat still
records a fresh timestamp — making the sweep blind to that client's
actual staleness. Friend proposed adding a sweep in Step 3 but did not
flag this anti-pattern.

## Implementation

### Change 1 — Fix heartbeat sharding to match poll sharding

`sse_manager.zig:416`:

```zig
// BEFORE
if (global_idx % LOOP_COUNT == loop_id) {

// AFTER
if (entry.value_ptr.*.id[0] % LOOP_COUNT == loop_id) {
```

Rationale: even though the practical effect is small (every client is
still in exactly one loop's slice), having matching sharding is correct
and the cost is zero.

### Change 2 — Subscribe to `POLL.NVAL` and reap on it

`sse_manager.zig:349` and `sse_manager.zig:362-366`:

```zig
// line 349
// BEFORE
.events = posix.POLL.IN | posix.POLL.HUP,
// AFTER
.events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.NVAL,

// lines 362-366 — add poll_nval and update the reaping branch
const poll_nval: u16 = @intCast(posix.POLL.NVAL);
if (revents & (poll_err | poll_hup | poll_nval) != 0) {
    _ = self.removeClientByFd(pfd.fd);
    continue;
}
```

`posix.POLL.NVAL = 0x020` exists on Linux
(`/usr/local/lib/zig/std/os/linux.zig:7439`); the same enum is re-exported
via `posix.POLL` (`posix.zig:110`). Other platforms are not in scope
(nalar is a Linux server). Wrap with `if (is_linux)` if cross-platform
support is needed later.

### Change 3 — Add periodic sweep of stale clients

`sse_manager.zig` — add a `sweepStaleClients` helper, call it at the end
of each `runEventLoop` iteration after the heartbeat.

```zig
/// Sweep clients whose last successful heartbeat is older than
/// `max_stale_ms`. Defensive against any future bug that lets a dead
/// client slip past the poll reaper and the heartbeat reaper.
fn sweepStaleClients(self: *SseManager, max_stale_ms: u64) void {
    const now = timestamp();

    self.lock.lock(self.io) catch unreachable;
    defer self.lock.unlock(self.io);

    var stale_ids: std.ArrayListUnmanaged([16]u8) = .empty;
    defer stale_ids.deinit(self.allocator);

    var it = self.clients.iterator();
    while (it.next()) |entry| {
        const client = entry.value_ptr.*;
        const age_ms = now -| client.last_heartbeat;
        if (age_ms > max_stale_ms) {
            stale_ids.append(self.allocator, client.id) catch break;
        }
    }

    for (stale_ids.items) |id| {
        if (self.clients.fetchRemove(id)) |entry| {
            _ = self.fd_to_id.remove(entry.value.*.fd);
            entry.value.*.deinit();
            self.server_allocator.destroy(entry.value);
        }
    }
}
```

Call from `runEventLoop` after the heartbeat dispatch:

```zig
// after sendHeartbeat(loop_id);
self.sweepStaleClients(heartbeat_ms * 3);
```

Cap at 64 removals per iteration to avoid O(N²) behaviour when many
clients go stale simultaneously (e.g., a server-side rollback).

### Change 4 — Only update `last_heartbeat` on successful write

`sse_manager.zig:425-434`:

```zig
for (client_ptrs.items) |client| {
    // Only update last_heartbeat on a successful write. A failed
    // heartbeat leaves the timestamp stale, so the periodic sweep
    // (Change 3) will catch it on the next iteration.
    if (writeChunkedFrame(client.fd, ping)) |_| {
        client.last_heartbeat = timestamp();
    } else |_| {
        dead_ids.append(self.allocator, client.id) catch break;
    }
}
```

### Change 5 — Add a regression test

`src/modules/custom_http_server/src/sse_chunked_test.zig` is the
registered test file (see `src/root.zig:401` — `sse_manager_test.zig`
is dead in this branch). Add tests there:

1. **`POLL.NVAL reaping closes orphaned FDs`** — register a client
   with a `socketpair` fd, close the kernel side of the pair to make
   the user-space fd invalid, run a single `runEventLoop` iteration
   with a short heartbeat, assert `clientCount() == 0`.

2. **`sweepStaleClients removes clients whose last_heartbeat is old`** —
   register a client with `last_heartbeat = 0`, call `sweepStaleClients(1)`,
   assert `clientCount() == 0`.

3. **`sendHeartbeat updates last_heartbeat only on successful write`** —
   register a client, deliberately close the kernel side of the pair,
   call `sendHeartbeat` (manually), assert `last_heartbeat` did NOT
   advance.

4. **`runEventLoop reaps abruptly-disconnected clients`** — register
   10 clients, close 5 of their kernel-side counterparts, run the
   event loop with heartbeat_secs=0 (no heartbeat), assert the 5
   closed clients are reaped via POLL.NVAL.

All tests use the `std.Io.Threaded` pattern from `sse_chunked_test.zig`
since the production event loops require it.

### Out of scope for this PR

The TOCTOU use-after-free in `sendHeartbeat`, `broadcast`, and
`broadcastTyped` (Finding 1) is a real bug but is unrelated to the FD
leak. Fixing it requires redesigning these functions to either (a)
re-look-up the client under the lock before each write, or (b) hold
the lock for the entire broadcast window. That is a separate
behavioural change with its own review surface and should be its
own plan.

## Files to Modify

- `src/modules/custom_http_server/src/sse_manager.zig` — all 4 code
  changes.
- `src/modules/custom_http_server/src/sse_chunked_test.zig` — 4 new
  regression tests (appended).

## Verification

1. `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — must
   show `test success` and the new test count.
2. Manual smoke test on port 8080 (do NOT use 8081 — the long-running
   nalar is on 8081): start a new `nalar --port 8080`, open 100 SSE
   connections, close 50 abruptly, wait 30s, assert
   `clientCount() == 50` and the FD count is ~constant.
3. Re-run the user's friend scenario: open SSE connections for an
   extended period, abruptly close the browser/network, wait for the
   event loop to settle, assert `clientCount() == 0` and FD count
   stable.

## What the user's friend got right

- Diagnosis of the SSE manager as the leak source.
- POLL.NVAL subscription fix.
- Heartbeat sharding mismatch fix.
- Periodic sweep idea.

## What the user's friend got wrong

- Claim that the heartbeat can "skip multiple times in a row" — false.
  Every client is in exactly one loop's slice per cycle.

## What the user's friend missed

- TOCTOU use-after-free in `sendHeartbeat`, `broadcast`,
  `broadcastTyped`.
- `last_heartbeat` is updated BEFORE the write, hiding staleness from
  any periodic sweep.