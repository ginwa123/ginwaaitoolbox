---
name: debug-hanging-zig-test
description: "Use when a `zig test` run produces no output and times out (a test is blocking forever) — separates compile from run to identify the hanging test, and lists the socket-read deadlocks that cause it in this repo."
---
# Debugging a hanging Zig test

## When to Use
`zig test -lc src/foo.zig` produces **no output and no error** and the command
times out (exit code 124 / SIGKILL), or you suspect one test blocks forever.
Also use when you need to know *which* test in a file hangs.

## Context
Repo: ginwaaitoolbox, module `src/modules/custom_http_server`. Tests that touch
sockets (via `test_helpers.createSocketPair()` / `Stream`) can block forever, and
`zig test` prints per-test progress to **stdout only as each test finishes** — so
a `| tail -n 30` pipeline hides everything until the process exits, which it
never does. A hang therefore looks identical to a very slow compile.

## Procedure
1. Prove compilation is fine and get a runnable binary in one step (sub-second
   on this repo once the cache is warm):
   ```bash
   zig test -lc --test-no-exec -femit-bin=/tmp/foo_test_bin src/foo.zig
   ```
   If this fails, it's a compile error, not a hang — read the compiler output.
2. Run the binary yourself with a bounded timeout, streamed to a log:
   ```bash
   timeout 60 /tmp/foo_test_bin > /tmp/foo_run.log 2>&1; echo "exit=$?"; tail -n 40 /tmp/foo_run.log
   ```
   The **last line of the log names the hanging test** (`N/M name...` with no
   `OK`), because the runner prints each test name before executing it.
3. Fix the specific test, then re-run the real command the task mandated
   (`zig test -lc src/foo.zig`) — never leave the `--test-no-exec` flow as the
   verification.
4. If the fix involves socket reads, cap the wait instead of trusting the peer:
   size the read buffer to the exact expected payload (EOF or full buffer ends
   the loop), or drain from a spawned `std.Thread` when the payload exceeds the
   socketpair buffers.

## Pitfalls
- **`read`-until-buffer-full on a live stream is an infinite block.** A helper
  like `while (got < dst.len) { got += try s.read(dst[got..]); }` only terminates
  when the peer closes OR sends `dst.len` bytes. With a 64-byte buffer and a
  31-byte message from a peer that stays open, it blocks forever. Size `dst` to
  the payload you expect.
- **Big payloads need a concurrent reader.** A 256 KiB `writeAll` on an AF_UNIX
  socketpair fills the ~200 KiB kernel buffer and then legitimately blocks; spawn
  a reader thread (and `shutdown` the write side in the error path so a failed
  write can never leave the thread parked forever).
- **`| tail` hides the hang.** Pipe to `tail` only after redirecting to a log, or
  you lose the per-test progress that identifies the culprit.
- **Local struct self-reference.** `const Ctx = struct { fn run(self: *Ctx) ... }`
  inside a function errors with `use of undeclared identifier 'Ctx'`; use
  `fn run(self: *@This()) void`.

## Verification
`zig test -lc src/foo.zig` finishes well within its timeout and prints
`All N tests passed.` as the final line. For a quick cross-target compile check
of OS-branched code (e.g. winsock vs POSIX paths):
`zig test -lc --test-no-exec -target x86_64-windows-gnu src/foo.zig` → exit 0.

