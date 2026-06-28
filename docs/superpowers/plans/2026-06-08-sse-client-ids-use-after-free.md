# SSE Client IDs Use-After-Free Fix Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the SIGABRT segfault in `llm_history_sse.zig:47` (and 3 sibling SSE handlers) by making `getListClientsForSession` return an owned, copied slice so the SSE callbacks can iterate it safely even when a `sendToClient` failure synchronously triggers `unregisterSessionClient`.

**Architecture:** Two surgical changes — (1) the source-of-truth function `getListClientsForSession` (`src/root.zig:235`) returns an `allocator.dupe([16]u8, list.items)` copy that survives concurrent map mutations, and (2) each of the 4 SSE callbacks adds a `defer allocator.free(client_ids)`. The latent dead-code branch in `handleClientDisconnect` that would double-free the new owned slice is also removed.

**Tech Stack:** Zig 0.15.2, `std.ArrayListUnmanaged`, `std.Io.Mutex`, SSE via `SseManager`.

---

## Bug Trace (read this first — the plan falls out of it)

The crash report:

```
Segmentation fault at address 0x7efd7d644210
/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/ai_workflow/tui/http_handlers/llm_history_sse.zig:47:14: in callback
        for (client_ids) |client_id| {
             ^
```

The crashing line iterates a `[][16]u8` slice that came from `getListClientsForSession(session_id, allocator, false)`. Here is the offending function (`src/root.zig:235-247`):

```zig
pub fn getListClientsForSession(
    session_id: []const u8,
    allocator: std.mem.Allocator,
    is_use_lock: bool,
) !?[][16]u8 {
    _ = is_use_lock;
    _ = allocator;                       // ← allocator is THROWN AWAY
    const di = try getSingleton();
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);

    const list = di.session_to_client_ids.get(session_id) orelse return null;
    if (list.items.len == 0) return null;

    return list.items;                   // ← BORROWED slice into the map
}
```

The returned `client_ids` slice points **into** the `ArrayListUnmanaged([16]u8)` value that lives inside `di.session_to_client_ids` (a `StringHashMapUnmanaged`). The lock is released by the `defer` when the function returns. The caller then iterates the slice **without holding the lock**.

### The trigger (synchronous re-entrancy via `sendToClient`)

In `src/modules/custom_http_server/src/sse_manager.zig:378-388`:

```zig
pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
    const client = self.clients.get(id);
    if (client == null) return error.ClientNotFound;

    const n = socket.write(client.?.fd, data.ptr, data.len);
    if (n < 0) {
        self.removeClient(id);          // ← SYNCHRONOUS, in the same thread
        return error.ClientDisconnected;
    }
}
```

`removeClient` (line 148-158) acquires the SseManager lock, removes the client, and invokes `on_disconnect`, which is `handleClientDisconnect` in `src/root.zig:276`:

```zig
pub fn handleClientDisconnect(client_id: [16]u8) void {
    // ... acquire on_disconnect_lock ...
    if (di.on_disconnect_cb) |cb| cb(client_id);

    const maybe_session_id = getSessionIdForClient(client_id, false);
    if (maybe_session_id) |session_id| {
        defer di.allocator.free(session_id);

        unregisterSessionClient(session_id, false);   // ← frees the list
        // ...
    }
}
```

And `unregisterSessionClient` (`src/root.zig:203-215`):

```zig
pub fn unregisterSessionClient(session_id: []const u8, is_use_lock: bool) void {
    // ...
    if (di.session_to_client_ids.fetchRemove(session_id)) |kv| {
        var list = kv.value;
        list.deinit(allocator);          // ← FREES THE BACKING ARRAY
        allocator.free(kv.key);
    }
}
```

The complete call chain that produces the crash:

