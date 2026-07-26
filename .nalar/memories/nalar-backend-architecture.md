# nalar — backend architecture patterns

This file consolidates nalar-specific backend patterns (HTTP, FD management, agent workflow, cross-platform work). For routine-specific patterns, see `nalar-data-and-routines.md`. For frontend patterns, see `nalar-frontend-patterns.md`. For build/CI infra, see `nalar-infra-and-build.md`.

---

## Custom HTTP server uses per-request arena allocator

`GinwaServer` in `src/modules/custom_http_server/src/http_server.zig` gives every HTTP request its own `std.heap.ArenaAllocator` built on the long-lived server allocator. The arena is `.deinit()`'d by `GinwaServer.handle` when the request finishes, so **every allocation with `ctx.allocator` is automatically freed** — no explicit `defer` needed.

```zig
// /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/modules/custom_http_server/src/http_server.zig
// ~line 164-179: per-request arena created; ~line 175-176: arena destroyed on handle exit
const arena = self.allocator.create(std.heap.ArenaAllocator);
arena.* = std.heap.ArenaAllocator.init(self.allocator);
// ...
fn handle(server: *GinwaServer, arena_allocator: *std.heap.ArenaAllocator, fd: i32) void {
    arena_allocator.deinit();
    server.allocator.destroy(arena_allocator);
}
```

**In HTTP handlers, don't add `defer ... .deinit()` or `defer ... .free(...)` for request-scoped allocations.** The arena does it. Just let the allocations go out of scope and trust the runtime cleanup.

```zig
// ✅ Correct — no defer needed
const parsed = try std.json.parseFromSlice(MyStruct, allocator, body, .{});
const buf = try allocator.alloc(u8, 1024);
const typed = try allocator.create(MyType);
typed.* = ...;
return res.jsonResponse(...);
```

**Exceptions — when NOT to skip the defer:**

- Allocations on a different allocator than `ctx.allocator` (e.g., a shared `di.allocator` that lives across requests) DO need explicit cleanup.
- The `defer errdefer allocator.free(out)` pattern for transient scratch buffers inside a `blk:` is still fine — frees on error during construction, not at request end.

**When this bites:** adding a `defer` to "be safe" in a new HTTP handler; following convention from Zig stdlib examples (`std.json.parseFromSlice` returns `Parsed(T)` that the docs say you must `deinit()`); adding a `defer` because another handler in the same project has one (codebase is inconsistent on this — convention is "don't").

---

## HTTP handler thin-wrapper pattern (CRUD endpoints)

When adding a new thin-wrapper HTTP handler in `src/ai_workflow/tui/http_handlers/` that delegates to a helper in `src/modules/agent/tools/*.zig`:

### 1. Use `req.params.get("name")`, NOT `req.path_params.get("name")`

The `HttpRequest` struct (`src/modules/custom_http_server/src/http_parser.zig:69`) has `params: std.StringHashMap([]const u8)`. `path_params` does NOT exist.

### 2. Use `std.json.parseFromSliceLeaky`, NOT `std.json.parseFromSlice`

`parseFromSlice` returns `Parsed(T)` with internal ArenaAllocator requiring explicit `deinit()`. The per-request `ctx.allocator` IS an arena and reaps everything — use Leaky.

```zig
// Correct (this codebase):
const parsed = std.json.parseFromSliceLeaky(MyBody, allocator, req.body, .{}) catch {
    return res.jsonResponse(.{ .status_code = 400, .data = "..." });
};
// parsed.name, parsed.foo, etc. directly — no .value accessor
```

Existing precedent: `task_create.zig:44`, `task_update.zig:49`, `session_create.zig:69`, `session_update.zig:41` all use Leaky.

### 3. Response shape — typed struct + `std.json.Stringify.valueAlloc`

Hand-rolled `std.fmt.allocPrint` does NOT escape quotes/backslashes in user-provided content. Use the typed struct pattern:

