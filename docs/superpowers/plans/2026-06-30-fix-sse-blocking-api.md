# Fix SSE Handler Blocking the Io Worker Pool

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the backend `/api/kanban/events` SSE handler return `error.WouldBlock` immediately (without a synchronous blocking `socket.write` on the critical path) so it stops starving the `std.Io.Threaded` worker pool when many clients connect simultaneously or with slow networks — which today blocks every other API call (POST `/api/kanban/columns`, etc.) until the connected-event handshake finishes.

**Architecture:** Three coordinated changes:

1. **Add `SseManager.sendDeferred(id, data)`** — spawns a one-shot task on a long-lived internal `std.Io.Group` (fire-and-forget, no `await`). The caller's worker thread is freed immediately; the actual `socket.write` runs on a separate worker thread.
2. **Update all 5 SSE handlers** (kanban + worker + sessions + llm_history + queue_messages) to call `sendDeferred` for the `event: connected` handshake instead of the synchronous `sendToClient`. The handler returns `error.WouldBlock` immediately, so the `group.concurrent` worker thread is released for the next incoming HTTP request.
3. **Lock the unlocked read in `sendToClient`/`broadcast`/`broadcastTyped`** — today these call `self.clients.get(id)` without holding `self.lock`, racing with the SSE event loop's locked iteration + `registerClient`'s mutation. The deferred-send worker thread makes the race more frequent.

**Tech Stack:** Zig 0.16, `std.Io.Threaded`, `std.Io.Group`, `posix.system` (`socket.write` / `sendto` with `MSG_NOSIGNAL`), the existing `SseManager` (`src/modules/custom_http_server/src/sse_manager.zig`), 5 SSE handlers under `src/ai_workflow/tui/http_handlers/*_sse.zig`.

**Spec / context:**
- Kanban task: `fix-sse-blocking-api` (workspace `ws_1779002584293_e52cd134532e1f00`, item `item_1782442554104741821`).
- Related done tasks on the same kanban: `non-blocking-sse-init` (frontend `setTimeout(start, 0)` defer in `helpers/sseClient.ts` — landed in commit `318d2d0d`), `fix-blocking-sse-call`, `fix the kanban sse stream chatview`.
- Today's symptom: while a kanban SSE client connects (the only client), every concurrent API call hangs for ~80 ms (typical Linux `tcp_send_buffer_lowat` time on a slow VM), because the kanban handler's `sendToClient(client_id_copy, connected_event)` calls `writeChunkedFrame` → `socket.write` synchronously, parking the `group.concurrent` worker thread.
- Today's race (separate but adjacent): `SseManager.sendToClient` reads `self.clients` without the lock while `runEventLoop` and `sendHeartbeat` iterate it with the lock held. The deferred-send path will make this race more frequent (worker threads calling `sendToClient` concurrently with the event-loop iterations).

---

## Context

### Current state

**Backend SSE handler pattern** (`src/ai_workflow/tui/http_handlers/kanban_events_sse.zig:95-121` — same shape in `worker_sse.zig`, `sessions_sse.zig`, `llm_history_sse.zig`, `queue_messages_sse.zig`):

```zig
pub fn kanbanEventsStreamHandler(ctx: ..., req: ..., res: ...) !HttpResponse {
    _ = req; _ = res;
    const di = try nalar_core.getSingleton();
    const server = di.server;

    if (ctx.client_id) |client_id| {
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient("kanban_column", client_id_copy, true) catch {};
        ai_mod.registerSessionClient("kanban_task",   client_id_copy, true) catch {};

        // ← BLOCKING: 3 sequential socket.write calls inside writeChunkedFrame
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
    }

    event_bus.subscribe(...);
    event_bus.subscribe(...);

    return error.WouldBlock;
}
```

**`http_server.zig` `handle()` task** (lines 213-247):
```zig
.sse => |sse| {
    // ... send chunked HTTP headers (synchronous socket.write) ...
    const client_id = server.sse_manager.registerClient(fd) catch { ... };
    sse_ctx.client_id = client_id;
    const res = http_parser.HttpResponse.init(200, "OK", allocator);
    _ = sse.handler(sse_ctx, req, res) catch |err| {
        if (err != error.WouldBlock) { std.debug.print(...); }
    };
    return;  // ← handle task ENDS here after the SSE handler returns WouldBlock
},
```

Each `.sse` route spawns its own `group.concurrent` worker task. The worker thread is parked in the `sendToClient(connected_event)` call for the entire duration of the kernel TCP send (typically <1 ms on localhost, but can be seconds on slow networks, paused VM, or under load).

With 4 `runEventLoop` tasks permanently parked in `socket.poll` (`LOOP_COUNT=4` in `sse_manager.zig:16`), the `std.Io.Threaded` worker pool (default ≈ hardware_concurrency = 8 on a typical dev box) has only ~3 free slots. A burst of 3+ concurrent SSE connections parks the pool and blocks every other HTTP request (`POST /api/kanban/columns`, `GET /api/llm/session`, etc.) until the connected-event writes complete.