1. SSE callback (`CallbackAiStream.callback`) calls `getListClientsForSession` → gets borrowed slice `S` → releases `session_map_lock`.
2. Loop iteration 1: `sendToClient(S[0], event_data)`.
3. `sendToClient` writes to a dead socket (e.g., browser tab closed, kernel RST'd). `socket.write` returns -1.
4. `sendToClient` synchronously calls `self.removeClient(S[0])`.
5. `removeClient` synchronously invokes `handleClientDisconnect(S[0])`.
6. `handleClientDisconnect` synchronously calls `unregisterSessionClient(session_id, false)`.
7. `unregisterSessionClient` calls `list.deinit(allocator)` — **`S`'s backing memory is now freed**.
8. Control unwinds back to the `for` loop in the SSE callback.
9. The loop reads `S[1]` — the slice header (`.len`, `.ptr`) is the old value, `.ptr` now points to freed-and-reused memory.
10. **SEGFAULT** at `for (client_ids) |client_id|` (or at the body of iteration 2, depending on what the allocator wrote into the freed block).

### Secondary trigger paths (same bug, different thread)

- **Event loop HUP** (`runEventLoop` in `sse_manager.zig:317-320`): one of the 4 polling threads detects `POLL.HUP` on a client fd and calls `self.removeClientByFd(pfd.fd)`, which runs the same `on_disconnect` chain.
- **Heartbeat failure** (`sendHeartbeat` in `sse_manager.zig:365-374`): the polling thread writes a `data: ping\n\n` heartbeat, gets a write error, and calls `self.removeClient(id)`.

All three paths share the property that the `client_ids` slice is invalidated **while a different caller is iterating it**. The fix is the same regardless of which path triggers the crash.

### Latent bug also visible

`handleClientDisconnect` (root.zig:298-311) calls `getListClientsForSession` AFTER `unregisterSessionClient` removed the entry — so the call returns `null` and the `if (listClients) |clients| { defer di.allocator.free(clients); ... }` branch is **dead code today**. But the function would return a borrowed slice, and the `defer free` would be a double-free. After the fix changes the function to return an owned copy, this dead branch becomes a memory-leak trap. The plan removes the dead branch in the same PR.

---

## File Structure

| File | Responsibility | Change |
|------|---------------|--------|
| `src/root.zig` | `getListClientsForSession`, `handleClientDisconnect` | Returns owned dupe; remove dead `defer free` branch |
| `src/ai_workflow/tui/http_handlers/llm_history_sse.zig` | SSE callback for chat streaming | Add `defer allocator.free(client_ids)` |
| `src/ai_workflow/tui/http_handlers/worker_sse.zig` | SSE callback for worker list | Add `defer allocator.free(client_ids)` |
| `src/ai_workflow/tui/http_handlers/sessions_sse.zig` | SSE callback for session list | Add `defer allocator.free(client_ids)` |
| `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig` | SSE callback for queue messages | Add `defer allocator.free(client_ids)` |
| `src/ai_workflow/tui/http_handlers/sse_callback_client_ids_free_test.zig` (NEW) | Static regression: every SSE callback frees the slice | New file |
| `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig` | (read-only reference) | n/a |
| `src/ai_workflow/tui/test_runner.zig` | Test registration | Add the new test file |

---

## Chunk 1: Regression Test That Pins the Contract

### Task 1.1: Write a static source-level test that fails on the bug

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/sse_callback_client_ids_free_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Create the new test file**

Write to `src/ai_workflow/tui/http_handlers/sse_callback_client_ids_free_test.zig`:

```zig
//! Regression test for the SSE `client_ids` use-after-free.
//!
//! Why this file exists
//! ────────────────────
//! `getListClientsForSession` (src/root.zig) used to return a slice
//! borrowed from the `session_to_client_ids` map's internal
//! `ArrayListUnmanaged([16]u8)`. Each of the 4 SSE callbacks then
//! iterated that slice inside a `for (client_ids) |client_id| { ... }`
//! loop, WITHOUT holding the `session_map_lock`. The first
//! `server.sse_manager.sendToClient(...)` call could synchronously
//! trigger `removeClient` → `on_disconnect` → `handleClientDisconnect`
//! → `unregisterSessionClient` → `list.deinit(allocator)`, freeing
//! the backing array the outer loop was still iterating. Result:
//! SIGABRT (segfault) at the `for` line.
//!
//! The fix is in two parts that must BOTH hold for the contract to
//! be correct:
//!
//! 1. `getListClientsForSession` returns an `allocator.dupe(...)`
//!    OWNED copy, so the slice outlives concurrent map mutations.
//! 2. Each SSE callback frees the returned slice with
//!    `defer allocator.free(client_ids)` after the `orelse`.
//!
//! This file pins BOTH parts with static source-level checks. The
//! test reads the .zig source files from disk and asserts the
//! exact call/return/free patterns are present. It is the same
//! pattern as `sse_handshake_test.zig` (substring match on the
//! source form of the SSE connected-handshake string).
//!
//! A behavioral test (race a fake `sendToClient` failure against
//! the for-loop) was considered and dropped: the race is
//! non-deterministic, the SseManager requires a real socket, and
//! the static checks below directly test the bug.

const std = @import("std");
const nalarcore = @import("nalarcore");
const testing = std.testing;

/// The 4 SSE route source files registered in src/main.zig.
/// Order matches the docstring in sse_handshake_test.zig.
const handler_paths = [_][]const u8{
    "src/ai_workflow/tui/http_handlers/llm_history_sse.zig",
    "src/ai_workflow/tui/http_handlers/worker_sse.zig",
    "src/ai_workflow/tui/http_handlers/sessions_sse.zig",
    "src/ai_workflow/tui/http_handlers/queue_messages_sse.zig",
};

/// Read a project-relative file as bytes. Anchored on the
/// project root by walking up from CWD until a `src/` dir is found.
fn readProjectFile(rel_path: []const u8) ![]u8 {
    // Try CWD first, then walk up 3 levels.
    var buf: [4096]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &buf);
    var dir = try std.fs.openDirAbsolute(cwd_path, .{});
    defer dir.close();

    return try dir.readFileAlloc(testing.allocator, rel_path, 1024 * 1024);
}

test "SSE callbacks: every handler frees the client_ids slice it borrows" {
    // For each SSE handler, assert that the source contains BOTH:
    //   (a) the call to `getListClientsForSession(...)` — the
    //       function that now returns an owned slice;
    //   (b) a `defer allocator.free(client_ids)` immediately after
    //       the `client_ids = maybe_clients orelse return;` line.
    //
    // Pattern (b) is the line that prevents the use-after-free.
    // Without it, the `for (client_ids) |client_id|` loop
    // dereferences memory the caller doesn't own.
    for (handler_paths) |path| {
        const source = try readProjectFile(path);
        defer testing.allocator.free(source);

        // (a) The call must be present.
        try testing.expect(source.len > 0);
        if (std.mem.indexOf(u8, source, "getListClientsForSession") == null) {
            std.debug.print("FAIL: {s} does not call getListClientsForSession\n", .{path});
            return error.MissingGetCall;
        }

        // (b) The free must be present, and it must reference the
        // local binding named `client_ids`. We allow the slice to
        // be named differently per handler, so we look for the
        // exact `defer allocator.free(client_ids)` substring.
        const free_pattern = "defer allocator.free(client_ids)";
        if (std.mem.indexOf(u8, source, free_pattern) == null) {
            std.debug.print(
                "FAIL: {s} does not contain `{s}` — client_ids slice will leak AND the caller assumes it owns the slice\n",
                .{ path, free_pattern },
            );
            return error.MissingFree;
        }
    }
}

test "getListClientsForSession: returns an owned dupe copy" {
    // Static check on src/root.zig that the function:
    //   (a) NO LONGER has `return list.items;` (the borrowed-return bug);
    //   (b) HAS `allocator.dupe([16]u8, list.items)` (the fix).
    const source = try readProjectFile("src/root.zig");
    defer testing.allocator.free(source);

    // (a) The bug: returning the borrowed slice. The fix replaces
    //     this with a dupe. We assert the borrowed-return is GONE.
    if (std.mem.indexOf(u8, source, "return list.items;") != null) {
        std.debug.print(
            "FAIL: src/root.zig still has `return list.items;` — this returns a borrowed slice into session_to_client_ids and re-introduces the use-after-free\n",
            .{},
        );
        return error.BorrowedReturn;
    }

    // (b) The fix: dupe into a caller-owned slice.
    if (std.mem.indexOf(u8, source, "allocator.dupe([16]u8, list.items)") == null) {
        std.debug.print(
            "FAIL: src/root.zig does not contain `allocator.dupe([16]u8, list.items)` — the function does not return an owned copy\n",
            .{},
        );
        return error.MissingDupe;
    }
}

test "handleClientDisconnect: dead `defer free(clients)` branch is removed" {
    // The old `handleClientDisconnect` had a `if (listClients) |clients| { defer di.allocator.free(clients); ... }`
    // branch that was dead code (unregisterSessionClient was called
    // first, so the get returned null) but is now a trap: with the
    // new owned-return API, the get returns a real slice and the
    // defer would free it TWICE (once here, once by its actual owner).
    //
    // Pin the cleanup: the trap branch must be gone.
    const source = try readProjectFile("src/root.zig");
    defer testing.allocator.free(source);

    // We check the function body by searching for the pattern that
    // USED to be there. The pattern is distinctive enough that a
    // substring match is safe.
    const trap_pattern = "defer di.allocator.free(clients)";
    if (std.mem.indexOf(u8, source, trap_pattern) != null) {
        std.debug.print(
            "FAIL: src/root.zig still has `{s}` — handleClientDisconnect will double-free the client_ids slice returned by getListClientsForSession\n",
            .{trap_pattern},
        );
        return error.DoubleFreeTrap;
    }
}
```

- [ ] **Step 2: Register the new test in `test_runner.zig`**

Modify `src/ai_workflow/tui/test_runner.zig` — add a new line inside the `test {}` block (any position is fine, but keep it grouped with the http_handlers tests):

```zig
test {

    _ = @import("handle_tool_test.zig");
    _ = @import("migration_performance_indexes_test.zig");
    _ = @import("notifications_test.zig");
    _ = @import("parse_diff_view_test.zig");
    _ = @import("save_agent_test.zig");
    _ = @import("save_skill_test.zig");
    _ = @import("http_handlers/nalar_config_put_test.zig");
    _ = @import("http_handlers/nalar_config_profile_delete_test.zig");
    _ = @import("http_handlers/sse_handshake_test.zig");
    _ = @import("http_handlers/sse_callback_client_ids_free_test.zig"); // NEW
    _ = @import("http_handlers/tasks_update_test.zig");
    // _ = @import("session_helpers_test.zig"); // DISABLED - requires std.Io which needs Init
    // _ = @import("session_table_test.zig"); // DISABLED - requires std.Io which needs Init
    _ = @import("transform_llm_history_to_agent_messages_test.zig");
    // _ = @import("extract_base64_image_urls_test.zig"); // DISABLED - 9 failing tests (investigation shows std.testing.expectEqualStrings has a bug with literal strings)
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
}
```

- [ ] **Step 3: Run the test to verify it FAILS on the current bug**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | head -n 60
```

Expected: the three new tests fail with `error.MissingFree` (the 4 SSE handlers don't have `defer allocator.free(client_ids)` yet) and `error.MissingDupe` (`getListClientsForSession` doesn't dupe yet). The third test (`handleClientDisconnect: dead defer free(clients) branch is removed`) should PASS on the current code because the dead branch is still present — the assertion is "must be removed", so passing here means the file still has it, which is what we want at this stage.

Capture the failure output. This is the "red" of red-green-refactor.

---

## Chunk 2: Fix the Source Function

### Task 2.1: Make `getListClientsForSession` return an owned dupe

**Files:**
- Modify: `src/root.zig:235-247`

- [ ] **Step 1: Replace the function body**

In `src/root.zig`, find the existing function:

```zig
/// Get list of client_ids for a session
/// Returns owned memory that caller must free, or null if session not found
pub fn getListClientsForSession(session_id: []const u8, allocator: std.mem.Allocator, is_use_lock: bool) !?[][16]u8 {
    _ = is_use_lock;
    _ = allocator;
    const di = try getSingleton();
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);

    const list = di.session_to_client_ids.get(session_id) orelse return null;
    if (list.items.len == 0) return null;

    return list.items;
}
```

And replace it with:

```zig
/// Get list of client_ids for a session.
///
/// Returns an OWNED, heap-copied slice. The caller MUST free the
/// returned slice with `allocator.free(slice)` (or `defer
/// allocator.free(slice)`) when done. Returns `null` if the
/// session is not registered or has zero clients.
///
/// IMPORTANT: this function previously returned a borrowed slice
/// into `di.session_to_client_ids`'s internal `ArrayListUnmanaged`,
/// which caused a use-after-free in every SSE callback that
/// iterated the slice without holding the `session_map_lock`. A
/// failed `sendToClient` could synchronously trigger
/// `unregisterSessionClient` (via `removeClient` → `on_disconnect`
/// → `handleClientDisconnect`), freeing the backing array while
/// the outer `for` loop was still iterating it. The `dupe` here
/// breaks that aliasing: the returned slice is independent of the
/// map's internal storage, so it survives concurrent `fetchRemove`
/// + `list.deinit` calls.
///
/// The `allocator` argument is now used (it was `_ = allocator;`
/// before, which is exactly the smell that pointed at the bug).
pub fn getListClientsForSession(
    session_id: []const u8,
    allocator: std.mem.Allocator,
    is_use_lock: bool,
) !?[][16]u8 {
    _ = is_use_lock;
    const di = try getSingleton();
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);

    const list = di.session_to_client_ids.get(session_id) orelse return null;
    if (list.items.len == 0) return null;

    // OWNED COPY: caller frees. Snapshot is taken under the lock
    // so the slice length is consistent, but the backing memory
    // is now independent of the map's internal storage.
    return try allocator.dupe([16]u8, list.items);
}
```

- [ ] **Step 2: Build to confirm the API change compiles**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 40
```

