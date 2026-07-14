# nalar — Three FD leaks that together produce `ProcessFdQuotaExceeded`

This memory supersedes my earlier `process-fd-quota-exceed-2026-07-14-workflow-leak.md`
(which only documented Source A). On 2026-07-14 a coordinated fix landed that addresses
all three concurrent FD leak sources in nalar. All three are variants of the same
bug class: **a struct that owns resources (sockets, pipes, or a Child) is created
but its cleanup is never called.**

## The three sources (in priority order)

### Source A — Agent.httpClient connection pool leak (88% of leaked FDs)

**File**: `src/ai_workflow/tui/workflow.zig:686-717` (`callDynamicAgentNew`)

`var dynamic_agent = try agent.Agent.init(allocator, io)` at line 700 — no
matching `defer dynamic_agent.deinit()`. `Agent.deinit()` calls
`self.httpClient.deinit()` which closes pooled HTTP keep-alive sockets. The
other 2 `Agent.init` call sites (`workflow.zig:637` and `compaction.zig:168`)
correctly have the defer.

**Fix**: 1-line `defer dynamic_agent.deinit();` + 8-line context comment.

### Source B — `nalar_mod.http_client.HttpClient` curl-subprocess pipe leak

**File**: `src/modules/http/HttpClient.zig` (used by
`handle_mcp_tool.zig:127` and `build_messages_for_agent_prompt.zig:377`)

`std.process.spawn` to run `bash -c "curl ..."` creates 2 pipe FDs (stdout +
stderr). The spawn is **never** followed by `child.deinit()`. In Zig 0.16:

- **`std.process.Child.deinit(io)` does NOT exist** — verified by compiling
  a minimal test file. Only `kill(io)` and `wait(io)` exist.
- `child.wait(io)` triggers `childCleanupPosix` via defer that closes the
  pipe FDs, but **only on the success path** (and only if `wait()` is actually
  called).
- `child.kill(io)` calls `childCleanupPosix` AFTER the kill, so it DOES close
  the pipes — but the HttpClient never calls `kill()` either.

So any error path between spawn and `wait()` (OOM in `toOwnedSlice`,
exception in JSON parse, etc.) drops the Child and leaks 2 FDs.

**Fix**: A `defer` block immediately after each spawn that calls
`out.close(self.io)` and `err_pipe.close(self.io)` on the
`std.Io.File` handles, then nulls the fields. On success, `wait()`
has already nulled those fields via `childCleanupPosix`, so the
defer is a no-op. On error paths, it's what actually closes the FDs.

3 static-contract regression tests in
`src/modules/http/http_client_fd_leak_test.zig` lock in the fix.

### Source C — `bash.zig` subprocess pipe leak in the timeout and pre-thread-error paths

**File**: `src/modules/agent/tools/bash.zig` (lines 264+, foreground mode)

The bash tool kills its child via `std.posix.kill(-child_pgid, .KILL)`
(a raw libc call) and constructs a synthetic `Term` value to skip
`child.wait(io)`. **Problem**: `std.posix.kill` doesn't touch the Zig
`Child` struct at all (it just sends a signal), so the parent's
pipe FDs are never closed. `std.Io.File` has no destructor, so
dropping `child` at scope exit doesn't close them either. They leak
until process exit.

The 2 leak paths:
1. **Timeout path** (line ~478): synthetic Term set inline, the
   `if (child_term == null)` guard at line 496 skips `child.wait(io)`,
   `childCleanupPosix` never runs.
2. **Pre-thread errdefer path** (line ~280): only `kill()` was called,
   no `wait()` afterward.

**Fix**:
1. In the timeout path, call `child.wait(io)` immediately after the
   kill (the child is already a zombie so it returns instantly). The
   guard at line 496 correctly skips the duplicate wait.
2. In the pre-thread errdefer, also call `child.wait(io) catch {}`
   to reap the zombie and run `childCleanupPosix`.

This also fixes a stale comment that claimed `kill` "invalidates
child.id" — that's wrong, only `child.kill(io)` (the Zig API) does that.

## The bigger lesson — Zig 0.16 std.process.Child API reality