```zig
const MyResponse = struct {
    my_field: ?MyPayload = null,
    error_message: ?[]const u8 = null,
};

return res.jsonResponse(.{
    .status_code = 200,
    .data = try std.json.Stringify.valueAlloc(allocator, MyResponse{ .my_field = payload }, .{}),
});
```

The `?T = null` fields let `valueAlloc` produce `{"my_field":null,"error_message":null}` for the error case.

**Exception:** for simple response shapes that don't contain user-provided content (`{"id":"task_123","success":true}`), hand-rolled `std.fmt.allocPrint` is fine.

### 4. Status code conventions

- **200 OK** — GET, PUT, DELETE success
- **201 Created** — POST that creates a new resource
- **400 Bad Request** — invalid name, missing body, bad JSON, helper failure
- **404 Not Found** — GET/PUT on a missing resource
- **409 Conflict** — POST on a duplicate resource

Idempotent delete: returns true for "deleted" AND "was already missing" → DELETE handler always returns 200 with `{success:true,name:"..."}`.

### 5. Manual smoke test on port 8080 (NOT 8081)

Another `nalar` process is always running on port 8081. NEVER kill it, NEVER use it for new work. Use port 8080.

`zig build run` depends on `install` → `install:nalar-desktop` → `codegen:webapp-assets` (pre-existing broken on some branches). Workaround: `zig build install:linux:system` builds the binary at `zig-out/bin/nalar` (cp fails harmlessly on permission). Then `./zig-out/bin/nalar --port 8080`.

---

## `image_urls` (array) vs `image_url` (string) — the two field shapes

The nalar backend has TWO related fields for image attachments:

| Field | Type | Lives in | Used by |
|---|---|---|---|
| `image_urls` (plural) | `?[][]const u8` | `llm_history.SaveMessageInput`, `TUIHistory` | `saveMessage`, `models.TUIHistory` |
| `image_url` (singular) | `?[]const u8` | `OnEventInputLLMHistory`, `SseEventLLMHistory` | `onEventSendLLMHistory`, REST `image_url` field |

Wire format is pipe-separated (`"url1|url2|url3"`). Plural is the in-memory split form.

**Mix-up symptom:** Build fails with `error: no field named 'image_url' in struct 'ai_workflow.tui.llm_history.SaveMessageInput'`.

**Correct pattern in workflow.zig:**

```zig
// 1. DB write — use plural ARRAY field
_ = llm_history.saveMessage(allocator, io, db, .{
    ...
    .image_urls = image_urls,   // ?[][]const u8
});

// 2. SSE event — use singular STRING field
on_event_sent.onEventSendLLMHistory(allocator, .{
    ...
    .image_url = if (queued.image_url.len > 0) queued.image_url else null,
});
```

**Why two shapes:** array is what LLM vision `content_parts` need (one per image); string fits in a TEXT column and is what REST responses return. Frontend splits via `msg.image_url.split('|')`.

---

## TUIHistory has BOTH `tools` and `tool_call_id` fields

The `TUIHistory` struct in `src/ai_workflow/tui/models.zig` has TWO fields:

- `tools: []const u8` (line 19) — the **tool_calls JSON array** (`[{"id":"...","function":{"name":"...","arguments":"..."}}]` string).
- `tool_call_id: ?[]const u8 = null` (line 36) — the **tool_call_id string** that pairs a tool-result back to its tool_call.

**Symptom of getting it wrong:**

```
try std.testing.expect(std.mem.eql(u8, msg.tool_call_id.?, "tool_call_id_123"));
```

`msg.tool_call_id` is `""` (or null) instead of the expected value. The `deinit` handles `tool_call_id` correctly — no special cleanup needed.

**When constructing TUIHistory for a tool-result message, set BOTH fields:**

```zig
var history = TUIHistory{
    .id = ...,
    .role = try allocator.dupe(u8, "tool"),
    .tools = try allocator.dupe(u8, ""),                       // no tool_calls JSON for tool results
    .tool_call_id = try allocator.dupe(u8, "tool_call_id_123"), // the tool_call_id of the call this is the result of
    .response_content = try allocator.dupe(u8, "Tool result here"),
    // ...
};
```