Expected: no new errors. (The callers in the SSE handlers will compile, because `defer allocator.free(...)` is a no-op on `null` and the slice return type is unchanged.)

If you see a compile error here, STOP — do not proceed to Task 2.2. The most likely cause is a stray caller that frees the returned slice twice. Use `rg "getListClientsForSession" src/` to find all callers and audit each one.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/root.zig
git commit -m "fix(sse): getListClientsForSession returns owned dupe, not borrowed slice

The 4 SSE callbacks (llm_history_sse, worker_sse, sessions_sse,
queue_messages_sse) iterated a slice borrowed from
session_to_client_ids's internal ArrayListUnmanaged. A failed
sendToClient synchronously triggers removeClient → on_disconnect
→ handleClientDisconnect → unregisterSessionClient, which
list.deinit()s the backing array. The outer for loop then reads
freed memory and SIGABRTs.

This is the source-of-truth fix: return an allocator.dupe copy
that survives concurrent map mutations. Each caller must now
add a `defer allocator.free(client_ids)` to its callback.

Bug first observed in llm_history_sse.zig:47 during LLM
streaming; the other 3 handlers have the same pattern and the
same latent bug."
```

---

## Chunk 3: Add `defer free` to Each SSE Callback

Each of the 4 SSE callbacks needs the same surgical patch. Apply the patch in this order: `llm_history_sse.zig` (the one that actually crashed) first, then the other 3.

### Task 3.1: Patch `llm_history_sse.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/llm_history_sse.zig:18-21`

- [ ] **Step 1: Apply the patch**

In `src/ai_workflow/tui/http_handlers/llm_history_sse.zig`, find the lines:

```zig
        // Get ALL client_ids for this session, not just the first
        const maybe_clients = ai_mod.getListClientsForSession(session_id, allocator, false) catch return;
        const client_ids = maybe_clients orelse return;

        if (client_ids.len == 0) return;