**`SseManager.sendToClient`** (`src/modules/custom_http_server/src/sse_manager.zig:441-454`):
```zig
pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
    const client = self.clients.get(id) orelse return error.ClientNotFound;  // ← UNLOCKED READ
    if (writeChunkedFrame(client.fd, data)) {
        // success
    } else |_| {
        self.removeClient(id);
        return error.ClientDisconnected;
    }
}
```

`broadcast` (`:456-481`) and `broadcastTyped` (`:483-508`) have the same unlocked-read pattern. `runEventLoop`, `sendHeartbeat`, `registerClient`, `removeClient`, `removeClientByFd` all take `self.lock` around `self.clients` access.

### What's already in place

- The `SseClient` per-client `lock: std.Io.Mutex` (`sse_manager.zig:28`) for `sendEvent` — the per-client mutex serializes writes on the same fd.
- The `SseManager.lock: std.Io.Mutex` (`sse_manager.zig:88`) — already taken by all read/write paths except `sendToClient`/`broadcast`/`broadcastTyped`.
- The `notify_pipe: [2]i32` (`sse_manager.zig:93`) and `notifyLoops` (`sse_manager.zig:227-232`) — the wakeup mechanism the event loops use to learn about new clients. We don't need it for `sendDeferred` (the new task runs once and exits).
- Static regression test `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig` asserts the 4 existing handlers contain the literal `"event: connected\\ndata: {\\\"connected\\\": true}\\n\\n"` string in their source. We'll add `kanban_events_sse.zig` (5th handler) and update the test list.
- The frontend `setTimeout(start, 0)` defer in `helpers/sseClient.ts:724` (the `non-blocking-sse-init` work, commit `318d2d0d`) — already done; not in scope for this plan.

### Out of scope

- Frontend `sseClient.ts` `.reconnect()` deferral — `.reconnect()` is currently synchronous (`sseClient.ts:766-780` calls `start()` immediately). The kanban store doesn't use it; only the workersSse pattern might. Add as a separate plan if user reports a related issue.
- Switching SSE sockets to `O_NONBLOCK` and adding `EAGAIN` handling to `sendAll` — bigger refactor; the deferred-send approach is sufficient.
- The SSE `connected` event handler having to fire the initial `fetchInitialKanban` HTTP fetch on the frontend — already handled by the existing `kanbanSse.onConnected` callback and runs after the `setTimeout(start, 0)` defer.
- A `cross-cancellation` mechanism for the long-lived `send_group` — `defer group.cancel(self.io)` in `deinit` is sufficient (the task runs to completion or gets cancelled on shutdown).

---

## File Structure

### New files (none)

The helper lives on the existing `SseManager` struct. No new files needed.

### Modified files (Zig backend)

| File | Change |
|---|---|
| `src/modules/custom_http_server/src/sse_manager.zig` | Add `send_group: std.Io.Group` + `sendDeferred(id, data)` method; add `lock.lock/unlock` around the `self.clients.get(id)` call in `sendToClient`, `broadcast`, `broadcastTyped` |
| `src/ai_workflow/tui/http_handlers/kanban_events_sse.zig` | Replace synchronous `sendToClient(client_id_copy, connected_event)` with `sendDeferred(client_id_copy, connected_event)` |
| `src/ai_workflow/tui/http_handlers/worker_sse.zig` | Same swap (line 77) |
| `src/ai_workflow/tui/http_handlers/sessions_sse.zig` | Same swap (line 78) |
| `src/ai_workflow/tui/http_handlers/llm_history_sse.zig` | Same swap (line 81) |
| `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig` | Same swap (line 106) |
| `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig` | Add `"src/ai_workflow/tui/http_handlers/kanban_events_sse.zig"` to the `handlers` tuple (4 → 5) |
| `src/modules/custom_http_server/src/sse_chunked_test.zig` | Add static regression test that `SseManager` defines `fn sendDeferred` and that it spawns a `group.concurrent` task (not a synchronous `sendToClient` call) — guards against someone removing the helper in a future refactor |

### Modified files (no frontend changes)

This is a backend-only plan. The frontend already defers `start()` via `setTimeout(start, 0)` in `helpers/sseClient.ts:724`.

---

## Chunk 1: Add `SseManager.sendDeferred` + lock the reads

