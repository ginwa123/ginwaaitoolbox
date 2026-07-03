# Decoupled nalar Service — Design

**Date:** 2026-07-03
**Status:** Draft (awaiting approval)
**Owner:** ginwa
**Related task:** kanban `make desktop split`

---

## Overview

Stop bundling nalar's lifetime to nalar-desktop's lifetime. Today, `nalar-desktop` spawns `nalar` as a *child process* and `SIGTERM`s it when the window closes — wasting ~400 MB of RAM (3 processes: nalar-desktop + WebKit parent + WebKit renderer) and forcing the user to also run a separate `nalar` for browser-based access.

After this change, `nalar` runs as an **independent long-lived service**. `nalar-desktop` is a pure GUI shell: it probes for a running nalar, attaches a webview, and never starts or stops the backend. The lifecycle is:

| Action | Effect |
|---|---|
| `nalar service start` | Fork/detach nalar into the background, write pid + port to state file |
| `nalar service stop` | Read state, SIGTERM, wait, SIGKILL if needed, delete state |
| `nalar service status` | Show running / stopped / stale-pid |
| Open `nalar-desktop` | Probe state → if running attach; else spawn detached then attach. Window close does **nothing** to nalar |
| Open browser at `http://127.0.0.1:8081/` | Same nalar instance as desktop (or just the one without desktop) |

**Result:** one nalar process serves all UIs (desktop + browser + webview popups) until the user explicitly stops it.

---

## Decisions (3 questions, all approved)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Should desktop auto-spawn nalar if it isn't running? | **Yes — by default.** `--no-auto-start` to opt out and surface a "Run `nalar service start`" error instead. |
| 2 | Port strategy | **Try 8081 first; if taken, random-port fallback.** The chosen port is written to the state file so desktop knows where to probe. |
| 3 | Lifecycle decoupling | **Always.** Desktop close never signals nalar. `nalar service stop` is the only stop path. |

---

## Architecture

### Process model (one run)

```
┌─────────────────────────────────────────────────────────────────┐
│  User runs `nalar service start` (or nalar-desktop auto-spawns)  │
│              │                                                   │
│              ▼                                                   │
│   ┌────────────────────────┐                                     │
│   │ nalar parent process    │  forks twice, writes pid+port      │
│   │ (exits immediately)    │  to state file, redirects stdio    │
│   └──────────┬─────────────┘                                     │
│              ▼                                                   │
│   ┌────────────────────────┐    listens on 8081 (or random)     │
│   │ nalar daemon            │─────────────────────────────────────┼────► browser @ :8081
│   │ pid: 12345, port: 8081 │─────────────────────────────────────┼────► webview popups
│   │ state file: ...        │                                     │
│   └────────────────────────┘                                     │
│                                                                 │
│   ┌────────────────────────┐                                     │
│   │ nalar-desktop (GUI)     │  probes state file → health 200    │
│   │ no child nalar          │  → attaches webview, exits cleanly │
│   └────────────────────────┘                                     │
└─────────────────────────────────────────────────────────────────┘
```

Key invariants:
- **Single-instance lock**: at most one nalar daemon per user. The state file's `pid` field, plus a `flock`/POSIX advisory lock, prevents double-spawn.
- **State file is the source of truth**: both desktop and `nalar service stop` read it; both `nalar service start` writes it. No PID file + separate port file — one JSON.
- **No re-parenting**: the daemon does not watch the desktop. Each has its own lifetime.

### State file

**Location** (per platform):
- Linux/macOS: `$XDG_STATE_HOME/nalar/state.json`, fallback to `~/.local/state/nalar/state.json` if `XDG_STATE_HOME` unset
- Windows: `%LOCALAPPDATA%\nalar\state.json`

**Schema** (JSON, written atomically by `nalar service start`, deleted by `nalar service stop` on clean exit):

```json
{
  "pid": 12345,
  "port": 8081,
  "host": "127.0.0.1",
  "started_at": 1751558400,
  "version": "0.4.0",
  "static_dir": "/run/user/1000/nalar-desktop-webapp-3170084"
}
```

The `static_dir` field carries the path to the extracted webapp directory, which is normally only relevant when `nalar-desktop` spawned the daemon (it extracted the embedded webapp, then passed `--static-dir` through). A manually-started `nalar` may have `null`/`""` here, in which case the existing webapp URL handling is unchanged.