```

And replace with:

```zig
        // Get ALL client_ids for this session, not just the first.
        // The returned slice is OWNED — we MUST free it when done.
        // The free prevents the use-after-free: without it, the
        // backing ArrayListUnmanaged could be freed by an
        // unregisterSessionClient triggered inside the for loop
        // (via sendToClient → removeClient → on_disconnect →
        // handleClientDisconnect), corrupting the slice we are
        // iterating.
        const maybe_clients = ai_mod.getListClientsForSession(session_id, allocator, false) catch return;
        const client_ids = maybe_clients orelse return;
        defer allocator.free(client_ids);

        if (client_ids.len == 0) return;
```

- [ ] **Step 2: Build to confirm**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 20
```

Expected: no errors. The 3 lines added compile cleanly.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/llm_history_sse.zig
git commit -m "fix(sse): free owned client_ids slice in llm_history_sse callback

Companion to the getListClientsForSession owned-return fix. The
defer must come immediately after the orelse — it fires on every
return path (early `client_ids.len == 0` return, the `data.data.len
== 0` branch, the line-by-line split loop, and the toOwnedSlice
catch path) and on the normal fallthrough, so the slice is
always freed exactly once."
```

### Task 3.2: Patch `worker_sse.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/worker_sse.zig:15-19`

- [ ] **Step 1: Apply the patch**

In `src/ai_workflow/tui/http_handlers/worker_sse.zig`, find the lines:

```zig
        // Get ALL client_ids for "workers" routing, not just the first
        const maybe_clients = ai_mod.getListClientsForSession("workers", allocator, false) catch return;
        const client_ids = maybe_clients orelse return;

        if (client_ids.len == 0) return;