**Files:**
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:84-94` (add `send_group` field)
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:441-454` (`sendToClient` lock + lock-protected access to `client.fd`)
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:456-481` (`broadcast` lock)
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:483-508` (`broadcastTyped` lock)
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:113-132` (`deinit` cancels the new group)
- Modify: `src/modules/custom_http_server/src/sse_chunked_test.zig` (static regression test)
- Test: `src/modules/custom_http_server/src/sse_chunked_test.zig` (add to existing test file)

### Task 1.1: Add `send_group` field + cancel in `deinit`

**Files:**
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:84-94` (struct fields)
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:113-132` (`deinit`)

- [ ] **Step 1: Read the current `SseManager` struct + `deinit` to confirm exact text**

Read `src/modules/custom_http_server/src/sse_manager.zig` lines 84-132 (struct fields + `deinit`).

- [ ] **Step 2: Add `send_group: std.Io.Group = .init` field to `SseManager`**

Edit the struct fields section to add (after the existing `notify_pipe: [2]i32,` field):

```zig
/// Long-lived `std.Io.Group` used by `sendDeferred` for fire-and-forget
/// tasks. Tasks are spawned on this group but never awaited — the
/// handler that calls `sendDeferred` returns `error.WouldBlock`
/// immediately and the worker thread is freed for the next incoming
/// HTTP request. We cancel the group in `deinit` to release any
/// in-flight tasks on shutdown.
send_group: std.Io.Group = .init,
```

- [ ] **Step 3: Add `send_group.cancel` to `deinit`**

Edit `deinit` to add the cancellation right at the top (after `self.running = false;`, before the `self.lock` acquire — the lock isn't safe to take during a `cancel` because cancelled tasks may still hold it briefly):

```zig
pub fn deinit(self: *SseManager) void {
    self.running = false;
    // Cancel any in-flight `sendDeferred` tasks BEFORE tearing down
    // `self.clients`. Tasks that already started their `sendToClient`
    // call will complete (or hit `error.Canceled`); tasks that haven't
    // started yet are dropped. The `group.cancel` is non-blocking.
    self.send_group.cancel(self.io);
    // ... existing body unchanged ...
}
```

- [ ] **Step 4: Verify the file still compiles**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `test success` and the same baseline count (no test count change yet).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/custom_http_server/src/sse_manager.zig
git commit -m "feat(sse-manager): add send_group field + cancel in deinit"
```

### Task 1.2: Implement `sendDeferred` method