### Where the nalar binary lives, from the desktop's view

The desktop already resolves the nalar binary via `src/apps/desktop_app/path_resolve.zig`. That code locates an executable named `nalar` next to itself or on `$PATH`. We add a third resolution step: **the desktop can also shell out to `<self_dir>/nalar service status`** to ask "is a daemon already alive?" — useful on systems where the state-file path can't be inferred from $HOME alone (e.g. unusual XDG setups).

### Spawn-detach on Linux/macOS

Pseudo-code (Zig, using `std.os.linux.fork` + `setsid`):

```zig
pub fn daemonize(log_path: []const u8) !void {
    // First fork
    const pid1 = std.os.linux.fork();
    if (pid1 != 0) {
        // Parent: wait briefly for child to print its PID, then exit.
        // The child prints its daemonized pid to a pipe, we read it,
        // propagate it back to the CLI parser. (Optional — the state
        // file has it too; the pipe is just for ergonomic CLI output.)
        return;
    }

    // In child 1: become session leader.
    _ = std.os.linux.setsid();

    // Second fork — the daemon is never a session leader, so it can
    // never reacquire a controlling terminal.
    const pid2 = std.os.linux.fork();
    if (pid2 != 0) std.process.exit(0);

    // Now we're the daemon.
    // - chdir("/")
    // - umask(0)
    // - redirect stdin/stdout/stderr → log_path or /dev/null
    // - write state file
    // - acquire flock on state file path (prevents double-spawn)
    // - run the existing nalar server
}

fn handleSigterm(_: c_int) void {
    // close HTTP server, remove state file (this is the "clean shutdown"
    // signal — service stop shouldn't have to delete the file for us).
    std.process.exit(0);
}
```

### Spawn-detach on Windows

```zig
pub fn daemonizeWindows(log_path: []const u8) !void {
    var si: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);
    si.cb = @sizeOf(STARTUPINFOW);

    var cmd_line: [4096:0]u16 = ...;
    const flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB;
    if (CreateProcessW(null, &cmd_line, null, null, false, flags, ...)) |ok| {
        if (!ok) return error.CreateProcessFailed;
    }
    // pi.dwProcessId → write to state file
    // Don't inherit handles (bInheritHandles=false) — the daemon has
    // no relationship to this shell session.
    // ...
}
```

### Single-instance lock via flock

`nalar service start` opens the state file path with `O_CREAT | O_RDWR` and calls `flock(fd, LOCK_EX | LOCK_NB)`. If the lock fails (because another instance holds it), the daemon refuses to start. This is a user-level lock (advisory, removed on process exit) and complements the pid check.

### Desktop attach-or-spawn flow

```zig
// Pseudocode for new main.zig spawn-mode logic
fn resolveAttachTarget(allocator, cfg) !AttachTarget {
    // 1. Read state file
    if (try readStateFile(allocator)) |state| {
        if (try probeHealth(state.host, state.port)) {
            return .{ .url = state.url(), .we_spawned = false };
        }
    }
    // 2. Fall back to well-known 8081
    if (try probeHealth("127.0.0.1", 8081)) {
        return .{ .url = "http://127.0.0.1:8081/", .we_spawned = false };
    }
    // 3. Auto-spawn (unless --no-auto-start)
    if (cfg.no_auto_start) return error.NalarNotRunning;
    return try spawnDetachedAndWaitForHealth();
}
```

The `we_spawned` flag is captured but currently has no behavioral effect (we no longer send signals on close). It's retained for diagnostics — `"we_spawned=true"` in `--smoke-test` output for debugging.

### What gets removed

| Existing code | Disposition |
|---|---|
| `subprocess.terminate()` (kills child nalar) | Delete. Window close never reaches the daemon. |
| `subprocess.spawn()` (fork+exec with piped stdio, no detach) | Replace with `daemonize()` which double-forks. |
| `cfg.port` semantics (auto-pick random or honor explicit) | Simplify: nalar service auto-picks; the port surfaces via state file. Desktop doesn't bind nalar's port anymore. |
| `--port` flag on desktop | Keep for "I want to attach to a specific port" rather than auto-detect from state file. |
| `--nalar-url` flag | Keep for pointing at non-local machines (e.g. `nalar-desktop --nalar-url http://10.0.0.42:8081` to attach to a remote box). |
| `--nalar-path` flag | Keep — used by auto-spawn to find the binary. |