```

And replace with:

```zig
        // Get ALL client_ids for "workers" routing, not just the first.
        // The returned slice is OWNED — we MUST free it when done.
        // See llm_history_sse.zig for the full use-after-free trace.
        const maybe_clients = ai_mod.getListClientsForSession("workers", allocator, false) catch return;
        const client_ids = maybe_clients orelse return;
        defer allocator.free(client_ids);

        if (client_ids.len == 0) return;
```

- [ ] **Step 2: Build to confirm**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/worker_sse.zig
git commit -m "fix(sse): free owned client_ids slice in worker_sse callback"
```

### Task 3.3: Patch `sessions_sse.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/sessions_sse.zig:16-20`

- [ ] **Step 1: Apply the patch**

In `src/ai_workflow/tui/http_handlers/sessions_sse.zig`, find the lines:

```zig
        // Get ALL client_ids for "sessions" routing, not just the first
        const maybe_clients = ai_mod.getListClientsForSession("sessions", allocator, false) catch return;
        const client_ids = maybe_clients orelse return;

        if (client_ids.len == 0) return;
```

And replace with:

```zig
        // Get ALL client_ids for "sessions" routing, not just the first.
        // The returned slice is OWNED — we MUST free it when done.
        // See llm_history_sse.zig for the full use-after-free trace.
        const maybe_clients = ai_mod.getListClientsForSession("sessions", allocator, false) catch return;
        const client_ids = maybe_clients orelse return;
        defer allocator.free(client_ids);

        if (client_ids.len == 0) return;
```