**Files:**
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:441-454` (add `sendDeferred` after `sendToClient`)

- [ ] **Step 1: Add `sendDeferred` method**

Insert this method right after the existing `sendToClient` (after the closing `};` at line 454):

```zig
/// Fire-and-forget send. Spawns a one-shot task on `self.send_group`
/// that calls `sendToClient(id, data)` on a separate worker thread,
/// then returns immediately. The caller's worker thread is freed for
/// the next incoming HTTP request — this is the fix for the "SSE
/// handler blocks the Io worker pool" bug.
///
/// Lifetime contract: `data` MUST point to memory that outlives the
/// worker's read of it. Safe cases:
///   - Static string literals (`const s = "..."`)
///   - Memory allocated from a long-lived allocator (NOT the
///     per-request arena in `http_server.zig`, which is freed when
///     the calling HTTP handler's `handle()` task ends).
///
/// `id` is a `[16]u8` — copied by value into the worker's args, no
/// lifetime concern.
///
/// `send_group.cancel(self.io)` is called in `deinit` to release
/// any tasks in flight on shutdown.
///
/// Errors from `sendToClient` (peer disconnected, etc.) are
/// swallowed — fire-and-forget has no caller to report to.
pub fn sendDeferred(self: *SseManager, id: [16]u8, data: []const u8) void {
    self.send_group.concurrent(self.io, struct {
        fn run(sm: *SseManager, cid: [16]u8, d: []const u8) void {
            sm.sendToClient(cid, d) catch {};
        }
    }.run, .{ self, id, data }) catch {};
}
```

- [ ] **Step 2: Verify the file compiles**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: same baseline.

- [ ] **Step 3: Commit**

```bash
git add src/modules/custom_http_server/src/sse_manager.zig
git commit -m "feat(sse-manager): add sendDeferred fire-and-forget helper"
```

### Task 1.3: Lock the unlocked reads in `sendToClient` / `broadcast` / `broadcastTyped`

**Files:**
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:441-454` (`sendToClient`)
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:456-481` (`broadcast`)
- Modify: `src/modules/custom_http_server/src/sse_manager.zig:483-508` (`broadcastTyped`)

- [ ] **Step 1: Re-read the three functions for exact text**

Read lines 441-508.

- [ ] **Step 2: Lock `sendToClient`'s `self.clients.get(id)` call**

Replace the body of `sendToClient`:

```zig
pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
    // Lock to read `self.clients` so a concurrent `registerClient` /
    // `removeClient` can't rehash the map under us. We extract the
    // `fd` value under the lock and release it before the blocking
    // write — same pattern as `sendHeartbeat` (sse_manager.zig:409-420).
    const fd: i32 = blk: {
        self.lock.lock(self.io) catch return error.LockFailed;
        defer self.lock.unlock(self.io);
        const client = self.clients.get(id) orelse return error.ClientNotFound;
        break :blk client.fd;
    };

    if (writeChunkedFrame(fd, data)) {
        // success
    } else |_| {
        self.removeClient(id);
        return error.ClientDisconnected;
    }
}
```

- [ ] **Step 3: Lock `broadcast`'s iterator**

Replace the body of `broadcast`:

```zig
pub fn broadcast(self: *SseManager, data: []const u8) !void {
    const event = try std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{data});
    defer self.allocator.free(event);

    // Snapshot client fds under the lock so a concurrent register /
    // remove can't invalidate the iterator. Same pattern as
    // `sendHeartbeat` (sse_manager.zig:409-420).
    var client_fds: std.ArrayListUnmanaged(i32) = .empty;
    {
        self.lock.lock(self.io) catch unreachable;
        defer self.lock.unlock(self.io);
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            client_fds.append(self.allocator, entry.value_ptr.*.fd) catch break;
        }
    }
    defer client_fds.deinit(self.allocator);

    for (client_fds.items) |fd| {
        if (writeChunkedFrame(fd, event)) {
            // success
        } else |_| {
            // We lost the client_id when we extracted just the fd.
            // The lock-free `removeClient` lookup will skip the
            // disconnect handler because `send_to_client` already
            // removed the client on the previous failed write (if
            // any). This is best-effort — a write failure here just
            // means the client gets disconnected, which the event
            // loop's next `socket.poll` will detect anyway.
        }
    }
}
```

(Trade-off: we lose the `client.id` needed to call `self.removeClient(fd)` — the `sendToClient` path still has it via the `id` parameter; the broadcast path can skip the explicit remove because the next `socket.poll` will detect the dead peer. Document this in the comment.)

- [ ] **Step 4: Lock `broadcastTyped` the same way**

Apply the identical `lock`-protected snapshot + `defer unlock` pattern to `broadcastTyped` (lines 483-508).

- [ ] **Step 5: Verify build + tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: same baseline test count, no compile errors in `sse_manager.zig`.

- [ ] **Step 6: Commit**

```bash
git add src/modules/custom_http_server/src/sse_manager.zig
git commit -m "fix(sse-manager): lock reads in sendToClient/broadcast/broadcastTyped"
```

### Task 1.4: Static regression test for `sendDeferred`

**Files:**
- Modify: `src/modules/custom_http_server/src/sse_chunked_test.zig` (add new test, register in `test_runner.zig`)

- [ ] **Step 1: Read the existing test file structure**

Read `src/modules/custom_http_server/src/sse_chunked_test.zig` lines 1-50 to find the pattern for static source-check tests and how `readSseManagerSource` works.

- [ ] **Step 2: Add `sendDeferred` static test**

Insert after the existing `sendHeartbeat takes the manager lock` test (around line 318). Mirror the existing pattern:

```zig
// ============================================================================
// Task (this plan): SseManager must define `sendDeferred` that spawns a
// group.concurrent task — guards against someone removing the helper in
// a future refactor and silently regressing the kanban-SSE handler
// blocking fix.
//
// Bug history (pre-fix): every SSE handler called `sendToClient` for
// the connected-event handshake synchronously, blocking the
// `group.concurrent` worker thread until the kernel TCP send
// completed. With 4 SSE event loops parked in `socket.poll`
// (`LOOP_COUNT=4`), the worker pool could starve under a burst of
// SSE connections, blocking every other HTTP API call.
//
// Fix: `sendDeferred` spawns the send on `send_group` (a long-lived
// internal Io Group), freeing the caller's worker thread immediately.
// The connected-event handshake (38 bytes of static-literal data)
// is safe to defer — the worker reads the literal's static memory.
// ============================================================================