The implementation reads from `tool_call_id`, NOT `tools`. Don't be misled by field name similarity to SQL columns or old code.

---

## `stream_reader.err` is null but `body_err` shows the real cause

When streaming code in `src/modules/agent/Agent.zig:1547` logs `[STREAM] ReadFailed with null underlying (chunks=0, bytes=0)`, the diagnostic is **incomplete**, not the error itself.

A Zig 0.16 `std.http.Client` connection has TWO distinct error fields that can fire when `bodyReader` returns `error.ReadFailed`:

| Field | Lives on | Set by | Meaning |
|---|---|---|---|
| `conn.stream_reader.err` | `Io.net.Stream.Reader` | `Io/net.zig:1306` when `io.vtable.netRead` fails | Transport-level (RST, ECONNRESET, EPIPE) |
| `response.request.reader.body_err` | `http.Reader` | `chunkedStream` / `chunkedDiscard` in `std/http.zig` | HTTP-level (HttpChunkInvalid, HttpChunkTruncated, HttpHeadersOversize) |

The current diagnostic only checks transport-level. **When the failure is HTTP-level (chunked encoding issue), `stream_reader.err` stays null.**

**Fix — check BOTH layers:**

```zig
if (err == error.ReadFailed) {
    const conn = response.request.connection orelse { ... };
    const http_err_opt: ?std.http.Reader.BodyError = response.request.reader.body_err;
    const transport_err_opt: ?std.Io.net.Stream.Reader.Error = conn.stream_reader.err;
    if (http_err_opt) |he| {
        self.log_fmt(.err, "[STREAM] http error: {s} (chunks={}, bytes={}, transport={?s})", .{
            @errorName(he), chunk_count, total_bytes_read,
            if (transport_err_opt) |t| @errorName(t) else null,
        });
    } else if (transport_err_opt) |te| {
        self.log_fmt(.err, "[STREAM] transport error: {s} (chunks={}, bytes={})", .{...});
    } else {
        self.log_fmt(.err, "[STREAM] ReadFailed with null underlying and no body_err", .{...});
    }
}
```

**Why the server sends 200 + chunked then closes cleanly:**
- LLM server accepted request, started streaming, then **panicked / OOM / crashed** before sending data.
- Proxy in front (CDN, API gateway) killed connection due to slow start / body size limit / response header validation.
- LLM server's response generator crashed but HTTP layer sent headers (200 OK is sometimes optimistic).

**When this bites:** user-visible reports of `ReadFailed with null underlying` in nalar backend logs.

---

## SSE `net::ERR_INCOMPLETE_CHUNKED_ENCODING` and auto-reconnect

`net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` is a Chromium-level network error. The server started a chunked HTTP response but the TCP connection was terminated **before the terminating `0\r\n\r\n` chunk arrived**.

**What triggers it:** server process died mid-stream, Zig `connection.close()` before all SSE bytes flushed, network drop, server panic, etc. The `(OK)` in the error means the **HTTP status line was 200** — connection completed headers and started streaming. "Incomplete chunked" means **body framing was never closed properly**.

**Limitation for the LLM stream specifically:** `/api/llm/stream/<session_id>` is one-shot per message. If the TCP connection drops mid-message, auto-reconnecting **does not retrieve the partial response** — the SSE spec doesn't support stream resumption; `sse_manager.zig` doesn't emit `retry:`. So a reconnect after mid-stream drop typically results in a fresh stream that has no in-flight generation for the session → effectively stuck.

**Fix to consider (out of scope here):** backend tracks "in-flight generation" state per session and emits synthetic `finish_reason: 'stream_interrupted'` when a reconnected client attaches to a session whose LLM call already finished.

---

## Three FD leaks that together produce `ProcessFdQuotaExceeded`