- [ ] **Step 2: Build to confirm**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/sessions_sse.zig
git commit -m "fix(sse): free owned client_ids slice in sessions_sse callback"
```

### Task 3.4: Patch `queue_messages_sse.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig:22-32`

- [ ] **Step 1: Apply the patch**

In `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig`, find the lines:

```zig
        // Get ALL client_ids for this queue_messages session, not just the first
        const maybe_clients = ai_mod.getListClientsForSession(copy_key_for_event_bus, allocator, false) catch return;
        const client_ids = maybe_clients orelse {
            std.debug.print("SSE_QUEUE_DEBUG: no clients registered for session {s}\n", .{data.session_id});
            return;
        };

        if (client_ids.len == 0) {
            std.debug.print("SSE_QUEUE_DEBUG: no client registered for session {s}\n", .{data.session_id});
            return;
        }
```

And replace with:

```zig
        // Get ALL client_ids for this queue_messages session, not just the first.
        // The returned slice is OWNED — we MUST free it when done.
        // See llm_history_sse.zig for the full use-after-free trace.
        const maybe_clients = ai_mod.getListClientsForSession(copy_key_for_event_bus, allocator, false) catch return;
        const client_ids = maybe_clients orelse {
            std.debug.print("SSE_QUEUE_DEBUG: no clients registered for session {s}\n", .{data.session_id});
            return;
        };
        defer allocator.free(client_ids);

        if (client_ids.len == 0) {
            std.debug.print("SSE_QUEUE_DEBUG: no client registered for session {s}\n", .{data.session_id});
            return;
        }
```

- [ ] **Step 2: Build to confirm**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/queue_messages_sse.zig
git commit -m "fix(sse): free owned client_ids slice in queue_messages_sse callback"
```

---

## Chunk 4: Remove the Latent Double-Free Trap in `handleClientDisconnect`

### Task 4.1: Simplify the dead branch

**Files:**
- Modify: `src/root.zig:298-311`

- [ ] **Step 1: Replace the dead branch with the unconditional unsubscribe**

In `src/root.zig`, find the existing block in `handleClientDisconnect` (lines 298-311):

```zig
        const listClients = getListClientsForSession(session_id, di.allocator, false) catch |err| {
            std.debug.print("SSE_DEBUG: Failed to get clients for session {s}: {any}\n", .{ session_id, err });
            return;
        };

        if (listClients) |clients| {
            defer di.allocator.free(clients);
            if (clients.len == 0) {
                ev_bus.unsubscribe(session_id);
            }
        } else {
            ev_bus.unsubscribe(session_id);
        }
    }
}
```

And replace with:

```zig
        // No more clients are registered for this session (we
        // just removed the last one above). Unsubscribe the
        // event-bus listener so the next emit to this session_id
        // is a no-op. We do NOT call getListClientsForSession
        // here — that would return an owned slice that the
        // caller of handleClientDisconnect never asked for, and
        // the `defer free` would be the wrong lifetime.
        ev_bus.unsubscribe(session_id);
    }
}
```