test "SseManager: defines sendDeferred that uses send_group.concurrent (NOT synchronous sendToClient)" {
    const source = try readSseManagerSource(std.testing.allocator);
    defer std.testing.allocator.free(source);

    // 1. The helper must exist.
    const decl = std.mem.indexOf(u8, source, "fn sendDeferred(") orelse {
        std.debug.print(
            "\n!! sse_manager.zig missing `fn sendDeferred` !!\n" ++
                "   The SSE handler blocking fix requires a fire-and-forget helper that\n" ++
                "   spawns the connected-event send on a separate worker thread. Without\n" ++
                "   this, every SSE handshake parks the calling `group.concurrent` worker\n" ++
                "   thread on `socket.write`, starving the Io worker pool.\n",
            .{},
        );
        return error.SendDeferredMissing;
    };
    const window_end = @min(decl + 4096, source.len);
    const body = source[decl..window_end];

    // 2. The helper must spawn via `send_group.concurrent` (NOT call
    //    `sendToClient` directly — that would re-introduce the
    //    synchronous-block bug we just fixed).
    if (std.mem.indexOf(u8, body, "send_group.concurrent") == null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendDeferred does not use `send_group.concurrent` !!\n" ++
                "   The helper must spawn the send on the internal `send_group` Io Group\n" ++
                "   so the calling worker thread is freed immediately.\n",
            .{},
        );
        return error.SendDeferredNotConcurrent;
    }

    // 3. The helper must NOT call `sendToClient` directly (would be
    //    the same bug).
    if (std.mem.indexOf(u8, body, "sendToClient(") != null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendDeferred calls `sendToClient` directly !!\n" ++
                "   The helper must spawn a task that calls sendToClient — NOT call\n" ++
                "   sendToClient in the calling thread. Direct call would re-introduce\n" ++
                "   the synchronous-block bug.\n",
            .{},
        );
        return error.SendDeferredCallsSendToClient;
    }
}
```

- [ ] **Step 3: Register the new test in the module's `test_runner.zig`**

Open `src/modules/custom_http_server/src/test_runner.zig` and confirm `_ = @import("sse_chunked_test.zig");` is already there (it is, per the file's header comment). If a separate test file is added later, register it here.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
TEST_BIN=$(ls -t .zig-cache/o/*/test | head -n 1)
timeout 60 "$TEST_BIN" 2>&1 | rg -i "sendDeferred"
```

Expected: the new test name appears in the output with no failures.