### What gets added

| New code | Purpose |
|---|---|
| `src/main.zig` `service` subcommand | CLI parser for `nalar service {start,stop,status,restart}` |
| `src/daemon.zig` | Cross-platform daemonize (double-fork on POSIX, DETACHED_PROCESS on Windows) |
| `src/state_file.zig` | Read/write the JSON state file; pidfile + atomic rename semantics |
| `src/signal_handlers.zig` | POSIX sigaction / Windows console-ctrl-handler to convert SIGTERM into graceful shutdown |
| `src/apps/desktop_app/attach.zig` | New desktop-side logic: probe state → health → connect |
| `src/apps/desktop_app/cli.zig` `--no-auto-start` flag | Opt out of the auto-spawn fallback |
| `src/apps/desktop_app/cli.zig` `--attach-port N` | Override default attach port (advanced — most users don't need this) |

---

## Data flow on `nalar service start`

1. CLI parser in `src/main.zig` matches `service start`.
2. Acquire `flock(LOCK_EX | LOCK_NB)` on the state file path. On failure, check the live pid (kill 0); if live, refuse with "nalar already running (pid N)"; if dead, remove stale state file and retry the lock once.
3. Pick a port: try 8081 (`port.findFree`), else random. Save to memory.
4. Double-fork + setsid (POSIX) or CreateProcess with DETACHED (Windows).
5. Daemon opens state file for writing, fsyncs, closes.
6. Daemon logs to `~/.local/share/nalar/service.log` (POSIX) or `%LOCALAPPDATA%\nalar\service.log` (Windows). Stdin → /dev/null.
7. Daemon registers SIGTERM handler that closes the HTTP server and removes the state file.
8. Daemon runs the existing nalar server on the picked port.
9. The original (foreground) `nalar service start` exits 0 as soon as the state file appears + the health endpoint responds (bounded poll: 10s, 100ms intervals).

## Data flow on `nalar service stop`

1. CLI parser in `src/main.zig` matches `service stop`.
2. Read state file. If missing → "nalar is not running" (exit 0 — idempotent).
3. Capture pid + port. Verify pid is alive via `kill(pid, 0)`. If dead, remove stale state file and exit 0.
4. Optional `--graceful-timeout N` flag (default 5000ms). Send SIGTERM (or PostThreadMessage to a hidden window on Windows), then poll `/api/health` until it returns non-2xx, up to N ms.
5. If still alive after timeout: `kill(pid, SIGKILL)` or TerminateProcess; remove state file.

## Data flow on `nalar-desktop` launch

1. Parse CLI. (`--no-auto-start`, `--attach-port`, `--nalar-url`, `--port` for the explicit-case old behavior.)
2. Resolve a target URL (the `attachTarget()` pseudocode above).
3. Open the webview at the target URL.
4. Run the GTK / NSApp / Win32 message loop.
5. Window close → exit 0. No signals sent. No cleanup needed — the daemon is independent.
6. The extracted webapp temp dir is owned by the *daemon* now (we passed `--static-dir` through), not by nalar-desktop. Add a deferred cleanup only if the webapp source was extracted in *this* nalar-desktop run AND the daemon didn't ack our path (a `--static-dir-from-desktop <path>` handoff where the daemon clears the dir on its own shutdown).

---

## Error handling

| Scenario | Behavior |
|---|---|
| User runs `nalar service start` while one is running | Refuse with "Already running (pid N)" — idempotent UX |
| Stale state file (PID points to dead process) | Remove the state file, proceed with start. Detected via `kill(pid, 0)` + `ESRCH` mapping |
| Desktop launched with no nalar running, `--no-auto-start` | Exit 1 with clear "Run `nalar service start` in a terminal" message; webview not opened |
| Port 8081 in use by another process (not nalar) | Random-port fallback. State file records the actual port |
| `nalar service stop` on not-running daemon | Exit 0, idempotent (no output by default; `--verbose` to log the no-op) |
| `nalar service stop` times out (5s grace, SIGKILL needed) | Print "Forced termination" warning. State file removed. Exit 0 |
| Daemon crashes mid-stream | State file is left behind. Next `start` cleans it up via stale-PID detection |
| Two desktop instances launched in parallel | Both probe the same state file → both attach to the same nalar. No conflict because the read is read-only |
| User logs out (Linux systemd, macOS logout) without `nalar service stop` | Daemon survives on Linux (POSIX process not tied to user session by default — verify), dies on macOS by default. **TODO** — may need a launchd plist for macOS to survive logout. Out of scope for this design; track as follow-up |

## Testing

### Unit tests (`src/daemon_test.zig`, `src/state_file_test.zig`)

- `readStateFile` returns null for missing file (not error)
- `writeStateFile` atomically renames a tmp file into place (no half-written state visible)
- `daemonize` test that fork-double-forks and verifies (a) the daemon's PPID == 1 or is a different process tree, (b) the daemon's PGID != the original
- `parseServiceSubcommand` accepts `start`, `stop`, `status`, `restart` with correct arg validation

### Integration tests (`tests/`, `scripts/`)

- **Smoke: start → status → stop cycle.** `scripts/service-lifecycle-smoke.sh` spawns a real nalar in a temp `$HOME`, asserts pidfile is written, polls `/api/health`, calls `nalar service stop`, asserts pidfile is gone and the port is unbound. Time-out: 15s.
- **Smoke: desktop auto-spawn + survives close.** Launch `nalar-desktop` with `--smoke-test` flag (already implemented) against a fresh `$HOME` where no nalar is running. The smoke test should observe (a) state.json appears within 5s, (b) closing the window does NOT remove state.json, (c) nalar is still alive via `/api/health`.
- **Cross-platform CI matrix.** The 3-cell matrix (Linux / Windows / macOS) already runs `zig build test` for both targets. Add the smoke test to each cell via a separate shell-script step that builds and runs the smoke runner.

### Manual test checklist (pre-merge)

1. `nalar service start` writes `~/.local/state/nalar/state.json`. `cat` it — correct pid + port.
2. `curl http://127.0.0.1:<port>/api/health` returns 200.
3. Open browser at the URL — Vue app renders.
4. `nalar service stop` — port is freed, state.json gone, `curl` now fails with ECONNREFUSED.
5. Launch nalar-desktop with no nalar running — it auto-spawns, opens the window. Close the window — `ps aux | grep nalar` still shows the daemon.
6. Two consecutive `nalar service start` — second one refuses with "already running".
7. Kill -9 the daemon while it's running — state.json is left stale. Run `nalar service start` — first tries to acquire flock, fails, checks pid via kill 0, finds it dead, removes state, proceeds. New daemon runs.

---

## Migration

This is a **breaking change** for `nalar-desktop` users who relied on the "open the app, it brings its own nalar, close it, it's gone" mental model. Mitigations:

1. **Document the change** in `README.md` and the next release notes: "nalar now runs as a background service; use `nalar service start`/`stop`/`status`."
2. **First-run UX**: if `nalar-desktop` is opened with `--no-auto-start` AND no nalar is running, the error message should be actionable: "nalar isn't running. Open a terminal and run `nalar service start`."
3. **Companion onboarding**: the same first-run experience as today (auto-spawn) is the default — users who don't know about `service` commands never need to interact with the new CLI.
4. **No state machine for the `nalar-desktop` binary itself** — it's still a simple "open window" app. The only change is how it finds/connects to nalar.
5. **Keep `--nalar-url`** for users on remote setups; deprecation only after a release cycle confirms nobody uses it.

## Out of scope (follow-ups)

1. **macOS login/logout survival**: requires a launchd plist. Not required for the architecture.
2. **systemd integration** for Linux (`nalar.service` unit + `xdg-autostart`). Would let nalar start at login. Not required.
3. **Windows Service** registration via `sc.exe`. Same reasoning.
4. **auto-restart on crash**: a tiny supervisor that re-runs `service start` if the pid goes dead. Optional, not in v1.
5. **Multiple nalar instances per user** (e.g., sandboxed contexts on different ports): the design assumes singleton. A future iteration could relax the flock to per-port.
6. **TLS / non-loopback binding**: out of scope; current `127.0.0.1` binding is intentional.