- [ ] **Step 2: Build to confirm**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/root.zig
git commit -m "refactor(sse): remove dead double-free trap in handleClientDisconnect

The old `if (listClients) |clients| { defer di.allocator.free(clients); ... }`
branch was unreachable (unregisterSessionClient had already
removed the map entry, so getListClientsForSession returned
null). With the new owned-return API, the trap becomes a real
leak/double-free: the get returns a real owned slice, the defer
frees it here, and there's no one else to free it — the listener
table still has the session_id key but no one can find it.

Simplify to the unconditional `ev_bus.unsubscribe(session_id)`
that was always the effective behavior."
```

---

## Chunk 5: Verify All Tests Pass

### Task 5.1: Run the new regression tests

- [ ] **Step 1: Run the three new tests**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | tail -n 40
```

Expected: the three new tests in `sse_callback_client_ids_free_test.zig` now PASS:
- "SSE callbacks: every handler frees the client_ids slice it borrows"
- "getListClientsForSession: returns an owned dupe copy"
- "handleClientDisconnect: dead `defer free(clients)` branch is removed"

If any of the three FAIL, STOP. Re-read the patch you applied. The most common failure is missing the new `defer allocator.free(client_ids)` line in one of the 4 handlers.

- [ ] **Step 2: Run the full test suite to confirm no regressions**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | tail -n 20
```

Expected: same number of PASS/FAIL counts as the last known-good run (look in `.nalar/tasks.md` or the most recent CI output for the baseline). The 3 pre-existing test files that are disabled in `test_runner.zig` (session_helpers, session_table, extract_base64_image_urls, session_db) should remain disabled — do NOT re-enable them in this PR.

- [ ] **Step 3: Run the existing SSE handshake test to make sure the changes don't break the connected-event contract**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | rg "SSE handshake|sse_handshake"
```

Expected: "SSE handshake: all 4 registered stream handlers send the connected event" PASSES. If it fails, your patch accidentally removed one of the `connected_event` blocks.

- [ ] **Step 4: Commit any test-runner / test-file changes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/sse_callback_client_ids_free_test.zig
git add src/ai_workflow/tui/test_runner.zig
git commit -m "test(sse): pin client_ids ownership contract via source-level checks

Three new tests in sse_callback_client_ids_free_test.zig:
  1. Every SSE callback frees the client_ids slice it borrows.
  2. getListClientsForSession returns an owned dupe, not a
     borrowed slice into session_to_client_ids.
  3. handleClientDisconnect no longer has the dead
     `defer di.allocator.free(clients)` branch that would
     become a double-free trap with the new owned-return API.

Static source-level checks (reads the .zig files at test time)
match the sse_handshake_test.zig pattern. A behavioral race
test was considered and dropped: the bug is non-deterministic
and the static checks directly test the contract."
```

---

## Chunk 6: Manual Integration Test (Real Server, Real Browser)

The unit tests prove the static contract. The manual test proves the runtime fix.

### Task 6.1: Reproduce the original crash scenario, then verify it's fixed

- [ ] **Step 1: Build the server in debug mode (faster iteration, ASAN-friendly)**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build -Doptimize=Debug 2>&1 | tail -n 5
```