| Method | Exists? | Closes pipes? |
|---|---|---|
| `child.wait(io) !Term` | YES | YES (via defer'd `childCleanupPosix`) |
| `child.kill(io) void` | YES | YES (via defer'd `childCleanupPosix` AFTER the kill) |
| `child.deinit(io) void` | **NO** | N/A — doesn't exist |
| `std.posix.kill(pid, sig)` | YES (libc) | NO — doesn't touch the Child struct at all |

**Implications:**
- ANY code that calls `std.posix.kill` to terminate a spawned child
  MUST also call `child.wait(io)` (or `child.kill(io)`) to close the
  pipe FDs. Otherwise the pipes leak.
- ANY code that uses `child.kill(io)` does NOT need a separate
  `child.wait(io)` (kill reaps via `childCleanupPosix`).
- `std.Io.File` has no destructor — dropping a `File` handle as a
  Zig value does nothing. Always call `file.close(io)` explicitly.
- The only "single-call cleanup" is `child.kill(io)`, which does
  kill + wait + cleanup all in one. There's no `kill -9 + wait`
  split API in Zig 0.16.

## Empirical evidence

Before fix (running nalar PID 1363527, started 09:43, observed at ~13:00):
- 198 total FDs
- 175 orphan sockets (held by nalar, not in /proc/net/tcp{,6} or /proc/net/unix)
- 10 pipes held
- 17 threads (suspicious — std.Io.Threaded typically uses 8-9)
- Growth pattern: 0/min when idle, 5-10 FDs/min in bursts during active chat
- ETA to soft limit (1024): ~5-10h of steady chat, minutes under retry stress

## Diagnostic recipe (unchanged from previous memory)

```bash
PID=$(pgrep -f "nalar --port 8081")
echo "FD count: $(ls /proc/$PID/fd | wc -l)"
cat /proc/$PID/limits | grep "Max open files"

# Orphan-FD detection (the smoking gun for any "FD leak"):
for fd in /proc/$PID/fd/*; do
    target=$(readlink "$fd" 2>/dev/null)
    [[ "$target" == socket:* ]] || continue
    inode=$(echo "$target" | sed 's/socket:\[\(.*\)\]/\1/')
    if ! grep -q ": $inode " /proc/net/tcp /proc/net/tcp6 /proc/net/unix; then
        echo "ORPHAN FD: $fd -> $target"
    fi
done | head -n 30
```

## Static-analysis recipe for finding new instances of this bug class

```bash
# 1. Find all struct-init sites that own FDs/handles/resources.
rg -n "var .* = .*Agent\.init\(|var .* = .*\.init\(|var child = try std\.process\.spawn" src/

# 2. For each match, scan the enclosing function (within ~30 lines) for
#    the matching defer/call to deinit/kill/wait.
rg -n --multiline "var .* = .*\.init\([^;]+;\s*$" src/ \
  | while IFS=: read -r file line _; do
      end=$((line + 30))
      if ! sed -n "${line},${end}p" "$file" \
           | grep -qE "(defer .*\.deinit|child\.wait|child\.kill|kill\(.*child)"; then
        echo "POTENTIAL LEAK: $file:$line"
      fi
  done

# 3. Also find any std.posix.kill uses that may skip child.wait:
rg -n "std\.posix\.kill\([^,]*-child" src/  # kills the child's pgid
# Each one MUST be followed (or errdefer-wrapped) by child.wait(io)
# OR the call must happen inside child.kill(io)'s scope.
```

## Verification

After all 3 fixes applied:
- `zig build install:linux:system` → `compile exe nalar` succeeds (cp-to-`/usr/local/bin/nalar` fails harmlessly with permission denied)
- `zig build test --summary all` → 1411/1418 pass, 3 skipped, 4 failed (same 4 pre-existing failures as the baseline of 1408/1415; the +3 are the new `http_client_fd_leak_test.zig` tests)
- No new test failures introduced

## Plan / commit reference

- Branch: `worktree/fd-quota-leak-fix`
- Files changed:
  - `src/ai_workflow/tui/workflow.zig` (+9 lines: 1-line defer + 8-line comment)
  - `src/modules/http/HttpClient.zig` (+37 lines: 2 defer blocks for pipe cleanup)
  - `src/modules/http/test_runner.zig` (+8 -1: registers the new test file)
  - `src/modules/http/http_client_fd_leak_test.zig` (new file: 182 lines, 3 static-contract tests)
  - `src/modules/agent/tools/bash.zig` (+44 lines: 2 surgical fixes for child.wait on timeout/error paths)
- Total: +89 / -9 across 5 files
- Memory update: this file

## Related memories

- `nalar-sse-incomplete-chunked-encoding.md` — PR #52 (2026-06-30) fixed the SSE manager version of the same bug class.
- `zig-0.16-process-spawn-api.md` — general notes on Zig 0.16 `std.process.spawn` API changes; this memory is the FD-leak-specific follow-up.
- `zig-0.16-thread-and-sleep-api.md` — notes on `child.kill(io) void` returning void (not Term) and asserting `child.id == null` after.