- [ ] **Step 5: Verify the test fails on stashed (pre-fix) code**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git stash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
# Expect the new test to fail with error.SendDeferredMissing.
git stash pop
```

If the stash loses the new test too, instead run the test against an in-memory `sse_manager.zig` with `fn sendDeferred(` deleted, then restore. (See `zig-stdfmt-bufprint-aliases-slice-headers.md` for the red-green verification pattern.)

- [ ] **Step 6: Commit**

```bash
git add src/modules/custom_http_server/src/sse_chunked_test.zig
git commit -m "test(sse-manager): assert sendDeferred uses send_group.concurrent"
```

---

## Chunk 2: Update the 5 SSE handlers to use `sendDeferred`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_events_sse.zig:111-112`
- Modify: `src/ai_workflow/tui/http_handlers/worker_sse.zig:77`
- Modify: `src/ai_workflow/tui/http_handlers/sessions_sse.zig:78`
- Modify: `src/ai_workflow/tui/http_handlers/llm_history_sse.zig:81`
- Modify: `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig:106`
- Modify: `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig:85-90` (add 5th handler)
- Modify: `src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig` (add static check)

### Task 2.1: Update `kanban_events_sse.zig` (primary handler)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_events_sse.zig:111-112`

- [ ] **Step 1: Read the current handler body**

Read `src/ai_workflow/tui/http_handlers/kanban_events_sse.zig` lines 95-121.

- [ ] **Step 2: Replace the synchronous `sendToClient` call with `sendDeferred`**

Replace lines 111-112:

```zig
        // Send the "connected" ack so the frontend's `onopen` fires.
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
```

with:

```zig
        // Send the "connected" ack so the frontend's `onopen` fires.
        // Deferred via `sendDeferred` so the handler task's
        // `group.concurrent` worker thread is freed immediately —
        // see docs/plans/2026-06-30-fix-sse-blocking-api.md. The
        // connected_event string is a static literal, so it's safe
        // to defer (lifetime contract documented on SseManager.sendDeferred).
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendDeferred(client_id_copy, connected_event);
```

Note: `sendDeferred` returns `void` (fire-and-forget), not `!void` — drop the `catch {}`.

- [ ] **Step 3: Verify the file compiles**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: same baseline count.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/kanban_events_sse.zig
git commit -m "fix(kanban-sse): defer connected-event send to free worker thread"
```

### Task 2.2: Update the other 4 SSE handlers (mechanical, parallelizable)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/worker_sse.zig:77`
- Modify: `src/ai_workflow/tui/http_handlers/sessions_sse.zig:78`
- Modify: `src/ai_workflow/tui/http_handlers/llm_history_sse.zig:81`
- Modify: `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig:106`

Each of the 4 files has the same one-line swap. The handlers can be edited in any order — they're independent files with no shared state. After this chunk, all 5 SSE handlers use the deferred-send pattern.

- [ ] **Step 1: Apply the same swap to `worker_sse.zig`**

In `src/ai_workflow/tui/http_handlers/worker_sse.zig`, replace:

```zig
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
```

with:

```zig
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendDeferred(client_id_copy, connected_event);
```

Add a one-line comment above the swap:

```zig
        // Deferred to keep the handler task non-blocking — see
        // SseManager.sendDeferred (docs/plans/2026-06-30-fix-sse-blocking-api.md).
```

- [ ] **Step 2: Apply the same swap to `sessions_sse.zig`, `llm_history_sse.zig`, `queue_messages_sse.zig`**

Mirror the edit from Step 1 in each of the other 3 files. Each file has exactly one `sendToClient(client_id_copy, connected_event)` line to swap.

- [ ] **Step 3: Verify all 4 files compile + tests still pass**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: same baseline count (no test changes).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/worker_sse.zig \
        src/ai_workflow/tui/http_handlers/sessions_sse.zig \
        src/ai_workflow/tui/http_handlers/llm_history_sse.zig \
        src/ai_workflow/tui/http_handlers/queue_messages_sse.zig
git commit -m "fix(sse): defer connected-event send in worker/sessions/llm/queue handlers"
```

### Task 2.3: Update `sse_handshake_test.zig` to cover the 5th handler

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig:85-90`

- [ ] **Step 1: Read the current `handlers` tuple**

Read `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig` lines 85-90.

- [ ] **Step 2: Add the 5th handler**

Replace the tuple:

```zig
    const handlers = .{
        "src/ai_workflow/tui/http_handlers/worker_sse.zig",
        "src/ai_workflow/tui/http_handlers/sessions_sse.zig",
        "src/ai_workflow/tui/http_handlers/llm_history_sse.zig",
        "src/ai_workflow/tui/http_handlers/queue_messages_sse.zig",
    };
```

with:

```zig
    const handlers = .{
        "src/ai_workflow/tui/http_handlers/worker_sse.zig",
        "src/ai_workflow/tui/http_handlers/sessions_sse.zig",
        "src/ai_workflow/tui/http_handlers/llm_history_sse.zig",
        "src/ai_workflow/tui/http_handlers/queue_messages_sse.zig",
        // Added when kanban_events_sse.zig landed — chunk 5 of the
        // kanban-list-empty-add-sse plan added the handler without
        // including it in this regression list. Adding now to keep
        // the contract test authoritative.
        "src/ai_workflow/tui/http_handlers/kanban_events_sse.zig",
    };
```

- [ ] **Step 3: Run the test to verify all 5 handlers pass**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: same baseline + 1 (the sse_handshake_test now scans 5 files instead of 4, but the test count is 1 either way).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/sse_handshake_test.zig
git commit -m "test(sse-handshake): cover the 5th handler (kanban_events_sse)"
```

### Task 2.4: Add `sendDeferred` regression check to `kanban_events_sse_test.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig` (add a 4th contract test)

- [ ] **Step 1: Read the current test file**

Read `src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig` to confirm the existing pattern.

- [ ] **Step 2: Add the 4th contract test**

Append at the end of the file:

```zig
// ─── Contract 4: handler uses sendDeferred (not synchronous sendToClient)
//                 for the connected-event handshake, so the handler task's
//                 group.concurrent worker thread is freed immediately.
//
//                 Bug history: pre-fix, the handler called
//                 `server.sse_manager.sendToClient(client_id_copy,
//                 connected_event)` synchronously, parking the worker
//                 thread on `socket.write`. With 4 SSE event loops
//                 permanently parked in `socket.poll`, a burst of
//                 kanban-SSE connections could starve the Io worker
//                 pool and block every other API call.
//                 See docs/plans/2026-06-30-fix-sse-blocking-api.md. ──────

test "kanban_events_sse.zig uses sendDeferred for the connected-event handshake" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // 1. The handler MUST call `sendDeferred` for the connected event.
    if (std.mem.indexOf(u8, source, "sendDeferred(client_id_copy, connected_event)") == null) {
        std.debug.print(
            "\n!! {s} does not use `sendDeferred` for the connected-event send !!\n" ++
                "   The SSE handler is blocking the Io worker pool on synchronous\n" ++
                "   `sendToClient` -> `writeChunkedFrame` -> `socket.write`. Replace:\n" ++
                "     server.sse_manager.sendToClient(client_id_copy, connected_event) catch {{}};\n" ++
                "   with:\n" ++
                "     server.sse_manager.sendDeferred(client_id_copy, connected_event);\n",
            .{HANDLER_PATH},
        );
        return error.SendDeferredCallMissing;
    }

    // 2. The handler MUST NOT also call synchronous `sendToClient` for
    //    the connected event (would re-introduce the blocking bug).
    if (std.mem.indexOf(u8, source, "sendToClient(client_id_copy, connected_event)") != null) {
        std.debug.print(
            "\n!! {s} still has a synchronous `sendToClient(client_id_copy, connected_event)` call !!\n" ++
                "   Remove the synchronous call — the deferred `sendDeferred` call handles\n" ++
                "   the connected-event send.\n",
            .{HANDLER_PATH},
        );
        return error.SynchronousSendToClientPresent;
    }
}
```

- [ ] **Step 3: Run the test to verify it passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: same baseline + 1.

- [ ] **Step 4: Verify the test fails on stashed (pre-fix) code**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git stash push -- src/ai_workflow/tui/http_handlers/kanban_events_sse.zig
timeout 180 zig build test --summary all 2>&1 | tail -n 5
# Expect: test "kanban_events_sse.zig uses sendDeferred..." fails with
# error.SendDeferredCallMissing.
git stash pop
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig
git commit -m "test(kanban-sse): assert handler uses sendDeferred for handshake"
```