Expected: build succeeds. (Use the project's standard debug invocation if different — check `build.zig` for the conventional flag.)

- [ ] **Step 2: Start the server on the test port (NOT 8081)**

The project has a strict rule: **never kill or restart process `nalar` on port 8081**. Use port 8080 for testing.

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 --process nalar_test 2>&1 | tee /tmp/nalar-8080.log &
echo "PID: $!"
```

Expected: the server starts and listens on `:8080`. The PID is captured for later cleanup.

- [ ] **Step 3: Open the desktop frontend pointed at port 8080**

Open the chat view in the browser/desktop app configured to talk to `localhost:8080`. Start a chat, send a message, and watch the SSE stream start.

- [ ] **Step 4: Trigger the original crash — close one tab mid-stream**

With the LLM streaming, **forcibly close the SSE connection** (kill the browser tab, or `kill -9` the client process if you can identify it). The desktop app's other connected tabs (if any) should keep receiving events, and the server should NOT crash.

Before the fix: server crashes with the SIGABRT stack trace in the report.
After the fix: server continues, other clients keep receiving events, the log shows the expected `SSE_DEBUG` line for the disconnect.

- [ ] **Step 5: Trigger the asynchronous variant — let the heartbeat time out a client**

Wait ~30 seconds without interacting with the SSE-connected tab. The `sendHeartbeat` thread will detect the dead connection and call `removeClient` from a different thread than the streaming callback. Watch the server log.

Expected: no crash. Log shows the heartbeat failure path and the disconnect cleanup. Other clients (if any) keep receiving events.

- [ ] **Step 6: Kill the test server cleanly**

Run:
```bash
kill <PID from Step 2>
```

Expected: clean shutdown. The `/tmp/nalar-8080.log` ends with the standard shutdown banner.

- [ ] **Step 7: Commit any test artifacts**

If you generated any test logs, scripts, or fixtures, commit them. Otherwise, this chunk produces no commits.

---

## Verification Checklist (run before marking the plan done)

- [ ] `zig build` succeeds with no new errors
- [ ] `zig build test` reports all 3 new tests in `sse_callback_client_ids_free_test.zig` as PASS
- [ ] `zig build test` reports the existing `sse_handshake_test.zig` as PASS (no regression)
- [ ] `zig build test` reports the same number of total PASS / FAIL as the baseline
- [ ] Server on port 8080 survives a mid-stream SSE client disconnect without crashing
- [ ] Server on port 8080 survives an asynchronous heartbeat-induced disconnect without crashing
- [ ] Port 8081 and the existing `nalar` process were NOT touched (verify with `ss -lntp | grep 8081` and `pgrep -af nalar`)
- [ ] All 6 commits land cleanly on the working branch with conventional-commit messages

---

## Rollback Plan

If a regression is caught AFTER merging, the fixes are isolated enough to revert in 2 commits:

1. **Revert `handleClientDisconnect` cleanup (Chunk 4)** — restores the old `if (listClients) |clients| { defer di.allocator.free(clients); ... }` branch. Independent of the other changes; revert first to minimize the leak window.
2. **Revert the 4 SSE callback `defer free` patches (Chunk 3)** — keeps `getListClientsForSession` returning an owned dupe but the callers don't free it. This is a pure memory leak, not a crash. Safe to leave running for a few hours while the next fix is prepared.
3. **(Only if needed) Revert `getListClientsForSession` to return the borrowed slice (Chunk 2)** — restores the original bug. Do this only as a last resort; the leak is the lesser evil compared to the SIGABRT.

The new regression test file (Chunk 1) should be KEPT in place during rollback — it pins the contract and will keep the bug from being silently re-introduced.

---

## Risk Notes

- **Performance**: `allocator.dupe([16]u8, list.items)` allocates a fresh `[N][16]u8` per call. For typical N=1..3 clients, this is ~16-48 bytes per SSE event. LLM streaming emits ~20 chunks/sec for a few seconds. Total allocation: a few KB. Not a meaningful cost. If profiling later shows otherwise, switch to a small-object free-list in the singleton.
- **Lock ordering**: `getListClientsForSession` takes `session_map_lock`. `SseManager` takes its own `sse_manager.lock`. The two are independent — no nested locking introduced. The `event_bus` is lock-free for `emit`. No new deadlock paths.
- **Allocator lifetime**: The new `defer free` uses `di.allocator` (the long-lived app allocator), same as the surrounding code. The slice survives across the `for` loop and the `sendToClient` call, then is freed at function return. Lifetime is correct.
- **Other callers of `getListClientsForSession`**: The 4 SSE handlers are the only production callers. The internal call from `handleClientDisconnect` is removed in Chunk 4, so after this plan lands, the function has exactly 4 production callers, all updated.

---

## What the Plan Does NOT Do (explicit non-goals)

- Does NOT add a behavioral race-condition test (rejected — see Task 1.1 step 1 docstring for why).
- Does NOT switch to a per-client listener model (where the SSE handler subscribes a callback per client instead of broadcasting). That is a larger refactor with a different architecture.
- Does NOT change the event_bus API (no mutex, no copy-on-emit). The current lock-free emit is fine; the bug is in the consumer, not the producer.
- Does NOT change `sendToClient` to defer disconnect cleanup. The synchronous `removeClient` is correct in the SseManager's terms — the caller has to be safe against the disconnect happening synchronously.
- Does NOT re-enable the 4 disabled test files in `test_runner.zig`. Those are pre-existing failures unrelated to this bug.
