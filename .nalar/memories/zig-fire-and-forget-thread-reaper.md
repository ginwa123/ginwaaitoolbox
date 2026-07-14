# Zig 0.16 — Fire-and-forget child spawn needs a per-child reaper thread (NOT signal(SIGCHLD, SIG_IGN))

When spawning a child process and intentionally not waiting for it
("fire-and-forget" pattern for notifications, cleanup tasks, daemons
that detach, etc.), the child will become a **zombie** in the parent's
process table forever UNLESS one of these is true:

1. **SIGCHLD is set to SIG_IGN** (process-global) — kernel auto-reaps.
2. **A handler calls waitpid()** when SIGCHLD fires.
3. **The parent explicitly wait()s on the child** (blocks, defeats
   the fire-and-forget intent).

On glibc ≥ 2.34 (the default on most modern Linux distros), SIGCHLD is
left at its **default behavior, which does NOT auto-reap**. So fire-and-
forget `std.process.spawn` without #1 or #2 accumulates zombies — about
9 per hour in nalar's notification path (verified empirically on
2026-07-15).

## Symptom

`/proc/<ppid>/stat` shows children in state `Z` (zombie) with `comm` =
`(notify-send)` (or similar). Count grows monotonically with each spawn.

```bash
for sf in /proc/[0-9]*/stat; do
    state=$(awk '{print $3}' "$sf" 2>/dev/null)
    ppid_in=$(awk '{print $4}' "$sf" 2>/dev/null)
    if [ "$state" = "Z" ] && [ "$ppid_in" = "<your-pid>" ]; then
        comm=$(awk '{print $2}' "$sf" 2>/dev/null)
        echo "ZOMBIE: $(basename "$sf" | tr -dc 0-9)  $comm"
    fi
done
```

Not an FD leak (the child's FDs are closed when it exits), but a real
kernel memory waste — each zombie takes a `pid_table` slot (~150-300
bytes + ~1 KB kernel struct).

## The fix — per-child detached reaper thread

```zig
/// Args passed to the reaper thread. The struct is copied onto the
/// thread's stack for the thread's lifetime, so no heap allocation
/// is needed. `io` is a fat pointer (vtable + userdata) and `child`
/// is a small handle struct; both are cheap to copy.
const ReaperArgs = struct {
    io: std.Io,
    child: std.process.Child,
};

/// One-shot reaper thread: blocks on `child.wait` so the OS can reap
/// the child when it exits. Fire-and-forget for the caller — we
/// don't care about the exit status, so any error from `wait` is
/// silently ignored.
fn reapChild(args: ReaperArgs) void {
    // Note: function parameters are const-by-default in Zig. Since
    // `child.wait(io)` requires `*Child` (mutable, because it nulls
    // `child.id` to mark the child as reaped), copy into a `var`
    // local first.
    var local = args;
    _ = local.child.wait(local.io) catch {};
}

fn spawnFireAndForget(io: std.Io, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.BinaryNotFound;
    if (child.id == null) return error.BinaryNotFound;

    const args = ReaperArgs{ .io = io, .child = child };
    if (std.Thread.spawn(.{}, reapChild, .{args})) |thread| {
        thread.detach();
    } else |_| {
        // Thread spawn failed (out of memory / thread limit). Fall
        // back to inline `child.kill(io)` to at least prevent zombie
        // accumulation. `child.kill(io)` in Zig 0.16 returns void,
        // blocks until the child is reaped, and closes the pipe FDs
        // via childCleanupPosix.
        child.kill(io);
    }
}
```

## Why this and not `signal(SIGCHLD, SIG_IGN)`

Tempting one-liner, but it's **process-global** — it would break
`child.wait(io)` everywhere else in the codebase. nalar has these
sites that rely on default SIGCHLD behavior:

- `src/modules/agent/tools/bash.zig` — `child.wait(io)` reaps spawned shells
- `src/modules/http/HttpClient.zig` — `child.wait(self.io)` reaps curl subprocess
- `src/modules/agent/tools/lsp*.zig` — 4+ sites that call `_ = child.wait() catch {};`

Per the POSIX `wait(2)` man page: if SIGCHLD is set to SIG_IGN, `wait()`
returns `-1` with `errno = ECHILD` (no children to wait on). All those
existing reapers would silently fail.

The per-child reaper thread is **surgical** — only the specific child's
reaping happens off-thread, no global signal-state change.

## Cost

Each fire-and-forget child costs ~8 KB of thread stack + a few hundred
bytes of struct state. For low-volume paths (LLM completions, OS
notifications) this is negligible. For high-volume paths (thousands of
spawns per second), switch to a **single long-lived reaper thread** that
periodically `waitpid(-1, ..., WNOHANG)`s over a queue of registered
PIDs — but this is overkill for the typical notification/cleanup case.

## Empirical verification (the nalar fix)

Before fix (production nalar on port 8081):
- 02:08:06 — 2 `notify-send` zombies
- 02:35:04 — 6 `notify-send` zombies
- Rate: ~9 zombies/hour

After fix (test nalar on port 8080, isolated HOME):
- 20 × `POST /api/notify/test` → **0 zombies** after 2s settle
- 10 × `POST /api/notify/test` → **0 zombies**, thread count returns
  to 8 (baseline `std.Io.Threaded` workers)

## Why the comment in the original code was wrong

```zig
// The OS reaps the child when it exits. The parent's process table
// will hold the zombie briefly; this is acceptable for short-lived
// notification daemons.
```

This is **only true if SIGCHLD is set to SIG_IGN** — which glibc ≥ 2.34
does NOT do by default. The kernel DOES auto-reap under SIG_IGN (so
zombies never appear), but at the cost of `wait()` returning ECHILD.
Without SIG_IGN, the kernel does NOT auto-reap — the child stays a
zombie until the parent explicitly wait()s. The comment was
authoritative-sounding but wrong for the default Linux environment.

## When to apply

- Any `std.process.spawn(io, ...)` whose result is **deliberately
  not wait()ed** (notification daemons, log tailers, hot-standby
  watchers, etc.)
- Cross-platform `osascript` (macOS) and `powershell` (Windows) paths
  in `notifications.zig` ALSO need this — same bug, same fix.
- Any test that spawns a helper process without waiting for it
  (will accumulate zombies in the test runner).

## Related memories

- `process-fd-quota-exceed-2026-07-14-workflow-leak.md` — different FD
  leak class (pipe FDs not closed in error paths), fixed in PR #91.
- `zig-0.15-process-spawn-api.md` — Zig 0.15 fire-and-forget pattern
  (same advice: OS reaps ONLY if SIGCHLD is SIG_IGN).
- `zig-0.16-thread-and-sleep-api.md` — Zig 0.16 `std.Thread` API
  (no Mutex; use `std.atomic.Mutex` for spinlocks).