All three are variants of the same bug class: **a struct that owns resources (sockets, pipes, or a Child) is created but its cleanup is never called.**

### Source A — Agent.httpClient connection pool leak (88% of leaked FDs)

**File:** `src/ai_workflow/tui/workflow.zig:686-717` (`callDynamicAgentNew`)

`var dynamic_agent = try agent.Agent.init(allocator, io)` at line 700 — no matching `defer dynamic_agent.deinit()`. `Agent.deinit()` calls `self.httpClient.deinit()` which closes pooled HTTP keep-alive sockets. The other 2 `Agent.init` call sites correctly have the defer.

**Fix:** 1-line `defer dynamic_agent.deinit();` + 8-line context comment.

### Source B — `nalar_mod.http_client.HttpClient` curl-subprocess pipe leak

**File:** `src/modules/http/HttpClient.zig`

`std.process.spawn` to run `bash -c "curl ..."` creates 2 pipe FDs. The spawn is **never** followed by `child.deinit()`. In Zig 0.16:

- **`std.process.Child.deinit(io)` does NOT exist** — only `kill(io)` and `wait(io)` exist.
- `child.wait(io)` triggers `childCleanupPosix` via defer that closes pipe FDs, **only on the success path** (and only if `wait()` is called).
- `child.kill(io)` calls `childCleanupPosix` AFTER the kill, so it DOES close pipes.

**Fix:** A `defer` block immediately after each spawn that calls `out.close(self.io)` and `err_pipe.close(self.io)` on the `std.Io.File` handles, then nulls the fields. On success, `wait()` already nulled them via `childCleanupPosix`, so the defer is a no-op. On error paths, it's what actually closes the FDs.

3 static-contract regression tests in `src/modules/http/http_client_fd_leak_test.zig` lock in the fix.

### Source C — `bash.zig` foreground path leaks 2 FDs per SUCCESSFUL call (NOT just timeout)

The bash tool's foreground path uses `waitPidBounded` (raw libc `waitpid`) instead of `child.wait(io)` to avoid hanging on D-state descendants. But `waitpid` does NOT trigger Zig 0.16's `childCleanupPosix` defer — only `child.wait(io)` does. The pipe FDs were never closed in the success path.

**Symptom**: at ~556 FDs in a 70-minute agent session, ~555 of which are orphan pipes (only the parent process holds each pipe inode; the child end was closed when bash exited). Bash was the most-called tool (17× in the recent log vs ~8 for the next-most-called). Each call leaks 2 FDs (stdout + stderr parent read ends) — the stdin pipe is properly closed by the parent after writing at `bash.zig:454`.

**Root cause**: `bash.zig` foreground path (`src/modules/agent/tools/bash.zig:404-770`) has TWO switch statements, each with `.reaped`, `.no_child`, `.grace_period_expired`, and `.unexpected_error` arms. The `.grace_period_expired`/`.unexpected_error` arms DID close pipes inline (defending against D-state). The `.reaped`/`.no_child` arms (the happy path) broke out of the loop WITHOUT closing pipes. After the 2026-07-15 IO.Select→waitPidBounded refactor, nobody noticed the contract was broken.

**Fix** (commit `2f873dbc`, plan `docs/SPEC.md` §3.5 — bash-tool-pipe-leak): add a single post-loop pipe close AFTER `child_term = blk: { ... };` exits, BEFORE `stdout_thread.join()`. The block runs once for every code path that exits the loop, removing the per-arm duplication.

```zig
// After: child_term = blk: { ... };
if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
stdout_thread.join();
stderr_thread.join();
```

**Verified**: 5 tests failed in red baseline (4 tightened from `diff <= 2` to `diff == 0`, plus 1 new 100-iter stress test). All 5 pass after the fix. Live session FD count is now stable (was growing at ~2 FDs per 5 seconds before the fix).