---

## Chunk 3: Behavioral verification + end-to-end smoke test

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig` (add 5th behavioral test, optional)
- Manual: `docs/superpowers/plans/2026-06-30-fix-sse-blocking-api.md` (verification steps for the executor)

### Task 3.1: Behavioral test — handler returns within 1 ms of `acceptClient`

Optional but recommended. Add a Zig behavioral test that:

1. Stands up an in-memory `SseManager` (via `registerClientForTest`).
2. Calls `kanbanEventsStreamHandler(ctx, req, res)`.
3. Asserts the handler returns `error.WouldBlock` immediately (no `socket.write` was performed in the calling thread — use a fake `EventSourceCtor`-style mock or count `writeChunkedFrame` calls on the registered fd before/after).

Skipped from this plan because: it requires mocking `posix.system.write` on a per-fd basis, which is non-trivial in Zig 0.16's `posix.system` layer. The static regression tests in Tasks 1.4 and 2.4 already lock in the contract; the manual smoke test in Task 3.2 below is sufficient for end-to-end verification.

### Task 3.2: Manual end-to-end smoke test

- [ ] **Step 1: Start `nalar` on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build install:linux:system 2>&1 | tail -n 5
# Binary lands at zig-out/bin/nalar. Run it in the background.
exec ./zig-out/bin/nalar --port 8080 &
sleep 2
```

- [ ] **Step 2: Verify `/api/health` is up**

```bash
curl -sS http://127.0.0.1:8080/health
```

Expected: `OK`.

- [ ] **Step 3: Open 5 concurrent kanban SSE connections + 5 concurrent POST `/api/kanban/columns` requests, measure timings**

```bash
# Open 5 SSE connections in the background; capture the time each takes to receive `connected`.
for i in 1 2 3 4 5; do
  (time curl -sS -N -H 'Accept: text/event-stream' \
       --max-time 5 http://127.0.0.1:8080/api/kanban/events 2>&1) &
done

# Immediately fire 5 POSTs to a placeholder endpoint.
for i in 1 2 3 4 5; do
  (time curl -sS -X POST -H 'Content-Type: application/json' \
       -d '{"workspace_id":"ws_1779002584293_e52cd134532e1f00","item_id":"item_1782442554104741821","name":"test '$i'"}' \
       http://127.0.0.1:8080/api/kanban/columns 2>&1) &
done

wait
```