**Why `countOpenFds` test helper was hiding the bug**: the previous helper used `ls /proc/self/fd | wc -l` which counts the BASH SUBSHELL's FDs (a fresh process with ~10 FDs), not the parent test process's FDs. Fixed by switching to `ls /proc/$PPID/fd | wc -l` (`$PPID` = bash's parent PID = the test process). Without this helper fix, the test would have passed despite the leak.

### Zig 0.16 std.process.Child API reality

| Method | Exists? | Closes pipes? |
|---|---|---|
| `child.wait(io) !Term` | YES | YES (via defer'd `childCleanupPosix`) |
| `child.kill(io) void` | YES | YES (via defer'd `childCleanupPosix` AFTER the kill) |
| `child.deinit(io) void` | **NO** | N/A — doesn't exist |
| `std.process.spawn` (raw) | YES | NO — only creates pipes, doesn't own them |
| `std.c.waitpid(pid, &status, WNOHANG)` | YES (libc) | NO — doesn't touch the Child struct |
| `std.posix.kill(pid, sig)` | YES (libc) | NO — doesn't touch the Child struct |

**Implications:**
- CODE THAT USES `child.wait(io)`: pipes auto-close via `childCleanupPosix`. ✅
- CODE THAT USES `child.kill(io)`: pipes auto-close via `childCleanupPosix` post-kill. ✅
- CODE THAT USES raw libc `waitpid` (like `waitPidBounded` in bash.zig): pipes do NOT close — caller MUST manually close `child.stdout`/`child.stderr` (and `child.stdin` if it was `.pipe`). ❌
- ANY code that calls `std.posix.kill` to terminate a spawned child MUST also call `child.wait(io)` (or `child.kill(io)`) to close the pipe FDs.
- `std.Io.File` has no destructor — always call `file.close(io)` explicitly.

### Diagnostic recipe

```bash
PID=$(pgrep -f "nalar --port 8081")
echo "FD count: $(ls /proc/$PID/fd | wc -l)"

# What KIND of FDs is leaking? (socket vs pipe vs anon_inode)
ls -la /proc/$PID/fd 2>/dev/null | awk '{print $NF}' | \
  sed 's|.*\[\(.*\)\].*|socket:[\1]|; s|^pipe.*$|pipe|; s|^/dev/null$|devnull|; s|^/tmp.*$|tmpfile|; s|^anon_inode.*$|anon_inode|; s|^/home.*$|homefile|; s|^/proc.*$|procfile|; s|^socket:.*$|socket|' | \
  sort | uniq -c | sort -rn | head -10

# Orphan pipe detection (the smoking gun for "subprocess pipe leak"):
for fd in /proc/$PID/fd/*; do
    target=$(readlink "$fd" 2>/dev/null)
    [[ "$target" == pipe:* ]] || continue
    inode=$(echo "$target" | sed 's/pipe:\[\(.*\)\]/\1/')
    # If ONLY this process holds the pipe inode, the child end closed
    # (child exited) but the parent end is still open — LEAK.
    OTHER=$(ls -la /proc/*/fd/* 2>/dev/null | grep -cF "$target")
    if [ "$OTHER" -le 1 ]; then
        echo "ORPHAN PIPE: $fd -> $target"
    fi
done | head -n 30

# FD creation burst analysis (groups FDs by second of creation):
for fd in /proc/$PID/fd/*; do
    stat -c %y /proc/$PID/fd/$fd 2>/dev/null | cut -d. -f1
done | sort | uniq -c | sort -rn | head -20
# Bursts of 6 FDs per 5s = spawn with stdin+stdout+stderr = .pipe each
# (3 pipes × 2 ends = 6 FDs/call). Bursts of 4 FDs = stdin=.close.
```

### Static-analysis recipe for finding new instances

```bash
# 1. Find all struct-init sites that own FDs/handles/resources.
rg -n "var .* = .*Agent\.init\(|var .* = .*\.init\(|var child = try std\.process\.spawn" src/

# 2. For each match, scan the enclosing function (~30 lines) for matching cleanup.
rg -n --multiline "var .* = .*\.init\([^;]+;\s*$" src/ \
  | while IFS=: read -r file line _; do
      end=$((line + 30))
      if ! sed -n "${line},${end}p" "$file" \
           | grep -qE "(defer .*\.deinit|child\.wait|child\.kill|kill\(.*child)"; then
        echo "POTENTIAL LEAK: $file:$line"
      fi
  done

# 3. Also find std.posix.kill uses that may skip child.wait:
rg -n "std\.posix\.kill\([^,]*-child" src/

# 4. Find raw libc waitpid uses that may skip childCleanupPosix:
rg -n "std\.c\.waitpid\(" src/
# Any code using std.c.waitpid MUST manually close pipes — child.wait(io)
# is the only path that triggers childCleanupPosix.
```

---

## `getDbPath.zig` — use `createDirPath` (mkdir-p), NOT `createDirAbsolute`

`src/helpers/db_path.zig` (pre-fix) called `Io.Dir.createDirAbsolute(io, config_dir, .default_dir)` which maps to `posix.mkdirat(AT_FDCWD, absolute_path, mode)`. That syscall only creates the **final** path component. With `/$HOME/.config/nalar` and `/$HOME/.config` missing, returns `ENOENT` → `error.FileNotFound`.

**Fix:** Use the same `openDirAbsolute + createDirPath` pattern as `Config.zig:writeDefaultConfig`:

```zig
var home_dir = Io.Dir.openDirAbsolute(io, home, .{}) catch ...;
defer home_dir.close(io);
home_dir.createDirPath(io, ".config/nalar") catch ...;
```

**When this bites:** any new code that creates a nested user dir (`.config/nalar`, `.local/share/...`, etc.). Always prefer `createDirPath` over `createDirAbsolute` unless you've verified the parents exist.

---

## Cross-compile build is blocked by pre-existing issues

The `zig build install:windows`, `install:macos`, and `install:macos-arm` steps **cannot produce binaries** on a Linux host. Pre-existing issue, not a code bug.

**Symptom:**

```
error: unable to find dynamic system library 'sqlite3' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'ssl' using strategy 'paths_first'. searched paths: none
```

`zig-out/bin/` is empty.

**Root cause 1:** `build.zig`'s `install:linux` step sets library paths, but `install:windows`, `install:macos`, `install:macos-arm` do NOT. The `linkSystemLibrary("sqlite3"/"ssl"/"crypto"/"c")` calls fail at config time because Zig searches `none` paths.

**Root cause 2:** `src/modules/agent/tools/bash_selfkill.zig:8` declares `pub fn get_self_pid() std.c.pid_t { return process.getCurrentProcessId(); }`. On Windows, `std.c.pid_t` is `*anyopaque` → compile error on `if (target_pid == self_pid)`.

**Workaround:** For testing cross-platform code changes, use `zig build-obj -fno-emit-bin -target X` (see `zig-cross-platform.md` for full technique). Don't try to make `install:X` actually work without doing the broader build.zig cross-target sysroot work.

**When this bites:** any task whose plan says "verify cross-compile to Windows/macOS succeeds" — the build will fail regardless of the code being changed.

---

## macOS pre-existing bug in `setReuseAddr`

On macOS, `GinwaServer.init()` crashes:

```
thread N panic: reached unreachable code
src/.../std/posix.zig:1081:23 in setsockopt
    .INVAL => unreachable,
src/.../http_server.zig:88 in setReuseAddr
```

The previous code at `src/modules/custom_http_server/src/http_server.zig:88` had hardcoded `SOL_SOCKET, SO_TYPE` (1, 2) — which is invalid as a SET direction on a listen socket and triggers `EINVAL`. Zig 0.16's `posix.setsockopt` maps `.INVAL` to `@compileError`-time `unreachable`.

**Fix:** Use the stdlib's os-tagged constants:

```zig
const opt: i32 = 1;
try posix.setsockopt(
    sock_fd,
    @intCast(posix.SOL.SOCKET),    // 1 on Linux, 0xffff on macOS
    @intCast(posix.SO.REUSEADDR),  // 0x0004 on both
    std.mem.asBytes(&opt),
);
```

**Never hardcode `1, 2` (or any numeric literal) when calling `setsockopt`** — these constants are OS-specific. Always use `std.posix.SOL.*` and `std.posix.SO.*`.

---

## Sub-agent error messages follow the workflow.zig pattern

The `spawn_sub_agent` tool's `<error>` field is the only error message the PARENT LLM sees when a sub-agent fails. The rich diagnostic that `workflow.zig` saves to the SUB-AGENT's chat history (line 410-475) is NOT visible to the parent — so without a clear message here, the parent has no idea what went wrong.

**Pattern in `src/ai_workflow/tui/tool_registry.zig` `runSubAgent`:**

```
Agent Nalar System error, the actual error is ->>>> <context>
```

For TooManyRetries (mirrors workflow.zig's rich bail):

```
[Agent Nalar System error] sub-agent workflow halted after TooManyRetries (10+ consecutive failures).
This typically indicates a network connectivity issue to the LLM API endpoint,
API rate limit exceeded, authentication/authorization failure, or upstream
service unavailability. The sub-agent's session logs contain the full chain
of errors at each retry attempt — review them before retrying.
```

**Where it lives:** `src/ai_workflow/tui/tool_registry.zig` `runSubAgent`:
- "Failed to create session_id" (line 1188-1198)
- "Failed to copy session_id" (line 1204-1212)
- "Workflow error: TooManyRetries" → rich TooManyRetries diagnostic (line 1238-1268)
- "getLatestMessage: {err}" (line 1272-1283)
- "Failed to copy response" (line 1288-1296)
- "Empty response content" (line 1300-1302)
- "No message found in database" (line 1304-1306)

All 6 paths now use the "Agent Nalar System error, the actual error is ->>>> ..." prefix.

---

## Plan "hint" XML responses (NOT `<error>`) for valid-but-empty cases

When a plan's implementation spec for an LLM tool says "return an error XML" for a valid-but-empty case (e.g., "kanban exists but has 0 columns"), the test expectation often conflicts with that. The plan says wrap the message in `<error>...</error>`; the test says the response must NOT contain `<error>` and must contain a `<columns></columns>` (or equivalent empty body) plus a hint substring.

**User-facing semantic distinction:**
- **Wrong item_id / shape mismatch / DB failure** → caller did something wrong → `<error>` is the right signal.
- **Valid input, but the answer is "0 of N"** → caller did nothing wrong → NOT an error, just empty body + friendly hint.

**When implementing an LLM tool that can return either "wrong input" or "valid input, empty result":**

1. Error case → `<error>...</error>` block with self-correcting hint.
2. Empty-but-valid case → normal response body (e.g., `<columns></columns>`) PLUS a sibling `<hint>...</hint>` block with the friendly message. NO `<error>` wrapper.

```zig
const empty_board_hint: ?[]u8 = if (cols.len == 0) blk: {
    const h = try std.fmt.allocPrint(allocator,
        \\This kanban item has no columns...
    , .{});
    break :blk h;
} else null;
defer if (empty_board_hint) |h| allocator.free(h);

// Render normal XML, then splice the hint before </kanban>:
const xml = try toXml(allocator, input.workspace_id, input.item_id,
    column_summaries.items, task_summaries.items);
if (empty_board_hint) |h| {
    const close_tag = "</kanban>";
    const idx = std.mem.indexOf(u8, xml, close_tag) orelse xml.len;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, xml[0..idx]);
    try out.appendSlice(allocator, "<hint>");
    const escaped_hint = try xmlEscape(allocator, h);
    defer allocator.free(escaped_hint);
    try out.appendSlice(allocator, escaped_hint);
    try out.appendSlice(allocator, "</hint>");
    try out.appendSlice(allocator, xml[idx..]);
    allocator.free(xml);
    return try out.toOwnedSlice(allocator);
}
```

---

## Bulk callsite refactor — `// empty` single-line comment tail misses regex

A regex-based bulk editor that targets a callsite's CLOSER (`        "",\n    );`) will MISS callsites whose last argument is followed by a trailing comment on the same line, because the closer shape is `        "", // empty X` not `        "",\n    );`.

**Symptom:** Added a new parameter to a 14-arg function; ran Python regex `re.compile(r'\n        "",\n    \);')` to insert the new arg. Script reported "16 sites updated" out of 17 expected. After running, `zig build test` failed with `expected 14 argument(s), found 13` at the missed sites.

**Fix options:**

**Option D — verify after running:**

```bash
timeout 180 zig build test --summary all 2>&1 | grep -E 'error:|expected.*argument(s)?'
# finds MISSED TEST callsites
timeout 180 zig build install:linux:system 2>&1 | grep -E 'error:|expected.*argument(s)?'
# finds MISSED PRODUCTION callsites (lazy analysis trap)
```

**Option C — match BOTH closer shapes:**

```python
PATTERN_A = re.compile(r'\n        "",\n    \);')
PATTERN_B = re.compile(r'\n        "",\s*//[^\n]*\n    \);')
```

**Why `zig build test` catches it but only partially:** the test build's module graph reaches callsites from the test file's perspective. If a test file's callsite is missed, `zig build test` will catch it with "expected N argument(s), found M". But `zig build test` does NOT catch missed callsites in non-test files (production code) because the test graph doesn't reach them via lazy analysis. Only `install:linux:system` or full `zig build` does.

**When this bites:** any bulk-rename / bulk-arg-add / bulk-signature-change with a regex finding callsites by shape. Any tool/handler/helper with >5 callsites.

---

## `set_git_worktree clear=true` does NOT delete the branch

The `set_git_worktree` tool with `clear: true` removes the worktree directory and the `git worktree list` registration, but does NOT delete the branch the worktree was on (the auto-derived `worktree/<basename>` branch).

**Symptom:** Created a worktree with `set_git_worktree(path="/abs/path/test-foo")`, called `set_git_worktree(clear=true)`. Worktree is gone, session is un-bound, but `git branch -a` still shows `worktree/test-foo` as orphaned.

**Fix:** After `clear: true`, follow up with:

```bash
git branch -D worktree/<basename>
```

**When this bites:** any test cycle of the tool (create → verify → clear) leaves a dangling branch per test. Test worktrees in `.worktrees/` accumulate over time.

---

## `cwd_override` on `ToolExecContext` is currently UNUSED (dead-letter field)

The `cwd_override: ?[]const u8 = null` field on `ToolExecContext` (added in commit `2626c797`) is declared and accepted by `execSetGitWorktree`'s input struct, but is **never read, never populated, and never mutated anywhere in the dispatch path**.

**Effect:** Calling `set_git_worktree` with `path=/abs/.worktrees/foo` persists the binding to the DB, but the NEXT `execBash` / `execReadFile` / `execWriteFile` / `execTextReplace` / `execGlob` / `execSearch` call still runs in `ctx.cwd` (the session's original cwd), not the worktree path.

**Workaround:** Re-call `set_git_worktree` (returns the path) to refresh, or pass absolute paths in every `bash` invocation.

**Do NOT remove the `cwd_override` field "because it's unused"** — that will block the follow-up that implements the runtime override. **Do NOT write code that depends on `ctx.cwd_override` being populated today** — the field is always `null` at runtime until the follow-up lands.

---

## Related / cross-references

- `nalar-data-and-routines.md` — schema/migration patterns, routine fire pipeline
- `nalar-frontend-patterns.md` — frontend/Vue patterns
- `nalar-infra-and-build.md` — CI, build infrastructure
- `zig-sqlite-patterns.md` — SQLite patterns
- `zig-cross-platform.md` — cross-platform Zig 0.16 patterns
- `zig-build-and-test.md` — lazy analysis, build/test patterns