Expected (post-fix):
- SSE `connected` events arrive within ~50 ms each (the deferred send runs in parallel; clients don't wait on each other).
- POST responses arrive within ~80 ms each (no worker pool starvation).
- The two streams are interleaved, not serialized.

Expected (pre-fix):
- Each SSE `connected` event blocks its worker thread for the full socket write duration.
- POST requests queue behind the SSE connections — observed `time` shows serial delays (~80 ms × 5 = ~400 ms instead of ~80 ms parallel).

- [ ] **Step 4: Tear down**

```bash
kill $(pgrep -f 'nalar --port 8080')
```

- [ ] **Step 5: Document the result in the commit message**

```bash
git commit --allow-empty -m "verify: fix-sse-blocking-api end-to-end smoke test passed"
```

(Skip if Task 3.2 is run locally only — the empty commit is just for the executor's reference.)

---

## Verification (executor must run before marking complete)

Per the project memory `verification-before-completion` skill:

1. **Backend build + tests** — both must pass:
   ```bash
   cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
   timeout 240 zig build test --summary all 2>&1 | tail -n 5
   timeout 240 zig build install:linux:system 2>&1 | tail -n 5
   ```
   Expected: `Build Summary: 4/6 steps succeeded` (the cp-to-/usr/local/bin step fails harmlessly); `test success` and the expected test count (baseline + 4 new tests).

2. **Static regression tests pass** — confirm the new tests in `sse_chunked_test.zig` and `kanban_events_sse_test.zig` exist in the test count:
   ```bash
   TEST_BIN=$(ls -t .zig-cache/o/*/test | head -n 1)
   timeout 60 "$TEST_BIN" 2>&1 | rg -i 'sendDeferred|SseManager.*sendDeferred'
   ```
   Expected: 2 hits (one per test file).

3. **Red-green verification on each new test** — confirm each new test fails on pre-fix code:
   ```bash
   # For each new test file:
   git stash push -- <file>
   timeout 180 zig build test --summary all 2>&1 | tail -n 5
   git stash pop
   ```
   Expected: the test fails with the specific error name (`error.SendDeferredMissing`, `error.SendDeferredCallMissing`, etc.).

4. **End-to-end smoke test** (Task 3.2) — the SSE `connected` events and POST requests must interleave, not serialize.

5. **No new failing tests vs. baseline** — `zig build test --summary all` reports the same pass count + the new tests added by this plan.

---

## Pitfalls

1. **`std.Io.Group` requires `await` or `cancel` to release resources.** The long-lived `send_group` is cancelled in `SseManager.deinit` (Task 1.1). Without the cancel, the group's internal allocation would leak on shutdown. Don't `await` `send_group` — that would block on shutdown (in-flight sends would block until they finish, which can be slow on a paused client).

2. **`send_group.cancel(self.io)` is non-blocking.** Per Zig 0.16's `std.Io.Group.cancel` docstring: "Equivalent to `await` but immediately requests cancelation on all members." The cancel signal propagates to in-flight tasks, which will exit at their next cancelation point. Tasks that are already inside `sendToClient` → `writeChunkedFrame` → `socket.write` will complete the syscall (which is uninterruptible by cancelation) and then return.

3. **The `data` slice passed to `sendDeferred` MUST point to long-lived memory.** The handler's `const connected_event = "..."` is a static literal, so it's safe. If a future caller passes a per-request arena slice, the arena is freed when the calling handler's `handle()` task ends, but the worker may still be reading the slice → use-after-free. The doc comment on `sendDeferred` (Task 1.2) calls this out.

4. **`broadcast` lost the `client.id` after the lock-protected snapshot refactor.** The trade-off (Task 1.3 Step 3 comment) is documented inline: a write failure in `broadcast` no longer triggers an immediate `removeClient` (we don't have the id). The next `socket.poll` in `runEventLoop` will detect the dead peer via `POLL.HUP` and remove it. This is best-effort; the trade-off is acceptable because broadcasts are non-critical (they're "fire to everyone" notifications, not transactional responses).

5. **`zig build test` may miss compile errors in `sse_chunked_test.zig`'s new static-check test.** The test reads `sse_manager.zig` from disk via `std.Io.Dir.cwd().readFileAlloc` — the test's compile does not type-check the source it's reading. The behavioral check (asserting the right error name is returned) is the source of truth; run `zig build install:linux:system` to confirm `sse_manager.zig` itself compiles.

6. **Don't remove `sse_manager.sendToClient`** — it's still used by the SSE event loop's `sendHeartbeat` (sse_manager.zig:431), `broadcast` (now calls it via the worker task in Task 1.2's pattern), and the `poll` event handlers. `sendDeferred` is a NEW method, not a replacement.

7. **The frontend `.reconnect()` is NOT in scope.** `sseClient.ts:766-780` still calls `start()` synchronously on reconnect. The kanban SSE store doesn't use `.reconnect()`; only `initKanbanSse` (which closes + creates a new client) — and the new client's first `start()` is already deferred. Add a separate plan if `.reconnect()` blocking becomes a real issue for the workersSse pattern.

8. **`kanban_events_sse.zig` was NOT in the original `sse_handshake_test.zig` handlers list.** Chunk 5 of the kanban-list-empty-add-sse plan (commit `79045ace`) added the handler without including it in the regression list. Task 2.3 fixes this oversight.

9. **Worker-pool size is small on this codebase.** `std.Io.Threaded`'s default worker pool is ≈ hardware_concurrency (typically 8 on a dev box). With 4 SSE event loops permanently parked in `socket.poll`, plus the listen() thread on the main thread, only ~3 slots are free for HTTP handlers. A burst of 4+ concurrent SSE connections on the pre-fix code starves the pool. The fix ensures each SSE handler releases its worker thread immediately after `registerClient` succeeds.

---

## Related

- `non-blocking-sse-init` skill — the frontend half of this fix (already done in commit `318d2d0d`). The defer pattern (`setTimeout(start, 0)` for the initial `start()` call) is the frontend analog of `sendDeferred` for the backend.
- `zig-0.16-thread-and-sleep-api.md` — the `std.Io.Group.concurrent` + `await` / `cancel` pattern is documented in `std.Io.Group` (see `std/Io.zig:1218-1300`). The plan uses `cancel` (not `await`) in `deinit` because `await` would block on in-flight sends.
- `custom-http-server-per-request-arena.md` — different memory ownership pattern (per-request arena reaps handler allocations; `sendDeferred`'s static-literal contract does not conflict — the connected event lives in static memory, not the arena).
- `sse-manager-defer-connected-event.md` (memory to be written) — the new memory this plan produces; should be added after execution so future agents know to use `sendDeferred` (not `sendToClient`) when adding new SSE handlers.